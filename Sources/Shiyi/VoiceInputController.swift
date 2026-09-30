import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import Combine
import SwiftUI

private final class VoiceIndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class VoiceInputController: NSObject, ObservableObject {
    let recognition = VoiceRecognition()
    @Published var shortcutLabel = UserDefaults.standard.string(forKey: "voiceShortcutLabel") ?? "⌃⇧Space"
    @Published var shortcutMessage = ""
    @Published var recordingShortcut = false
    @Published var deliveryStatus = ""
    var onWillRecord: (() -> Void)?
    var onTranscriptReady: ((String) -> Void)?
    private var indicator: NSPanel?
    private var hotKey: GlobalHotKey?
    private var targetApplication: NSRunningApplication?
    private var targetElement: AXUIElement?
    private var keyMonitor: Any?
    private var keyCode = UInt32(UserDefaults.standard.object(forKey: "voiceKeyCode") as? Int ?? 49)
    private var modifiers = UInt32(UserDefaults.standard.object(forKey: "voiceModifiers") as? Int ?? Int(controlKey | shiftKey))
    private var pressed = false
    private var finishedWhileHeld = false
    private var hideTask: Task<Void, Never>?
    private var deliveryTask: Task<Void, Never>?
    private var observation: AnyCancellable?
    private var generation = UUID()

