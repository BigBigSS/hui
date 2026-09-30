import AppKit
import SwiftUI

private enum Style {
    static let accent = Color.blue
    static let soft = Color.primary.opacity(0.045)
    static let line = Color.primary.opacity(0.08)
}

struct MainView: View {
    @ObservedObject var model: AppModel
    let store: ClipboardHistoryStore
    let voice: VoiceInputController
    let recognition: VoiceRecognition
    let engine: MenuEngine
    let settings: AppSettings
    @State private var clipboardState: ClipboardBrowserState
    @State private var navigationUsesKeyboard = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var navigationGlass

    init(model: AppModel, store: ClipboardHistoryStore, voice: VoiceInputController, recognition: VoiceRecognition, engine: MenuEngine, settings: AppSettings) {
        self.model = model; self.store = store; self.voice = voice
        self.recognition = recognition; self.engine = engine; self.settings = settings
        _clipboardState = State(initialValue: ClipboardBrowserState(store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("hui").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).frame(height: 28)
            navigation.padding(.horizontal, 14).padding(.bottom, 14)
            Group {
                switch model.page {
                case .clipboard: ClipboardBrowserView(model: model, store: store, standalone: false, state: clipboardState)
                case .voice: VoicePage(model: model, voice: voice, recognition: recognition)
                case .menu: MenuPage(model: model, engine: engine)
                case .settings: SettingsPage(model: model, settings: settings, recognition: recognition, store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            if model.page != .clipboard { MessageStrip(model: model) }
        }
        .frame(width: 400).frame(maxHeight: .infinity)
        .background(PanelMaterial())
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(colorScheme == .dark ? 0.10 : 0.7)).frame(height: 0.5).allowsHitTesting(false) }
        .foregroundStyle(.primary).tint(.blue).ignoresSafeArea()
        .onChange(of: model.page) { _, _ in model.message = ""; voice.stopShortcutCapture() }
        .onChange(of: model.saveVoice) { _, value in UserDefaults.standard.set(value, forKey: "saveVoice") }
        .background(KeyListener { event in
            if !navigationUsesKeyboard { navigationUsesKeyboard = true }
            guard model.page != .clipboard, !voice.recordingShortcut, event.window?.attachedSheet == nil else { return false }
            if let input = event.window?.firstResponder as? NSTextInputClient, input.hasMarkedText() { return false }
            if event.keyCode == 53 { model.onHide?(); return true }
            return false
        })
    }

    @ViewBuilder private var navigation: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { navigationItems }.frame(height: 42)
        } else { navigationItems.frame(height: 42) }
    }
    private var navigationItems: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach([AppModel.Page.clipboard, .voice, .menu], id: \.self) { page in
                    Button { select(page) } label: {
                        navigationLabel(page)
                    }.buttonStyle(.plain).accessibilityAddTraits(model.page == page ? .isSelected : [])
                }
            }
            .padding(4)
            .background(Color.primary.opacity(colorScheme == .dark ? 0.13 : 0.055), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.045), lineWidth: 0.5).allowsHitTesting(false))
            Button { select(.settings) } label: {
                Image(systemName: "gearshape").font(.system(size: 14, weight: .medium))
                    .foregroundStyle(model.page == .settings ? Color.blue : .secondary)
                    .frame(width: 38, height: 38)
            }.buttonStyle(.plain).modifier(GlassSurface(radius: 20))
                .help("设置").accessibilityLabel("设置").accessibilityAddTraits(model.page == .settings ? .isSelected : [])
        }
        .focusEffectDisabled(!navigationUsesKeyboard)
    }
    @ViewBuilder private func navigationLabel(_ page: AppModel.Page) -> some View {
        let label = Label(page.rawValue, systemImage: page.icon)
            .font(.system(size: 11, weight: model.page == page ? .semibold : .medium))
            .foregroundStyle(model.page == page ? Color.blue : .secondary)
            .frame(maxWidth: .infinity).frame(height: 34)
            .contentShape(Capsule())
        if model.page == page, #available(macOS 26.0, *) {
            label
                .glassEffect(.regular.tint(.blue.opacity(0.08)).interactive(), in: .capsule)
                .glassEffectID("selected-page", in: navigationGlass)
                .overlay(Capsule().strokeBorder(.blue.opacity(0.24), lineWidth: 0.65))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.25 : 0.10), radius: 3, y: 2)
        } else if model.page == page {
            label.background {
                Capsule().fill(Color(nsColor: .controlBackgroundColor))
                    .matchedGeometryEffect(id: "selected-page", in: navigationGlass)
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
            }
        } else { label }
    }
    private func select(_ page: AppModel.Page) {
        // Pointer selection should not leave a keyboard ring on another tab.
        let eventType = NSApp.currentEvent?.type
        navigationUsesKeyboard = eventType == .keyDown || eventType == .keyUp
        guard model.page != page else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.86)) { model.page = page }
    }
}

