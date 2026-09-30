import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum Page: String, CaseIterable { case clipboard = "剪贴板", voice = "语音", menu = "菜单栏", settings = "设置"
        var panelHeight: CGFloat { switch self { case .clipboard: 520; case .voice: 430; case .menu: 300; case .settings: 460 } }
        var icon: String { switch self { case .clipboard: "square.on.square"; case .voice: "waveform"; case .menu: "menubar.rectangle"; case .settings: "slider.horizontal.3" } }
    }
    let settings = AppSettings()
    lazy var store = ClipboardHistoryStore(settings: settings)
    let voice = VoiceInputController()
    let engine = MenuEngine()
    @Published var page: Page = Page(rawValue: UserDefaults.standard.string(forKey: "lastPage") ?? "") ?? .clipboard { didSet { UserDefaults.standard.set(page.rawValue, forKey: "lastPage") } }
    @Published var message = ""
    @Published var accessibility = false
    @Published var microphone = false
    @Published var screenRecording = false
    @Published var launchAtLogin = false
    @Published var paused = false
    @Published var saveVoice = UserDefaults.standard.bool(forKey: "saveVoice")
    @Published var shortcutOK = true
    var onShow: (() -> Void)?
    var onShowClipboard: (() -> Void)?
    var onHide: (() -> Void)?
    var pasteTarget: NSRunningApplication?
    var monitor: ClipboardMonitor?
    private var clipboardKey: GlobalHotKey?
    private var mainKey: GlobalHotKey?
    private var menuKey: GlobalHotKey?
    private var timer: Timer?
    private var observation: AnyCancellable?
    private var pendingPaste: DispatchWorkItem?

    func start() {
        voice.recognition.loadCredentials(allowPrompt: false)
        monitor = ClipboardMonitor(store: store); monitor?.start()
        voice.onWillRecord = { [weak self] in self?.engine.hide(); self?.onHide?() }
        voice.registerShortcut()
        voice.onTranscriptReady = { [weak self] text in
            guard let self, self.saveVoice else { return }; self.store.addText(text)
        }
        clipboardKey = GlobalHotKey { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.paused { self.monitor?.checkClipboard() }
                self.onShowClipboard?()
            }
        }
        shortcutOK = clipboardKey?.register() == true
        mainKey = GlobalHotKey(id: 4, keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            MainActor.assumeIsolated { self?.onShow?() }
        }
        _ = mainKey?.register()
        menuKey = GlobalHotKey(id: 5, keyCode: UInt32(kVK_ANSI_I), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            MainActor.assumeIsolated { self?.showBar() }
        }
        _ = menuKey?.register()
        refreshPermissions()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions(); self?.engine.refresh() }
        }
        engine.start()
    }
    func stop() { timer?.invalidate(); monitor?.stop(); voice.shutdown(); clipboardKey?.unregister(); mainKey?.unregister(); menuKey?.unregister(); pendingPaste?.cancel(); engine.stop() }
    func refreshPermissions() {
        let nextAccessibility = AXIsProcessTrusted()
        let nextMicrophone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let nextScreenRecording = CGPreflightScreenCaptureAccess()
        let nextLaunchAtLogin = SMAppService.mainApp.status == .enabled
        if accessibility != nextAccessibility { accessibility = nextAccessibility }
        if microphone != nextMicrophone { microphone = nextMicrophone }
        if screenRecording != nextScreenRecording { screenRecording = nextScreenRecording }
        if launchAtLogin != nextLaunchAtLogin { launchAtLogin = nextLaunchAtLogin }
    }
    func setLogin(_ value: Bool) {
        do { if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; refreshPermissions() }
        catch { message = "自动启动设置未完成：\(error.localizedDescription)" }
    }
    func toggleMonitoring() { paused.toggle(); if paused { monitor?.stop() } else { monitor?.start() } }
    func openPrivacy(_ anchor: String) {
        engine.hide(); onHide?()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in Task { @MainActor in self?.refreshPermissions() } }
    }
    func requestScreenRecording() {
        engine.hide(); onHide?()
        _ = CGRequestScreenCaptureAccess()
        refreshPermissions()
        if !screenRecording { openPrivacy("Privacy_ScreenCapture") }
    }
    func copy(_ item: ClipboardHistoryItem) { message = store.copy(item) ? "已复制" : "这条内容暂时无法复制" }
    func paste(_ item: ClipboardHistoryItem) {
        guard store.copy(item) else { message = "复制失败，请检查原始文件"; return }
        guard accessibility else { message = "已复制。开启辅助功能后，可以直接粘贴到输入框"; return }
        guard let target = pasteTarget, !target.isTerminated else { message = "已复制，请切换到要粘贴的位置"; return }
        onHide?(); target.activate(options: [])
        let pid = target.processIdentifier
        pendingPaste?.cancel()
        let work = DispatchWorkItem {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            guard let source = CGEventSource(stateID: .combinedSessionState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
            down.flags = .maskCommand; up.flags = .maskCommand; down.postToPid(pid); up.postToPid(pid)
        }
        pendingPaste = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }
    func showBar(anchor: NSRect? = nil) {
        onHide?()
        engine.toggle(anchor: anchor)
    }
    func saveTranscript() { guard !voice.recognition.text.isEmpty else { return }; store.addText(voice.recognition.text); message = "已收进剪贴板" }
}
