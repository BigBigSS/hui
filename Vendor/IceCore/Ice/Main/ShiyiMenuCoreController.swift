import AppKit
import Combine
import OSLog
import SwiftUI

/// The host owns this controller; all menu-bar work runs in its process.
@MainActor
public final class ShiyiMenuCoreController: NSObject, ObservableObject {
    public struct Status: Equatable {
        public var ready: Bool
        public var accessibilityGranted: Bool
        public var screenRecordingGranted: Bool
        /// Requested presentation, including loading and excluding the closing animation.
        public var isVisible: Bool
        public var error: String?

        public init(ready: Bool = false, accessibilityGranted: Bool = false, screenRecordingGranted: Bool = false, isVisible: Bool = false, error: String? = nil) {
            self.ready = ready
            self.accessibilityGranted = accessibilityGranted
            self.screenRecordingGranted = screenRecordingGranted
            self.isVisible = isVisible
            self.error = error
        }
    }

    @Published public private(set) var status = Status()
    public var onStatus: ((Status) -> Void)?
    public var onOpenMain: ((NSRect) -> Void)?
    public var onOpenSettings: (() -> Void)?

    private var appState: AppState?
    private var setupTask: Task<Void, Never>?
    private var settingsRefreshTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var settingsWindow: NSWindow?
    private var requestedStart = false
    private var setupFinished = false
    private var desiredHover: Bool?
    private let logger = Logger(subsystem: "Shiyi.MenuCore", category: "EmbeddedSettings")

    public override init() {
        super.init()
        Self.preparePreferences()
        installState()
        refreshStatus()
    }

    public func start() {
        requestedStart = true
        if appState == nil { installState() }
        refreshStatus()
        onStatus?(status)
    }

    public func refreshStatus() {
        let accessibility = AXHelpers.isProcessTrusted()
        let screenRecording = ScreenCapture.cachedCheckPermissions(reset: true)
        let ready = setupFinished && accessibility && screenRecording
        let error: String?
        if !accessibility { error = "请为 hui 开启辅助功能" }
        else if !screenRecording { error = "请为 hui 开启屏幕与系统音频录制权限，以显示菜单栏图标" }
        else { error = nil }
        let next = Status(ready: ready, accessibilityGranted: accessibility, screenRecordingGranted: screenRecording, isVisible: appState?.menuBarManager.iceBarPanel.isPresented == true, error: error)
        if next != status { status = next; onStatus?(next) }
        guard requestedStart, accessibility, screenRecording, !setupFinished, setupTask == nil, let state = appState else { return }
        setupTask = Task { [weak self, weak state] in
            guard let state else { return }
            await state.prepareForEmbedding()
            guard let self, !Task.isCancelled, self.appState === state else { return }
            state.settings.general.showIceIcon = false
            state.settings.general.useIceBar = true
            state.settings.advanced.hideApplicationMenus = false
            if let desiredHover = self.desiredHover { state.settings.general.showOnHover = desiredHover }
            self.setupFinished = true
            self.setupTask = nil
            self.refreshStatus()
        }
    }

    public func toggle(anchor: NSRect? = nil) {
        refreshStatus()
        guard status.ready, let state = appState else { return }
        state.menuBarManager.iceBarPanel.presentationAnchor = anchor
        HotkeyAction.toggleHiddenSection.perform(appState: state)
    }

    public func hide() { appState?.menuBarManager.iceBarPanel.hide() }

    public func setHover(_ enabled: Bool) {
        desiredHover = enabled
        Defaults.set(enabled, forKey: .showOnHover)
        if setupFinished { appState?.settings.general.showOnHover = enabled }
    }

