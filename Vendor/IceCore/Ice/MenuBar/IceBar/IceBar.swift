//
//  IceBar.swift
//  Ice
//

import Combine
import OSLog
import SwiftUI
import QuartzCore

// MARK: - IceBarPanel

final class IceBarPanel: NSPanel {
    var presentationAnchor: NSRect?
    private var presentationGeneration = 0
    /// The requested presentation, including cache loading and excluding dismissal.
    @Published private(set) var isPresented = false
    private var isClosing = false
    private var dismissalMonitor: EventMonitor?
    /// The shared app state.
    private weak var appState: AppState?

    /// Manager for the Ice Bar's color.
    private let colorManager = IceBarColorManager()

    /// The currently displayed section.
    private(set) var currentSection: MenuBarSection.Name?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// Creates a new Ice Bar panel.
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        self.title = "hui 菜单栏"
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.allowsToolTipsWhenApplicationIsInactive = true
        self.isFloatingPanel = true
        self.animationBehavior = .none
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = .mainMenu + 1
        self.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .moveToActiveSpace]
    }

    /// Sets up the panel.
    func performSetup(with appState: AppState) {
        self.appState = appState
        configureCancellables()
        colorManager.performSetup(with: self)
    }

    /// Configures the internal observers.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        // Hide the panel when the active space or screen parameters change.
        Publishers.Merge(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification),
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
        )
        .sink { [weak self] _ in
            self?.hide()
        }
        .store(in: &c)

        // Update the panel's origin whenever its size changes.
        publisher(for: \.frame).map(\.size)
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, let screen else {
                    return
                }
                updateOrigin(for: screen)
            }
            .store(in: &c)

        if let controlItem = appState?.menuBarManager.controlItem(withName: .hidden) {
            // Use the hidden control item's frame to determine if the menu bar
            // is hidden. Hide the panel if so.
            controlItem.$frame
                .combineLatest(controlItem.$screen)
                .throttle(for: 0.1, scheduler: DispatchQueue.main, latest: true)
                .sink { [weak self] (frame, screen) in
                    guard let self else {
                        return
                    }

                    guard let frame, let screen else {
                        hide()
                        return
                    }

                    // Icon is not vertically visible. We can infer that the
                    // menu bar is hidden.
                    if frame.maxY > screen.frame.maxY {
                        hide()
                    }
                }
                .store(in: &c)
        }

        cancellables = c
    }

    /// Updates the panel's frame origin for display on the given screen.
    private func updateOrigin(for screen: NSScreen) {
        guard let appState else {
            return
        }
        if let anchor = presentationAnchor {
            let x = max(screen.frame.minX, min(anchor.maxX - frame.width, screen.frame.maxX - frame.width))
            let y = max(screen.visibleFrame.minY, anchor.minY - frame.height - 4)
            setFrameOrigin(NSPoint(x: x, y: y))
            return
        }

        func getOrigin(for iceBarLocation: IceBarLocation) -> CGPoint {
            let menuBarHeight = screen.getMenuBarHeight() ?? 0
            let originY = ((screen.frame.maxY - 1) - menuBarHeight) - frame.height

            var originForRightOfScreen: CGPoint {
                CGPoint(x: screen.frame.maxX - frame.width, y: originY)
            }

            switch iceBarLocation {
            case .dynamic:
                if appState.eventManager.isMouseInsideEmptyMenuBarSpace(appState: appState, screen: screen) {
                    return getOrigin(for: .mousePointer)
                }
                return getOrigin(for: .iceIcon)
            case .mousePointer:
                guard let location = MouseHelpers.locationAppKit else {
                    return getOrigin(for: .iceIcon)
                }

                let lowerBound = screen.frame.minX
                let upperBound = screen.frame.maxX - frame.width

                guard lowerBound <= upperBound else {
                    return originForRightOfScreen
                }

                return CGPoint(x: (location.x - frame.width / 2).clamped(to: lowerBound...upperBound), y: originY)
            case .iceIcon:
                let lowerBound = screen.frame.minX
                let upperBound = screen.frame.maxX - frame.width

                guard
                    lowerBound <= upperBound,
                    let controlItem = appState.itemManager.itemCache.managedItems.first(matching: .visibleControlItem),
                    // Bridging API is more reliable than controlItem.frame in some
                    // cases (like if the item is offscreen).
                    let itemBounds = Bridging.getWindowBounds(for: controlItem.windowID)
                else {
                    return originForRightOfScreen
                }

                return CGPoint(x: (itemBounds.midX - frame.width / 2).clamped(to: lowerBound...upperBound), y: originY)
            }
        }

        setFrameOrigin(getOrigin(for: appState.settings.general.iceBarLocation))
    }

    /// Shows the panel on the given screen, displaying the given
    /// menu bar section.
    func reservePresentation(section: MenuBarSection.Name) -> Int {
        presentationGeneration &+= 1
        isClosing = false
        currentSection = section
        appState?.navigationState.isIceBarPresented = true
        isPresented = true
        installDismissalMonitor()
        return presentationGeneration
    }

    func isCurrentPresentation(_ generation: Int) -> Bool {
        generation == presentationGeneration && currentSection != nil
    }

    func show(section: MenuBarSection.Name, on screen: NSScreen, generation: Int) async {
        guard isCurrentPresentation(generation), !Task.isCancelled else { return }
        guard let appState else {
            return
        }

        // IMPORTANT: We must set the navigation state and current section
        // before updating the caches.
        appState.navigationState.isIceBarPresented = true
        currentSection = section
        installDismissalMonitor()

        let cacheTask = Task(timeout: .seconds(1)) {
            await appState.itemManager.cacheItemsIfNeeded()
            await appState.imageCache.updateCache()
        }

        do {
            try await cacheTask.value
        } catch {
            Logger.default.error("Cache update failed when showing IceBarPanel - \(error)")
        }
        guard generation == presentationGeneration, !Task.isCancelled, currentSection == section else { return }

        contentView = IceBarHostingView(
            appState: appState,
            colorManager: colorManager,
            screen: screen,
            section: section
        )

        updateOrigin(for: screen)

        // Color manager must be updated after updating the panel's origin,
        // but before it is shown.
        //
        // Color manager handles frame changes automatically, but does so on
        // the main queue, so we need to update manually once before showing
        // the panel to prevent the color from flashing.
        colorManager.updateAllProperties(with: frame, screen: screen)

        let wasVisible = isVisible
        if !wasVisible { alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0 }
        orderFrontRegardless()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            alphaValue = 1
        } else {
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
        }
    }

    /// Hides the panel.
    func hide() {
        if
            let name = currentSection,
            let section = appState?.menuBarManager.section(withName: name),
            !section.isHidden
        {
            section.hide()
            return
        }
        close()
    }

    override func close() {
        guard isPresented || currentSection != nil else { return }
        dismissalMonitor?.stop()
        dismissalMonitor = nil
        presentationGeneration &+= 1
        let generation = presentationGeneration
        isClosing = true
        currentSection = nil
        presentationAnchor = nil
        appState?.navigationState.isIceBarPresented = false
        isPresented = false
        guard isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finishClosing(generation: generation)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.finishClosing(generation: generation)
        }
    }

    func closeImmediately() {
        guard isPresented || currentSection != nil || isClosing || isVisible else { return }
        dismissalMonitor?.stop()
        dismissalMonitor = nil
        presentationGeneration &+= 1
        currentSection = nil
        presentationAnchor = nil
        appState?.navigationState.isIceBarPresented = false
        isPresented = false
        finishClosing(generation: presentationGeneration)
    }

    private func finishClosing(generation: Int) {
        guard generation == presentationGeneration else { return }
        isClosing = false
        super.close()
        contentView = nil
        alphaValue = 1
    }

    private func installDismissalMonitor() {
        dismissalMonitor?.stop()
        dismissalMonitor = .universal(for: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.currentSection != nil else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                if let input = event.window?.firstResponder as? NSTextInputClient, input.hasMarkedText() { return event }
                self.hide()
                return nil
            }
            let point = NSEvent.mouseLocation
            guard !self.frame.contains(point) else { return event }
            guard self.presentationAnchor?.contains(point) != true else { return event }
            // Status-item clicks have their own toggle actions on mouse-up.
            guard !NSScreen.screens.contains(where: { $0.frame.contains(point) && point.y >= $0.visibleFrame.maxY }) else { return event }
            self.hide()
            return event
        }
        dismissalMonitor?.start()
    }
}

