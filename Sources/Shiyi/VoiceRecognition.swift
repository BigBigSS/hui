import AppKit
import AVFoundation
import CryptoKit
import Foundation
import Security
import LocalAuthentication

struct VoiceCredentials: Codable, Sendable {
    var appID = ""
    var apiKey = ""
    var apiSecret = ""
    var valid: Bool { !appID.isEmpty && !apiKey.isEmpty && !apiSecret.isEmpty }

    static let service = "com.macliphistory.voice-demo.xfyun"
    static func load(allowPrompt: Bool = true) -> VoiceCredentials? {
        var result: CFTypeRef?
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "iat",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        if !allowPrompt {
            let context = LAContext(); context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    func save() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service, kSecAttrAccount as String: "iat"]
        let data = try JSONEncoder().encode(self)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw VoiceError.message("钥匙串保存失败；可选择仅本次使用。") }
        } else if status != errSecSuccess { throw VoiceError.message("钥匙串保存失败；可选择仅本次使用。") }
    }
    func signedURL() -> URL {
        let host = "iat-api.xfyun.cn"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let date = formatter.string(from: Date())
        let source = "host: \(host)\ndate: \(date)\nGET /v2/iat HTTP/1.1"
        let signature = Data(HMAC<SHA256>.authenticationCode(for: Data(source.utf8), using: SymmetricKey(data: Data(apiSecret.utf8)))).base64EncodedString()
        let authorization = Data("api_key=\"\(apiKey)\", algorithm=\"hmac-sha256\", headers=\"host date request-line\", signature=\"\(signature)\"".utf8).base64EncodedString()
        var url = URLComponents(string: "wss://\(host)/v2/iat")!
        url.queryItems = [URLQueryItem(name: "host", value: host), URLQueryItem(name: "date", value: date), URLQueryItem(name: "authorization", value: authorization)]
        return url.url!
    }
}

enum VoiceError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

// Result sequence numbers refer to original response slots, including replaced slots.
struct VoiceTranscript {
    private var segments: [Int: String] = [:]
    mutating func accept(_ result: [String: Any]) {
        guard let sn = result["sn"] as? Int else { return }
        if result["pgs"] as? String == "rpl", let range = result["rg"] as? [Int], range.count == 2, range[0] <= range[1] {
            segments = segments.filter { $0.key < range[0] || $0.key > range[1] }
        }
        let words = result["ws"] as? [[String: Any]] ?? []
        segments[sn] = words.compactMap { ($0["cw"] as? [[String: Any]])?.first?["w"] as? String }.joined()
    }
    var text: String { segments.keys.sorted().compactMap { segments[$0] }.joined() }
}

// AVAudioConverter invokes its input provider synchronously within convert().
private final class VoiceConversionInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var supplied = false
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

// AVAudioEngine owns the tap; conversion stays on its serial audio callback.
private final class VoiceAudioCapture: @unchecked Sendable {
    let engine = AVAudioEngine()
    private var installed = false
    func start(deliver: @escaping @Sendable (Data, Float) -> Void) throws {
        let input = engine.inputNode
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw VoiceError.message("麦克风不可用，请检查系统的声音输入设备。")
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: source) { buffer, _ in
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / source.sampleRate) + 64)
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            let conversion = VoiceConversionInput(buffer)
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if conversion.supplied { status.pointee = .noDataNow; return nil }
                conversion.supplied = true
                status.pointee = .haveData
                return conversion.buffer
            }
            guard error == nil, output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return }
            let count = Int(output.frameLength)
            var sum: Float = 0
            for i in 0..<count { let value = Float(samples[i]) / 32768; sum += value * value }
            deliver(Data(bytes: samples, count: count * 2), min(1, sqrt(sum / Float(count)) * 7))
        }
        installed = true
        engine.prepare()
        do { try engine.start() } catch { stop(); throw VoiceError.message("无法启动麦克风，请检查输入设备或重新授权。") }
    }
    func stop() {
        engine.stop()
        if installed { engine.inputNode.removeTap(onBus: 0); installed = false }
    }
}

@MainActor
final class VoiceRecognition: ObservableObject {
    @Published var text = ""
    @Published private(set) var rawText = ""
    @Published private(set) var refinementStatus = "原文直出"
    @Published private(set) var refining = false
    @Published var aiConfiguration: VoiceAIConfiguration?
    @Published var aiEnabled = UserDefaults.standard.object(forKey: "voiceAIEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(aiEnabled, forKey: "voiceAIEnabled") }
    }
    @Published var customTerms = UserDefaults.standard.string(forKey: "voiceCustomTerms") ?? "" {
        didSet { UserDefaults.standard.set(customTerms, forKey: "voiceCustomTerms") }
    }
    private let refiner = VoiceTextRefiner()
    private var finalization: Task<Void, Never>?

