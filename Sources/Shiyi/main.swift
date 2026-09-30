import AppKit
import SwiftUI
import Combine
import QuartzCore

@MainActor
final class ShiyiPanel: NSPanel { override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { true } }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel!
    var panel: ShiyiPanel!
    var statusItem: NSStatusItem!
    private var clipboardPanel: ClipboardPanelController!
    private var pageObservation: AnyCancellable?
    private var barObservation: AnyCancellable?
    private var presentation = 0
    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenus()
        migrateHistory()
        model = AppModel()
        let icon = NSImage(contentsOf: Bundle.main.url(forResource: "AppIcon", withExtension: "png") ?? URL(fileURLWithPath: "/"))
        if let icon { NSApp.applicationIconImage = icon }
        panel = ShiyiPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: model.page.panelHeight), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "hui"; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .clear; panel.isOpaque = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true; panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: MainView(model: model, store: model.store, voice: model.voice, recognition: model.voice.recognition, engine: model.engine, settings: model.settings))
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        panel.contentView = hosting
        panel.center()
        clipboardPanel = ClipboardPanelController(model: model)
        pageObservation = model.$page.dropFirst().removeDuplicates().sink { [weak self] page in
            DispatchQueue.main.async { [weak self] in
            guard let self, self.model.page == page, let panel = self.panel else { return }
            guard abs(panel.frame.height - page.panelHeight) > 0.5 || abs(panel.frame.width - 400) > 0.5 else { return }
            var frame = panel.frame
            frame.origin.y += frame.height - page.panelHeight
            frame.size = NSSize(width: 400, height: page.panelHeight)
            if let screen = panel.screen ?? NSScreen.main {
                let visible = screen.visibleFrame
                frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - frame.width))
                frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - frame.height))
            }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !panel.isVisible {
                panel.setFrame(frame, display: true)
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    panel.animator().setFrame(frame, display: true)
                }
            }
            }
        }
        if UserDefaults.standard.object(forKey: "NSStatusItem Preferred Position ShiyiStatus") == nil { UserDefaults.standard.set(0, forKey: "NSStatusItem Preferred Position ShiyiStatus") }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "ShiyiStatus"
        let menuIcon = Bundle.main.url(forResource: "HuiMenuBarTemplate", withExtension: "pdf").flatMap(NSImage.init(contentsOf:))
        menuIcon?.size = NSSize(width: 18, height: 18)
        statusItem.button?.image = menuIcon ?? NSImage(systemSymbolName: "h.circle", accessibilityDescription: "hui")
        statusItem.button?.image?.isTemplate = true; statusItem.button?.toolTip = "hui · 剪贴板、语音与菜单栏"
        statusItem.button?.target = self; statusItem.button?.action = #selector(statusClick)
        statusItem.button?.window?.title = "Shiyi.StatusItem"
        statusItem.button?.setAccessibilityLabel("hui 菜单栏")
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        if let cell = statusItem.button?.cell as? NSButtonCell {
            cell.showsStateBy = .changeBackgroundCellMask
        }
        barObservation = model.engine.$visible.removeDuplicates().sink { [weak self] visible in
            self?.statusItem.button?.state = visible ? .on : .off
        }
        model.onShow = { [weak self] in self?.show() }
        model.onShowClipboard = { [weak self] in
            self?.model.engine.hide()
            self?.panel.orderOut(nil)
            self?.clipboardPanel.toggle()
        }
        model.onHide = { [weak self] in
            guard let self else { return }
            self.presentation += 1
            self.clipboardPanel.hide(); self.panel.orderOut(nil)
        }
        model.engine.onOpenMain = { [weak self] anchor in self?.show(anchor: anchor) }
        model.engine.onOpenSettings = { [weak self] in
            guard let self else { return }
            self.model.page = .settings
            self.show(anchor: self.statusItem.button?.window?.frame)
        }
        model.engine.onNeedsAttention = { [weak self] in
            guard let self else { return }
            self.model.page = .menu
            self.show(anchor: self.statusItem.button?.window?.frame)
        }
        model.start()
    }
    private func configureMenus() {
        let menu = NSMenu()
        let application = NSMenuItem(); application.submenu = NSMenu(title: "hui")
        application.submenu?.addItem(withTitle: "退出 hui", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(application)
        let edit = NSMenuItem(); edit.submenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.submenu?.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        menu.addItem(edit)
        let window = NSMenuItem(); window.submenu = NSMenu(title: "窗口")
        let openMain = NSMenuItem(title: "打开 hui", action: #selector(openMainWindow), keyEquivalent: "")
        openMain.target = self
        window.submenu?.addItem(openMain)
        let openBar = NSMenuItem(title: "展开菜单栏", action: #selector(toggleMenuBar), keyEquivalent: "")
        openBar.target = self
        window.submenu?.addItem(openBar)
        window.submenu?.addItem(.separator())
        window.submenu?.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(window); NSApp.mainMenu = menu
    }
    @objc func statusClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let item = NSMenuItem(title: "打开 hui", action: #selector(openMainWindow), keyEquivalent: "")
            item.target = self; menu.addItem(item)
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出 hui", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            statusItem.button?.state = model.engine.visible ? .on : .off
        } else { toggleMenuBar() }
    }
    @objc private func toggleMenuBar() { model.showBar(anchor: statusItem.button?.window?.frame) }
    @objc private func openMainWindow() { show(anchor: statusItem.button?.window?.frame) }
    func show(anchor: NSRect? = nil) {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { model.pasteTarget = app }
        clipboardPanel.hide()
        model.engine.hide()
        presentation += 1
        let generation = presentation
        let wasVisible = panel.isVisible
        if let anchor = anchor ?? statusItem.button?.window?.frame {
            let anchorCenter = NSPoint(x: anchor.midX, y: anchor.midY)
            let screen = NSScreen.screens.first(where: { $0.frame.contains(anchorCenter) })
                ?? NSScreen.screens.first(where: { $0.frame.intersects(anchor) })
                ?? panel.screen ?? NSScreen.main
            if let screen {
                let area = screen.visibleFrame.insetBy(dx: 8, dy: 8)
                let size = NSSize(width: 400, height: model.page.panelHeight)
                // The entry can be in the floating icon bar; it only anchors the
                // display and horizontal edge. The main panel sits below the menu bar.
                panel.setFrame(NSRect(x: max(area.minX, min(anchor.maxX - size.width, area.maxX - size.width)),
                                      y: max(area.minY, area.maxY - size.height),
                                      width: size.width, height: size.height), display: false)
            }
        }
        let animate = !wasVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let destination = panel.frame
        if animate { panel.alphaValue = 0; panel.setFrameOrigin(NSPoint(x: destination.minX, y: destination.minY + 5)) }
        else { panel.alphaValue = 1 }
        NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(destination, display: true)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.presentation == generation else { return }
                    self.panel.alphaValue = 1
                }
            }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { show(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { clipboardPanel?.shutdown(); model?.stop() }
    private func migrateHistory() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let destination = base.appendingPathComponent("Shiyi")
        guard !fm.fileExists(atPath: destination.path) else { return }
        let staging = base.appendingPathComponent("Shiyi-Migration-" + UUID().uuidString)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            var records: [[String: Any]] = []
            var ids = Set<String>()
            for name in ["MaClipHistory", "MaClipHistory-Voice-Demo"] {
                let source = base.appendingPathComponent(name)
                let history = source.appendingPathComponent("clipboard-history-native.json")
                guard fm.fileExists(atPath: history.path) else { continue }
                let data = try Data(contentsOf: history)
                guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
                for entry in entries {
                    guard let id = entry["id"] as? String, ids.insert(id).inserted else { continue }
                    records.append(entry)
                }
                for name in ["Images", "Files"] {
                    let src = source.appendingPathComponent(name), dst = staging.appendingPathComponent(name)
                    try fm.createDirectory(at: dst, withIntermediateDirectories: true)
                    if fm.fileExists(atPath: src.path) {
                        for file in try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) {
                            let target = dst.appendingPathComponent(file.lastPathComponent)
                            if !fm.fileExists(atPath: target.path) { try fm.copyItem(at: file, to: target) }
                        }
                    }
                }
            }
            records.sort { ($0["timestamp"] as? String ?? "") > ($1["timestamp"] as? String ?? "") }
            try JSONSerialization.data(withJSONObject: records).write(to: staging.appendingPathComponent("clipboard-history-native.json"), options: .atomic)
            try fm.moveItem(at: staging, to: destination)
            let capacity = AppSettings.maxHistoryOptions.first(where: { $0 >= records.count }) ?? 5000
            UserDefaults.standard.set(max(1000, capacity), forKey: "maxHistoryItems")
        } catch {
            let alert = NSAlert(); alert.messageText = "历史记录迁移未完成"; alert.informativeText = "原来的内容没有改动。请检查磁盘空间或目录访问权限后重试。"; alert.runModal()
            NSApp.terminate(nil)
        }
    }
}
// Import from an explicitly supplied private file; never package or log credentials.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--import-voice-ai" {
    do {
        let source = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
        var values: [String: String] = [:]
        for line in source.components(separatedBy: .newlines) where !line.hasPrefix("#") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { values[String(parts[0]).trimmingCharacters(in: .whitespaces)] = String(parts[1]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        }
        let config = VoiceAIConfiguration(baseURL: values["OPENAI_BASE_URL"] ?? "", apiKey: values["OPENAI_API_KEY"] ?? "")
        try config.save()
        print("Voice AI configuration saved to Keychain.")
        exit(0)
    } catch { print("Voice AI configuration import failed."); exit(1) }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