// MARK: - IceBarHostingView

private final class IceBarHostingView: NSHostingView<IceBarContentView> {
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }

    init(
        appState: AppState,
        colorManager: IceBarColorManager,
        screen: NSScreen,
        section: MenuBarSection.Name
    ) {
        let rootView = IceBarContentView(
            appState: appState,
            colorManager: colorManager,
            itemManager: appState.itemManager,
            imageCache: appState.imageCache,
            menuBarManager: appState.menuBarManager,
            screen: screen,
            section: section
        )
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @available(*, unavailable)
    required init(rootView: IceBarContentView) {
        fatalError("init(rootView:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

// MARK: - IceBarContentView

private struct IceBarContentView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var colorManager: IceBarColorManager
    @ObservedObject var itemManager: MenuBarItemManager
    @ObservedObject var imageCache: MenuBarItemImageCache
    @ObservedObject var menuBarManager: MenuBarManager
    @State private var frame = CGRect.zero
    @State private var scrollIndicatorsFlashTrigger = 0

    let screen: NSScreen
    let section: MenuBarSection.Name

    private var items: [MenuBarItem] {
        itemManager.itemCache.managedItems(for: section)
    }

    private var configuration: MenuBarAppearanceConfigurationV2 {
        appState.appearanceManager.configuration
    }

    private var horizontalPadding: CGFloat {
        if #available(macOS 26.0, *) {
            return 3
        }
        return configuration.hasRoundedShape ? 7 : 5
    }

    private var verticalPadding: CGFloat {
        if #available(macOS 26.0, *) {
            return screen.hasNotch && configuration.hasRoundedShape ? 2 : 0
        }
        return screen.hasNotch ? 0 : 2
    }

    private var contentHeight: CGFloat? {
        guard let menuBarHeight = screen.getMenuBarHeight() else {
            return nil
        }
        if configuration.shapeKind != .noShape && configuration.isInset && screen.hasNotch {
            return menuBarHeight - appState.appearanceManager.menuBarInsetAmount * 2
        }
        return menuBarHeight
    }

    private var clipShape: some InsettableShape {
        if configuration.hasRoundedShape {
            RoundedRectangle(cornerRadius: frame.height / 2, style: .circular)
        } else if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: frame.height / 4, style: .continuous)
        } else {
            RoundedRectangle(cornerRadius: frame.height / 5, style: .continuous)
        }
    }

    private var shadowOpacity: CGFloat {
        configuration.current.hasShadow ? 0.5 : 0.33
    }

    var body: some View {
        ZStack {
            content
                .frame(height: contentHeight)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .menuBarItemContainer(appState: appState, colorInfo: colorManager.colorInfo)
                .foregroundStyle(colorManager.colorInfo?.color.brightness ?? 0 > 0.67 ? .black : .white)
                .clipShape(clipShape)
                .shadow(color: .black.opacity(shadowOpacity), radius: 2.5)

            if configuration.current.hasBorder {
                clipShape
                    .inset(by: configuration.current.borderWidth / 2)
                    .stroke(lineWidth: configuration.current.borderWidth)
                    .foregroundStyle(Color(cgColor: configuration.current.borderColor))
            }
        }
        .padding(5)
        .frame(maxWidth: screen.frame.width)
        .fixedSize()
        .onFrameChange(update: $frame)
    }

    @ViewBuilder
    private var content: some View {
        HStack(spacing: 0) {
            itemContent
            if appState.isEmbedded {
                Rectangle().fill(.primary.opacity(0.16)).frame(width: 0.5, height: 14).padding(.horizontal, 5)
                ShiyiEntryButton { anchor in
                    let openHost = appState.onOpenHost
                    menuBarManager.iceBarPanel.hide()
                    openHost?(anchor)
                }
                .frame(width: 30, height: contentHeight ?? 26)
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var itemContent: some View {
        if !ScreenCapture.cachedCheckPermissions() {
            HStack {
                Text("需要屏幕录制权限")

                Button {
                    menuBarManager.section(withName: section)?.hide()
                    appState.navigationState.settingsNavigationIdentifier = .advanced
                    appState.activate(withPolicy: .regular)
                    appState.openWindow(.settings)
                } label: {
                    Text("打开设置")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.link)
            }
            .padding(.horizontal, 10)
        } else if menuBarManager.isMenuBarHiddenBySystemUserDefaults {
            Text("请先关闭系统菜单栏自动隐藏")
                .padding(.horizontal, 10)
        } else if itemManager.itemCache.managedItems.isEmpty {
            HStack {
                Text("正在载入图标…")
                ProgressView()
                    .controlSize(.small)
            }
            .padding(.horizontal, 10)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(items, id: \.windowID) { item in
                        IceBarItemView(
                            imageCache: imageCache,
                            itemManager: itemManager,
                            menuBarManager: menuBarManager,
                            item: item,
                            section: section
                        )
                    }
                }
            }
            .environment(\.isScrollEnabled, frame.width == screen.frame.width)
            .defaultScrollAnchor(.trailing)
            .scrollIndicatorsFlash(trigger: scrollIndicatorsFlashTrigger)
            .task {
                scrollIndicatorsFlashTrigger += 1
            }
        }
    }
}