    public func showSettings() {
        refreshStatus()
        guard status.ready, let state = appState else { onOpenSettings?(); return }
        hide()
        state.navigationState.settingsNavigationIdentifier = .menuBarLayout
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 400), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "排列菜单栏图标"
            window.identifier = NSUserInterfaceItemIdentifier(IceWindowIdentifier.settings.rawValue)
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 560, height: 320)
            window.contentView = NSHostingView(rootView: MenuBarLayoutSettingsPane(itemManager: state.itemManager).environmentObject(state))
            window.center()
            settingsWindow = window
        }
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsRefreshTask?.cancel()
        guard let window = settingsWindow else { return }
        // This host-created window can appear after the standalone startup
        // warmup. Populate its first frame directly rather than waiting for
        // window-discovery publishers and their presentation gates.
        settingsRefreshTask = Task { [weak self, weak state, weak window] in
            guard let self, let state, let window,
                  self.appState === state, self.settingsWindow === window,
                  window.isVisible, !Task.isCancelled else { return }
            await state.itemManager.cacheItemsIfNeeded()
            guard self.appState === state, self.settingsWindow === window,
                  window.isVisible, !Task.isCancelled else { return }
            let navigation = state.navigationState
            let cache = state.itemManager.itemCache
            let visibleCount = cache[.visible].count
            let hiddenCount = cache[.hidden].count
            let alwaysHiddenCount = cache[.alwaysHidden].count
            let displayID = cache.displayID ?? 0
            let permitted = state.hasPermission(.screenRecording)
            self.logger.notice("Layout initial refresh: frontmost=\(navigation.isAppFrontmost) presented=\(navigation.isSettingsPresented) display=\(displayID) permission=\(permitted) items=\(visibleCount)/\(hiddenCount)/\(alwaysHiddenCount)")
            await state.imageCache.updateCacheWithoutChecks(sections: MenuBarSection.Name.allCases)
        }
    }

    public func stop() {
        requestedStart = false
        setupTask?.cancel()
        setupTask = nil
        settingsRefreshTask?.cancel()
        settingsRefreshTask = nil
        subscriptions.removeAll()
        settingsWindow?.close()
        settingsWindow = nil
        appState?.shutdown()
        appState = nil
        setupFinished = false
        let next = Status(accessibilityGranted: status.accessibilityGranted, screenRecordingGranted: status.screenRecordingGranted)
        if status != next { status = next; onStatus?(next) }
    }

    private func installState() {
        let state = AppState()
        state.isEmbedded = true
        // The host refreshes permission state; avoid a second background polling loop.
        state.permissions.stopAllChecks()
        state.onOpenHost = { [weak self] anchor in self?.onOpenMain?(anchor) }
        state.onOpenWindow = { [weak self, weak state] identifier in
            guard let self, let state else { return }
            if identifier == .permissions || state.navigationState.settingsNavigationIdentifier == .advanced {
                self.hide()
                self.onOpenSettings?()
            } else {
                self.showSettings()
            }
        }
        state.onDismissWindow = { [weak self] _ in self?.settingsWindow?.orderOut(nil) }
        appState = state
        state.menuBarManager.iceBarPanel.$isPresented
            .removeDuplicates()
            .sink { [weak self] presented in
                guard let self else { return }
                // @Published emits before its stored value changes. Use this value
                // directly so loading and dismissal update the host in the same turn.
                var next = self.status
                next.isVisible = presented
                if next != self.status { self.status = next; self.onStatus?(next) }
            }
            .store(in: &subscriptions)
    }

    private static func preparePreferences() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "ShiyiMenuCoreMigratedPreferencesV1") {
            let legacy = UserDefaults(suiteName: "com.jordanbaird.Ice")
            let keys: [Defaults.Key] = [
                .iceBarLocation, .showOnClick, .showOnHover, .showOnScroll,
                .autoRehide, .rehideStrategy, .rehideInterval, .itemSpacingOffset,
                .enableAlwaysHiddenSection, .showAllSectionsOnUserDrag, .sectionDividerStyle,
                .enableSecondaryContextMenu, .showOnHoverDelay, .tempShowInterval,
                .menuBarAppearanceConfigurationV2
            ]
            for key in keys where defaults.object(forKey: key.rawValue) == nil {
                if let value = legacy?.object(forKey: key.rawValue) { defaults.set(value, forKey: key.rawValue) }
            }
            for name in ["Ice.ControlItem.Hidden", "Ice.ControlItem.AlwaysHidden"] {
                for suffix in ["Preferred Position", "Visible", "VisibleCC"] {
                    let key = "NSStatusItem \(suffix) \(name)"
                    if defaults.object(forKey: key) == nil, let value = legacy?.object(forKey: key) { defaults.set(value, forKey: key) }
                }
            }
            defaults.set(true, forKey: "ShiyiMenuCoreMigratedPreferencesV1")
        }
        // The host owns its status item, shortcuts, activation policy, and updater.
        Defaults.set(false, forKey: .showIceIcon)
        Defaults.set(true, forKey: .useIceBar)
        Defaults.set(false, forKey: .hideApplicationMenus)
    }
}