private struct VoicePage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var voice: VoiceInputController
    @ObservedObject var recognition: VoiceRecognition
    @State private var showOriginal = false
    @State private var termsOpen = false
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: recognition.recording ? "waveform" : "mic")
                    .font(.system(size: 24, weight: .light)).frame(width: 48, height: 48)
                    .background(Style.soft, in: RoundedRectangle(cornerRadius: 14))
                    .scaleEffect(recognition.recording ? 1 + CGFloat(recognition.level) * 0.12 : 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(recognition.recording ? "正在聆听" : (recognition.busy ? "识别中" : "语音输入")).font(.system(size: 14, weight: .semibold))
                    Text(recognition.busy ? "\(recognition.elapsed)s" : "普通话").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { voice.captureShortcut() } label: {
                    Text(voice.recordingShortcut ? "请按快捷键" : voice.shortcutLabel).font(.system(size: 12, weight: .medium, design: .monospaced)).padding(.horizontal, 8).padding(.vertical, 5)
                }.buttonStyle(.bordered).controlSize(.small).help("修改快捷键")
            }
            if !voice.shortcutMessage.isEmpty { Text(voice.shortcutMessage).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(recognition.busy ? recognition.refinementStatus : "最近转写").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    if !recognition.rawText.isEmpty {
                        Button(showOriginal ? "看整理稿" : "看原文") { showOriginal.toggle() }.buttonStyle(.plain).font(.system(size: 10))
                    }
                    Spacer()
                    if !recognition.text.isEmpty {
                        Button { model.saveTranscript() } label: { Image(systemName: "square.and.arrow.down") }.buttonStyle(.plain).help("存入剪贴板").accessibilityLabel("存入剪贴板")
                    }
                }
                if recognition.text.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "waveform").font(.system(size: 28, weight: .ultraLight)).foregroundStyle(.tertiary)
                        Text(recognition.error ? recognition.status : "暂无转写").font(.system(size: 12)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView { Text(showOriginal ? recognition.rawText : recognition.text).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    if !voice.deliveryStatus.isEmpty { Text(voice.deliveryStatus).font(.system(size: 10)).foregroundStyle(.secondary) }
                }
            }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(ContentSurface(radius: 13))
                
            HStack {
                Button { termsOpen = true } label: { Label("专有名词", systemImage: "character.book.closed").font(.system(size: 11)) }
                    .buttonStyle(.plain).disabled(recognition.busy)
                Spacer()
                if recognition.recording { Button("停止录音") { voice.release() }.buttonStyle(.bordered) }
            }
            if recognition.aiEnabled && recognition.aiConfiguration == nil {
                Text("AI 尚未连接，当前保留讯飞原文。请到设置连接文字处理服务。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if !model.accessibility || !model.microphone || !recognition.credentials.valid {
                Button { model.page = .settings } label: { Label("权限与连接", systemImage: "exclamationmark.circle").font(.system(size: 11)) }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 16).padding(.top, 4)
            .sheet(isPresented: $termsOpen) { VoiceTermsView(recognition: recognition) }
    }
}

private struct MenuPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: MenuEngine
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "menubar.rectangle").font(.system(size: 23, weight: .light)).frame(width: 48, height: 48).background(Style.soft, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text("菜单栏").font(.system(size: 14, weight: .semibold))
                    Text(engine.statusLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("展开  ⌃⌥I") { model.showBar() }.buttonStyle(.bordered).controlSize(.small).disabled(!engine.running)
            }
            VStack(spacing: 0) {
                settingRow("悬停展开", icon: "cursorarrow") { Toggle("悬停展开", isOn: Binding(get: { engine.hover }, set: { engine.setHover($0) })).labelsHidden().toggleStyle(.switch).controlSize(.mini) }
                Divider()
                settingRow("排列图标", icon: "square.grid.3x1") { Button { engine.arrange() } label: { Image(systemName: "chevron.right").frame(width: 24, height: 22) }.buttonStyle(.plain).accessibilityLabel("排列图标").disabled(!engine.running) }
            }.padding(.horizontal, 12).modifier(ContentSurface(radius: 12))
            HStack {
                if !engine.error.isEmpty { Text(engine.error).font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button(engine.running ? "刷新" : "权限设置") { if engine.running { engine.restart() } else { model.page = .settings } }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 16).padding(.top, 4)
    }
}