    override init() {
        super.init()
        recognition.onFinished = { [weak self] in
            guard let self else { return }
            self.onTranscriptReady?(self.recognition.text)
            if self.pressed { self.finishedWhileHeld = true } else { self.deliver() }
        }
        observation = recognition.$busy.dropFirst().sink { [weak self] busy in
            guard !busy else { return }
            Task { @MainActor in
                guard let self else { return }
                if self.recognition.error { self.deliveryStatus = self.recognition.status; self.hideAfter(seconds: 5) }
            }
        }
    }
    func registerShortcut() {
        hotKey?.unregister()
        hotKey = GlobalHotKey(id: 2, keyCode: keyCode, modifiers: modifiers,
            onReleased: { [weak self] in Task { @MainActor in self?.release() } },
            onPressed: { [weak self] in Task { @MainActor in self?.hold() } })
        if hotKey?.register() != true { shortcutMessage = "快捷键被占用，请换一组。" }
    }
    func hold() {
        guard !recordingShortcut, !pressed, !recognition.busy, deliveryTask == nil else { return }
        deliveryStatus = ""
        hideTask?.cancel()
        onWillRecord?()
        showIndicator()
        guard recognition.credentials.valid else {
            recognition.loadCredentials()
            deliveryStatus = "请完成钥匙串确认后重试"
            hideAfter(seconds: 4)
            return
        }
        guard CGPreflightPostEventAccess() else { deliveryStatus = "请在系统辅助功能中允许自动输入"; hideAfter(seconds: 4); return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let element = focusedElement(pid: app.processIdentifier) else {
            deliveryStatus = "请先点击要输入文字的位置，再按住快捷键"; showIndicator(); hideAfter(seconds: 3); return
        }
        var secureRole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &secureRole)
        guard secureRole as? String != kAXSecureTextFieldSubrole as String else { return }
        targetApplication = app; targetElement = element
        pressed = true; finishedWhileHeld = false; generation = UUID(); hideTask?.cancel()
        deliveryStatus = ""
        onWillRecord?()
        showIndicator()
        recognition.start()
    }
    func release() {
        guard pressed else { return }
        pressed = false
        if finishedWhileHeld { finishedWhileHeld = false; deliver(); return }
        recognition.stop()
        if !recognition.busy { hideAfter(seconds: 2) }
    }
    private func focusedElement(pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let editableRoles = [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String]
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        guard editableRoles.contains(role as? String ?? "") || settable.boolValue else { return nil }
        return element
    }
    private func deliver() {
        guard !recognition.text.isEmpty else { deliveryStatus = "没有听清，请再试一次"; hideAfter(seconds: 2); return }
        let run = generation
        deliveryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.deliveryTask = nil }
            // Wait for the shortcut modifiers as well as its primary key to be released.
            for _ in 0..<40 {
                let flags = CGEventSource.flagsState(.combinedSessionState)
                if flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty && !self.pressed { break }
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, self.generation == run else { return }
            }
            guard !self.pressed,
                  CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty,
                  let app = self.targetApplication, !app.isTerminated,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                  let original = self.targetElement,
                  let current = self.focusedElement(pid: app.processIdentifier), CFEqual(original, current) else {
                self.deliveryStatus = "输入位置已变化，文字保留在语音页"; self.hideAfter(seconds: 4); return
            }
            guard CGPreflightPostEventAccess(),
                  let source = CGEventSource(stateID: .combinedSessionState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
                self.deliveryStatus = "自动输入需要辅助功能权限"; self.hideAfter(seconds: 4); return
            }
            let pasteboard = NSPasteboard.general
            let previous = (pasteboard.pasteboardItems ?? []).map { item in
                item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                    guard let data = item.data(forType: type) else { return nil }; return (type, data)
                }
            }
            let payload = NSPasteboardItem()
            payload.setString(self.recognition.text, forType: .string)
            payload.setString("voice", forType: ClipboardHistoryStore.internalPasteboardWriteType)
            pasteboard.clearContents(); pasteboard.writeObjects([payload])
            let count = pasteboard.changeCount
            down.flags = .maskCommand; up.flags = .maskCommand
            down.postToPid(app.processIdentifier); up.postToPid(app.processIdentifier)
            self.deliveryStatus = "已输入"
            try? await Task.sleep(for: .milliseconds(650))
            if pasteboard.changeCount == count {
                pasteboard.clearContents()
                let restored = previous.map { values in
                    let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item
                }
                if !restored.isEmpty { pasteboard.writeObjects(restored) }
            }
            self.hideAfter(seconds: 0.5)
        }
    }
    private func showIndicator() {
        if indicator == nil {
            let panel = VoiceIndicatorPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 242), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.level = .floating; panel.hidesOnDeactivate = false; panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: VoiceIndicatorView(controller: self, model: recognition))
            indicator = panel
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        if let frame = screen?.visibleFrame { indicator?.setFrameOrigin(NSPoint(x: frame.midX - 260, y: frame.minY + 16)) }
        indicator?.orderFrontRegardless()
    }
    private func hideAfter(seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }; self?.indicator?.orderOut(nil)
        }
    }
    func shutdown() {
        stopShortcutCapture(); hotKey?.unregister(); hideTask?.cancel(); deliveryTask?.cancel(); recognition.cancel(); indicator?.orderOut(nil)
    }
    func captureShortcut() {
        stopShortcutCapture()
        hotKey?.unregister()
        recordingShortcut = true
        shortcutMessage = "按下新的组合键（包含 ⌘、⌃ 或 ⌥），Esc 取消"
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed: Bool = MainActor.assumeIsolated {
                guard let self, self.recordingShortcut else { return false }
                if event.keyCode == 53 { self.stopShortcutCapture(); self.shortcutMessage = "已取消修改"; return true }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else { self.shortcutMessage = "请加上 ⌘、⌃ 或 ⌥ 修饰键"; return true }
                var mods: UInt32 = 0
                var label = ""
                if flags.contains(.control) { mods |= UInt32(controlKey); label += "⌃" }
                if flags.contains(.option) { mods |= UInt32(optionKey); label += "⌥" }
                if flags.contains(.shift) { mods |= UInt32(shiftKey); label += "⇧" }
                if flags.contains(.command) { mods |= UInt32(cmdKey); label += "⌘" }
                if (event.keyCode == 8 && mods == UInt32(cmdKey | shiftKey)) || (event.keyCode == 34 && mods == UInt32(controlKey | optionKey)) || (event.keyCode == 49 && mods == UInt32(controlKey | optionKey)) { self.shortcutMessage = "这组快捷键已用于 hui，请换一组"; return true }
                label += event.keyCode == 49 ? "Space" : (event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)")
                let oldKey = self.keyCode, oldModifiers = self.modifiers
                self.hotKey?.unregister()
                self.keyCode = UInt32(event.keyCode); self.modifiers = mods
                self.registerShortcut()
                if self.hotKey?.register() == true {
                    self.shortcutLabel = label
                    UserDefaults.standard.set(Int(self.keyCode), forKey: "voiceKeyCode")
                    UserDefaults.standard.set(Int(mods), forKey: "voiceModifiers")
                    UserDefaults.standard.set(label, forKey: "voiceShortcutLabel")
                    self.shortcutMessage = "快捷键已保存：\(label)"
                    self.stopShortcutCapture()
                } else {
                    self.keyCode = oldKey; self.modifiers = oldModifiers; self.registerShortcut()
                    self.shortcutMessage = "这组快捷键被占用，请换一组"
                }
                return true
            }
            return consumed ? nil : event
        }
    }
    func stopShortcutCapture() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        let wasRecording = recordingShortcut
        recordingShortcut = false
        if wasRecording { registerShortcut() }
    }
}


struct VoiceIndicatorView: View {
    @ObservedObject var controller: VoiceInputController
    @ObservedObject var model: VoiceRecognition
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: model.recording ? "waveform" : "mic")
                    .font(.system(size: 17, weight: .medium))
                    .scaleEffect(model.recording ? 1 + CGFloat(model.level) * 0.25 : 1)
                Text(model.recording ? "正在聆听 · 停顿后可继续说" : model.status)
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                if model.busy { Text("\(model.elapsed)s").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary) }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.text.isEmpty ? "说出的文字会实时显示在这里…" : model.text)
                            .font(.system(size: 15)).lineSpacing(6)
                            .foregroundStyle(model.text.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("tail")
                    }
                }
                .onChange(of: model.text) { _, _ in proxy.scrollTo("tail", anchor: .bottom) }
            }
            HStack {
                Text(controller.deliveryStatus.isEmpty ? model.refinementStatus : controller.deliveryStatus)
                    .lineLimit(1)
                Spacer()
                if model.recording { Text("松开后输入") }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(16).frame(width: 512, height: 234)
            .foregroundStyle(.primary).modifier(GlassSurface(radius: 20)).padding(4)
    }
}