    init() {
        refiner.onChange = { [weak self] text, status, working in
            self?.text = text; self?.refinementStatus = status; self?.refining = working
        }
        Task { [weak self] in
            let configuration = await Task.detached { VoiceAIConfiguration.load() }.value
            self?.aiConfiguration = configuration
        }
    }
    private func acceptTranscript(_ value: String) {
        rawText = value
        refiner.update(value)
    }
    @Published var status = "先点击输入框，再按住快捷键说话"
    @Published private(set) var recording = false
    @Published private(set) var busy = false
    @Published private(set) var level: Float = 0
    @Published private(set) var elapsed = 0
    @Published private(set) var error = false
    var onFinished: (() -> Void)?
    @Published var credentials = VoiceCredentials()
    @Published private(set) var loadingCredentials = false

    func loadCredentials(allowPrompt: Bool = true) {
        guard !loadingCredentials else { return }
        loadingCredentials = true
        Task { [weak self] in
            let saved = await Task.detached(priority: .userInitiated) { VoiceCredentials.load(allowPrompt: allowPrompt) }.value
            guard let self else { return }
            if let saved { self.credentials = saved }
            self.loadingCredentials = false
        }
    }
    private var capture: VoiceAudioCapture?
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var sender: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var pending = Data()
    private var transcript = VoiceTranscript()
    private var token = UUID()
    private var stopping = false
    private var sentFirst = false
    private var streamID = UUID()
    private var committedText = ""
    private var sentBytes = 0
    private var sendingFrame = false
    private var finalResultReady = false