private struct SettingsPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var recognition: VoiceRecognition
    @ObservedObject var store: ClipboardHistoryStore
    @State private var credentialsOpen = false
    @State private var aiOpen = false
    @State private var appID = ""
    @State private var apiKey = ""
    @State private var apiSecret = ""
    @State private var credentialMessage = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(spacing: 0) {
                    settingRow("登录时启动", icon: "power") { Toggle("登录时启动", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLogin($0) })).labelsHidden().toggleStyle(.switch).controlSize(.mini) }
                    Divider()
                    settingRow("剪贴板收集", icon: "square.on.square") { Toggle("剪贴板收集", isOn: Binding(get: { !model.paused }, set: { _ in model.toggleMonitoring() })).labelsHidden().toggleStyle(.switch).controlSize(.mini) }
                    Divider()
                    settingRow("语音存入历史", icon: "waveform") { Toggle("语音存入历史", isOn: $model.saveVoice).labelsHidden().toggleStyle(.switch).controlSize(.mini) }
                    Divider()
                    settingRow("历史上限", icon: "tray") { Picker("历史上限", selection: $settings.maxHistoryItems) { ForEach(AppSettings.maxHistoryOptions, id: \.self) { Text("\($0) 条").tag($0) } }.labelsHidden().frame(width: 88).controlSize(.small) }
                }.padding(.horizontal, 12).modifier(ContentSurface(radius: 12))
                VStack(spacing: 0) {
                    permission("辅助功能", icon: "hand.raised", granted: model.accessibility) { model.openPrivacy("Privacy_Accessibility") }
                    Divider()
                    permission("麦克风", icon: "mic", granted: model.microphone) { model.requestMicrophone(); model.openPrivacy("Privacy_Microphone") }
                    Divider()
                    permission("菜单栏图像", icon: "menubar.rectangle", granted: model.screenRecording) { model.requestScreenRecording() }
                    Divider()
                    settingRow("讯飞听写", icon: "network") { HStack(spacing: 6) { Button(recognition.loadingCredentials ? "连接中" : (recognition.credentials.valid ? "已连接" : "连接")) {
                        if recognition.credentials.valid { credentialsOpen = true } else { recognition.loadCredentials() }
                    }.disabled(recognition.loadingCredentials).buttonStyle(.bordered).controlSize(.small)
                        Menu { Button("更换配置…") { credentialsOpen = true } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 18).accessibilityLabel("语音服务选项")
                    } }
                }.padding(.horizontal, 12).modifier(ContentSurface(radius: 12))
                VStack(spacing: 0) {
                    settingRow("AI 纠错与分段", icon: "sparkles") {
                        Toggle("AI 纠错与分段", isOn: $recognition.aiEnabled).labelsHidden().toggleStyle(.switch).controlSize(.mini).disabled(recognition.busy)
                    }
                    Divider()
                    settingRow("文字处理服务", icon: "text.badge.checkmark") {
                        Button(recognition.aiConfiguration == nil ? "连接" : "已配置") { aiOpen = true }.buttonStyle(.bordered).controlSize(.small).disabled(recognition.busy)
                    }
                    Text("开启后，转写文字会发送至配置的 AI 服务；录音仍仅发送至讯飞。AI 超时保留原文。")
                        .font(.system(size: 10)).foregroundStyle(.secondary).padding(.bottom, 10)
                }.padding(.horizontal, 12).modifier(ContentSurface(radius: 12))
                HStack { Text("⌘⇧C 剪贴板"); Spacer(); Text("⌃⌥Space hui") }.font(.system(size: 10)).foregroundStyle(.secondary)
                HStack {
                    Text("\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") · \(store.storageSizeDescription())").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                    Button("退出 hui") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if !model.shortcutOK { Text("快捷键被占用，请退出旧剪贴板应用。") .font(.caption).foregroundStyle(.orange) }
            }.padding(.horizontal, 16)
        }.sheet(isPresented: $credentialsOpen) { credentialsView }
        .sheet(isPresented: $aiOpen) { VoiceAISettingsView(recognition: recognition) }
    }
    private func permission(_ name: String, icon: String, granted: Bool, action: @escaping () -> Void) -> some View {
        settingRow(name, icon: icon) {
            Button(granted ? "已开启" : "开启", action: action).buttonStyle(.bordered).controlSize(.small)
        }
    }
    private var credentialsView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("讯飞听写").font(.system(size: 14, weight: .semibold)); Spacer(); Button("取消") { credentialsOpen = false }.keyboardShortcut(.cancelAction) }
            TextField("APPID", text: $appID).textFieldStyle(.roundedBorder)
            SecureField("API Key", text: $apiKey).textFieldStyle(.roundedBorder)
            SecureField("API Secret", text: $apiSecret).textFieldStyle(.roundedBorder)
            Text("密钥保存在本机钥匙串。录音发送至讯飞识别，不保存在本机。").font(.system(size: 10)).foregroundStyle(.secondary)
            if !credentialMessage.isEmpty { Text(credentialMessage).font(.caption).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("保存") {
                let value = VoiceCredentials(appID: appID.trimmingCharacters(in: .whitespacesAndNewlines), apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines), apiSecret: apiSecret.trimmingCharacters(in: .whitespacesAndNewlines))
                guard value.valid else { credentialMessage = "请填写完整的三项配置"; return }
                do { try value.save(); recognition.credentials = value; apiKey = ""; apiSecret = ""; credentialsOpen = false; model.message = "已保存" } catch { credentialMessage = error.localizedDescription }
            }.buttonStyle(.borderedProminent) }
        }.padding(20).frame(width: 380)
    }
}