private struct ShiyiEntryButton: NSViewRepresentable {
    let action: (NSRect) -> Void

    final class Coordinator: NSObject {
        var action: (NSRect) -> Void
        init(action: @escaping (NSRect) -> Void) { self.action = action }
        @objc func openMain(_ button: NSButton) {
            guard let window = button.window else { return }
            action(window.convertToScreen(button.convert(button.bounds, to: nil)))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let icon = Bundle.main.url(forResource: "HuiMenuBarTemplate", withExtension: "pdf").flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "h.circle", accessibilityDescription: "打开 hui")!
        icon.size = NSSize(width: 18, height: 18)
        icon.isTemplate = true
        let button = NSButton(image: icon, target: context.coordinator, action: #selector(Coordinator.openMain(_:)))
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = "打开 hui"
        button.setAccessibilityLabel("打开 hui")
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.action = action }
}

// MARK: - IceBarItemView

private struct IceBarItemView: View {
    @ObservedObject var imageCache: MenuBarItemImageCache
    @ObservedObject var itemManager: MenuBarItemManager
    @ObservedObject var menuBarManager: MenuBarManager

    let item: MenuBarItem
    let section: MenuBarSection.Name

    private var leftClickAction: () -> Void {
        return { [weak itemManager, weak menuBarManager] in
            guard let itemManager, let menuBarManager else {
                return
            }
            menuBarManager.section(withName: section)?.hide(animated: false)
            Task {
                try await Task.sleep(for: .milliseconds(25))
                await itemManager.activateFromBar(item: item, with: .left)
            }
        }
    }

