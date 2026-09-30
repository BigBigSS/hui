import AppKit
import Combine
import ShiyiMenuCore

@MainActor
final class MenuEngine: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var visible = false
    @Published private(set) var error = ""
    @Published private(set) var statusLabel = "准备中"
    @Published private(set) var hover = UserDefaults.standard.bool(forKey: "menuHover")
    var onOpenMain: ((NSRect) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onNeedsAttention: (() -> Void)?
    private let core = ShiyiMenuCoreController()

    init() {
        core.onStatus = { [weak self] status in
            guard let self else { return }
            if self.running != status.ready { self.running = status.ready }
            if self.visible != status.isVisible { self.visible = status.isVisible }
            let message = status.error ?? ""
            if self.error != message { self.error = message }
            let label = status.ready ? "已就绪" : (status.accessibilityGranted && status.screenRecordingGranted ? "载入中" : "等待权限")
            if self.statusLabel != label { self.statusLabel = label }
        }
        core.onOpenMain = { [weak self] anchor in self?.onOpenMain?(anchor) }
        core.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
    }

    func start() { core.start(); core.setHover(hover) }
    func refresh() { core.refreshStatus() }
    func stop() { core.stop() }
    func restart() { core.start(); core.refreshStatus() }
    func hide() { core.hide() }
    func toggle(anchor: NSRect? = nil) {
        core.refreshStatus()
        guard core.status.ready else {
            core.start()
            onNeedsAttention?()
            return
        }
        core.toggle(anchor: anchor)
    }
    func setHover(_ value: Bool) {
        hover = value
        UserDefaults.standard.set(value, forKey: "menuHover")
        core.setHover(value)
    }
    func arrange() { core.showSettings() }
}