@MainActor
private func settingRow<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
    HStack(spacing: 9) {
        Image(systemName: icon).font(.system(size: 12)).frame(width: 18).foregroundStyle(.secondary)
        Text(title).font(.system(size: 12)); Spacer(); content()
    }.frame(height: 39)
}

struct MessageStrip: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Text(model.message).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 17).frame(height: 28)
    }
}
struct ContentSurface: ViewModifier {
    var radius: CGFloat = 12
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .textBackgroundColor).opacity(colorScheme == .dark ? 0.40 : 0.72), in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.primary.opacity(0.065), lineWidth: 0.5))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.12 : 0.025), radius: 4, y: 2)
    }
}
struct PanelMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.material = .popover; view.blendingMode = .behindWindow; view.state = .active; return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
struct GlassSurface: ViewModifier {
    var radius: CGFloat = 20
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.glassEffect(.regular, in: .rect(cornerRadius: radius)) }
        else { content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius)) }
    }
}
struct KeyListener: NSViewRepresentable {
    let action: (NSEvent) -> Bool
    final class Host: NSView {
        var monitor: Any?
        var action: ((NSEvent) -> Bool)?
        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { guard let self, event.window === self.window else { return false }; return self.action?(event) == true }
                return handled ? nil : event
            }
        }
    }
    static func dismantleNSView(_ nsView: Host, coordinator: ()) { if let monitor = nsView.monitor { NSEvent.removeMonitor(monitor); nsView.monitor = nil } }
    func makeNSView(context: Context) -> Host { let host = Host(); host.action = action; return host }
    func updateNSView(_ nsView: Host, context: Context) { nsView.action = action }
}

private struct VoiceAISettingsView: View {
    @ObservedObject var recognition: VoiceRecognition
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var model = "gpt-5.6-luna"
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("AI 纠错与分段").font(.headline); Spacer(); Button("取消") { dismiss() } }
            TextField("接口地址（HTTPS，以 /v1 结尾）", text: $baseURL).textFieldStyle(.roundedBorder)
            SecureField(recognition.aiConfiguration == nil ? "API Key" : "API Key（留空沿用）", text: $apiKey).textFieldStyle(.roundedBorder)
            TextField("模型", text: $model).textFieldStyle(.roundedBorder)
            Text("密钥保存在本机钥匙串。只处理本次转写，不发送剪贴板历史。说话时整理前文，讯飞完成后 AI 最多额外等待 2 秒。")
                .font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("保存") {
                let config = VoiceAIConfiguration(baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                    apiKey: apiKey.isEmpty ? (recognition.aiConfiguration?.apiKey ?? "") : apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                    model: model.trimmingCharacters(in: .whitespacesAndNewlines))
                do { try config.save(); recognition.aiConfiguration = config; apiKey = ""; dismiss() }
                catch { message = error.localizedDescription }
            }.buttonStyle(.borderedProminent) }
        }.padding(20).frame(width: 380)
        .onAppear { baseURL = recognition.aiConfiguration?.baseURL ?? ""; model = recognition.aiConfiguration?.model ?? "gpt-5.6-luna" }
    }
}

private struct VoiceTermsView: View {
    @ObservedObject var recognition: VoiceRecognition
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("专有名词").font(.headline); Spacer(); Button("取消") { dismiss() } }
            Text("每行填写一个正确名称。系统名、产品名、客户姓名都可以添加；修改或删除对应行即可更新。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text("也可填写：正确名称 = 常见误识别一、常见误识别二")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            TextEditor(text: $draft).font(.system(size: 14)).frame(height: 210)
                .padding(6).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("专有名词列表，每行一个")
            Text("保存在本机，AI 整理时随本次文字发送。保存后从下一次录音生效；词表用于辅助判断，不强制替换相似词。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.orange) }
            HStack {
                Text("\(draft.split(whereSeparator: \.isNewline).count) 条 / 最多 100 条").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("保存") {
                    let terms = draft.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    guard terms.count <= 100, draft.count <= 6000, terms.allSatisfy({ $0.count <= 120 }) else {
                        message = "最多 100 条、共 6000 字，每条不超过 120 字。"; return
                    }
                    var seen = Set<String>()
                    recognition.customTerms = terms.filter { seen.insert($0).inserted }.joined(separator: "\n")
                    dismiss()
                }.buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 440)
            .onAppear { draft = recognition.customTerms }
    }
}