    private var rightClickAction: () -> Void {
        return { [weak itemManager, weak menuBarManager] in
            guard let itemManager, let menuBarManager else {
                return
            }
            menuBarManager.section(withName: section)?.hide(animated: false)
            Task {
                try await Task.sleep(for: .milliseconds(25))
                await itemManager.activateFromBar(item: item, with: .right)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let native = imageCache.nativeTemplate(for: item) {
            // Native status menus can keep a nontransparent window while
            // culling its offscreen glyph. Use the source app's own template
            // for this known static icon, even if that blank capture succeeded.
            Image(nsImage: native)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .frame(
                    width: item.bounds.width.isFinite ? min(max(item.bounds.width, 24), 64) : 24,
                    height: item.bounds.height.isFinite ? min(max(item.bounds.height, 22), 36) : 24
                )
        } else if let captured = imageCache.images[item.tag] {
            Image(nsImage: captured.nsImage)
        } else {
            // A temporarily uncapturable offscreen window is still a live
            // status item. Keep its target available while normal capture
            // retries replace this fallback with the actual menu bar image.
            Group {
                if let sourceIcon = imageCache.fallbackImage(for: item) {
                    Image(nsImage: sourceIcon)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "square.dashed")
                        .resizable()
                        .scaledToFit()
                }
            }
            .frame(width: 18, height: 18)
            .frame(
                width: item.bounds.width.isFinite ? min(max(item.bounds.width, 24), 64) : 24,
                height: item.bounds.height.isFinite ? min(max(item.bounds.height, 22), 36) : 24
            )
        }
    }

    var body: some View {
        icon
            .contentShape(Rectangle())
            .overlay {
                IceBarItemClickView(
                    item: item,
                    leftClickAction: leftClickAction,
                    rightClickAction: rightClickAction
                )
            }
            .accessibilityLabel(item.displayName)
            .accessibilityAction(named: "left click", leftClickAction)
            .accessibilityAction(named: "right click", rightClickAction)
    }
}

// MARK: - IceBarItemClickView

private struct IceBarItemClickView: NSViewRepresentable {
    private final class Represented: NSView {
        var item: MenuBarItem