    func start() {
        guard !busy else { return }
        guard credentials.valid else { fail("本机语音配置暂不可用。"); return }
        token = UUID()
        let run = token
        busy = true
        error = false
        status = "正在准备麦克风…"
        Task {
            let permission = AVCaptureDevice.authorizationStatus(for: .audio)
            var granted = permission == .authorized
            if permission == .notDetermined { granted = await Self.requestMicrophone() }
            guard token == run, busy else { return }
            guard granted else { fail("麦克风未授权。请在系统设置 → 隐私与安全性 → 麦克风中允许本应用。"); return }
            begin(run: run)
        }
    }
    private static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
    private func begin(run: UUID) {
        text = ""; rawText = ""; transcript = VoiceTranscript(); pending = Data(); elapsed = 0
        refiner.start(configuration: aiEnabled ? aiConfiguration : nil, glossary: customTerms)
        stopping = false; committedText = ""
        let capture = VoiceAudioCapture()
        self.capture = capture
        do {
            try capture.start { [weak self] data, level in
                Task { @MainActor in
                    guard let self, self.token == run, self.recording else { return }
                    self.level = level
                    self.pending.append(data)
                    if self.pending.count > 640000 { self.fail("网络发送跟不上录音，已停止。已识别文字保留，请稍后重试。"); }
                }
            }
        } catch { fail(error.localizedDescription); return }
        recording = true
        status = "正在聆听…"
        openStream(run: run)
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.token == run, self.recording else { return }
                self.elapsed += 1
            }
        }
    }

    // A provider segment may end on silence or its duration limit. The microphone
    // belongs to the held-key session and stays alive across all such segments.
    private func openStream(run: UUID) {
        closeStream()
        transcript = VoiceTranscript(); sentFirst = false; sentBytes = 0; sendingFrame = false; finalResultReady = false
        let segment = streamID
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 80
        let session = URLSession(configuration: config)
        self.session = session
        let socket = session.webSocketTask(with: credentials.signedURL())
        self.socket = socket
        socket.resume()
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let reply = try await socket.receive()
                    guard let self, self.token == run, self.streamID == segment, self.busy else { return }
                    let data: Data
                    switch reply { case .data(let bytes): data = bytes; case .string(let string): data = Data(string.utf8); @unknown default: continue }
                    guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any], let code = payload["code"] as? Int else { throw VoiceError.message("讯飞返回了无法识别的结果，已有文字已保留。") }
                    guard code == 0 else { throw VoiceError.message(Self.explain(code)) }
                    if let resultData = payload["data"] as? [String: Any] {
                        if let result = resultData["result"] as? [String: Any] {
                            self.transcript.accept(result)
                            self.acceptTranscript(self.committedText + self.transcript.text)
                            if self.recording { self.status = "正在听写 · 中文普通话" }
                        }
                        if resultData["status"] as? Int == 2 {
                            self.finalResultReady = true
                            if !self.sendingFrame { self.finishStream(run: run) }
                            return
                        }
                    }
                }
            } catch {
                guard let self, self.token == run, self.streamID == segment, self.busy else { return }
                self.fail((error as? VoiceError)?.localizedDescription ?? "讯飞连接中断或鉴权失败，请检查网络和凭证。已有文字已保留。")
            }
        }
        sender = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    guard let self, self.token == run, self.streamID == segment, self.busy else { return }
                    // Rotate well before the provider's 60-second limit. Keep
                    // newly captured audio queued until the next socket opens.
                    if self.sentBytes >= 50 * 32000 || (self.stopping && self.pending.isEmpty) {
                        if !self.sentFirst {
                            try await socket.send(.string(self.frame(audio: Data(repeating: 0, count: 1280), status: 0)))
                            guard self.streamID == segment, self.token == run else { return }
                            self.sentFirst = true
                        }
                        try await socket.send(.string(self.frame(audio: Data(), status: 2)))
                        guard self.streamID == segment, self.token == run else { return }
                        self.armFinalTimeout(run: run, segment: segment)
                        return
                    }
                    if self.pending.count >= 1280 || (self.stopping && !self.pending.isEmpty) {
                        let length = min(1280, self.pending.count)
                        let chunk = Data(self.pending.prefix(length))
                        let frame = try self.frame(audio: chunk, status: self.sentFirst ? 1 : 0)
                        self.sentFirst = true
                        self.sendingFrame = true
                        try await socket.send(.string(frame))
                        guard self.streamID == segment, self.token == run else { return }
                        self.sendingFrame = false
                        self.pending.removeFirst(length)
                        self.sentBytes += length
                        if self.finalResultReady { self.finishStream(run: run); return }
                    }
                    try await Task.sleep(for: .milliseconds(40))
                }
            } catch {
                guard !Task.isCancelled, let self, self.token == run, self.streamID == segment, self.busy else { return }
                self.sendingFrame = false
                if self.finalResultReady { self.finishStream(run: run); return }
                self.fail("音频发送失败，请检查网络。已有文字已保留。")
            }
        }
    }
    private func armFinalTimeout(run: UUID, segment: UUID) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self, self.token == run, self.streamID == segment, self.busy else { return }
            self.fail("等待识别结果超时，已保留当前文字。")
        }
    }
    private func finishStream(run: UUID) {
        committedText += transcript.text
        acceptTranscript(committedText)
        // stop() is the only normal path that turns recording off. Pending audio
        // still needs its own segment if the provider ended just as the key rose.
        if recording || !pending.isEmpty {
            openStream(run: run)
        } else {
            complete()
        }
    }
    private func closeStream() {
        streamID = UUID()
        sender?.cancel(); receiver?.cancel(); timeout?.cancel()
        sender = nil; receiver = nil; timeout = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
    }
    private func frame(audio: Data, status: Int) throws -> String {
        var body: [String: Any] = ["data": ["status": status, "format": "audio/L16;rate=16000", "encoding": "raw", "audio": audio.base64EncodedString()]]
        if status == 0 {
            body["common"] = ["app_id": credentials.appID]
            body["business"] = ["language": "zh_cn", "domain": "iat", "accent": "mandarin", "dwa": "wpgs", "vinfo": 0, "ptt": 1]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    }
    func stop() {
        guard busy else { return }
        if !recording { if socket == nil { cancel() }; return }
        capture?.stop(); capture = nil; recording = false; level = 0
        stopping = true
        status = "正在结束录音…"
        timer?.cancel()
    }
    func cancel() { cleanup(); status = "已停止，录音未保存" }
    func fail(_ message: String) { cleanup(); error = true; status = message }
    private func complete() {
        cleanup(cancelRefinement: false)
        busy = true
        status = "正在整理最后一段…"
        let run = token
        finalization = Task { [weak self] in
            guard let self else { return }
            let result = await self.refiner.finish()
            guard !Task.isCancelled, self.token == run else { return }
            self.text = result; self.busy = false; self.refining = false
            self.status = result.isEmpty ? "没有识别到文字，请检查麦克风后再试" : "听写完成"
            self.onFinished?()
        }
    }
    private func cleanup(cancelRefinement: Bool = true) {
        if cancelRefinement { finalization?.cancel(); finalization = nil; refiner.cancel(); refining = false }
        token = UUID()
        capture?.stop(); capture = nil
        closeStream()
        timer?.cancel(); timer = nil
        pending.removeAll(); recording = false; busy = false; level = 0
    }
    private static func explain(_ code: Int) -> String {
        switch code {
        case 10005, 10010, 10110, 11200: return "讯飞语音听写未授权（\(code)），请检查应用及普通话服务。"
        case 11201, 11202, 11203: return "讯飞服务额度不足或已到期（\(code)），请核对控制台。"
        default: return "讯飞返回错误 \(code)，已保留当前文字，请核对语音听写控制台。"
        }
    }
}