        var leftClickAction: () -> Void
        var rightClickAction: () -> Void

        private var lastLeftMouseDownDate = Date.now
        private var lastRightMouseDownDate = Date.now

        private var lastLeftMouseDownLocation = CGPoint.zero
        private var lastRightMouseDownLocation = CGPoint.zero

        init(
            item: MenuBarItem,
            leftClickAction: @escaping () -> Void,
            rightClickAction: @escaping () -> Void
        ) {
            self.item = item
            self.leftClickAction = leftClickAction
            self.rightClickAction = rightClickAction
            super.init(frame: .zero)
            self.toolTip = item.displayName
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            lastLeftMouseDownDate = .now
            lastLeftMouseDownLocation = NSEvent.mouseLocation
        }

        override func rightMouseDown(with event: NSEvent) {
            super.rightMouseDown(with: event)
            lastRightMouseDownDate = .now
            lastRightMouseDownLocation = NSEvent.mouseLocation
        }

        override func mouseUp(with event: NSEvent) {
            super.mouseUp(with: event)
            guard
                Date.now.timeIntervalSince(lastLeftMouseDownDate) < 0.5,
                lastLeftMouseDownLocation.distance(to: NSEvent.mouseLocation) < 5
            else {
                return
            }
            leftClickAction()
        }

        override func rightMouseUp(with event: NSEvent) {
            super.rightMouseUp(with: event)
            guard
                Date.now.timeIntervalSince(lastRightMouseDownDate) < 0.5,
                lastRightMouseDownLocation.distance(to: NSEvent.mouseLocation) < 5
            else {
                return
            }
            rightClickAction()
        }
    }

    let item: MenuBarItem

    let leftClickAction: () -> Void
    let rightClickAction: () -> Void

    func makeNSView(context: Context) -> NSView {
        Represented(
            item: item,
            leftClickAction: leftClickAction,
            rightClickAction: rightClickAction
        )
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let represented = nsView as? Represented else { return }
        represented.item = item
        represented.leftClickAction = leftClickAction
        represented.rightClickAction = rightClickAction
        represented.toolTip = item.displayName
    }
}
