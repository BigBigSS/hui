import AppKit
import ApplicationServices
import SwiftUI

@MainActor
private final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ClipboardPanelController {
    private let model: AppModel
    private let panel: ClipboardPanel
    private var mouseMonitor: Any?
    private var localMonitor: Any?
    private var activationObserver: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        panel = ClipboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 440),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "剪贴板"
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let hosting = NSHostingView(rootView: ClipboardBrowserView(model: model, store: model.store, standalone: true))
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 18
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting
    }

    func toggle() {
        if panel.isVisible { hide(); return }
        let anchor = captureAnchor()
        panel.setFrame(Self.position(size: NSSize(width: 360, height: 440), anchor: anchor), display: false)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        installDismissalObservers()
    }

    func hide() {
        panel.orderOut(nil)
        removeDismissalObservers()
    }

    func shutdown() { hide() }

    private func captureAnchor() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let fallback = NSRect(origin: mouse, size: NSSize(width: 1, height: 1))
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return fallback }
        model.pasteTarget = app
        guard AXIsProcessTrusted(), let bounds = Self.caretBounds(pid: app.processIdentifier) else { return fallback }
        return bounds
    }

    private static func caretBounds(pid: pid_t) -> NSRect? {
        let application = AXUIElementCreateApplication(pid)
        // A stalled accessibility provider must never stall the clipboard picker.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        func setRemainingTimeout(_ element: AXUIElement) -> Bool {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            AXUIElementSetMessagingTimeout(element, Float(remaining))
            return true
        }
        guard setRemainingTimeout(application) else { return nil }
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        let focused = focusedValue as! AXUIElement
        guard setRemainingTimeout(focused) else { return nil }
        var selectionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &selectionValue) == .success,
              let selectionValue, CFGetTypeID(selectionValue) == AXValueGetTypeID() else { return nil }
        let selection = selectionValue as! AXValue
        var range = CFRange()
        guard AXValueGetType(selection) == .cfRange, AXValueGetValue(selection, .cfRange, &range),
              range.location >= 0, range.length >= 0, range.location <= Int.max - range.length else { return nil }
        var insertionRange = CFRange(location: range.location + range.length, length: 0)
        let insertionValue = AXValueCreate(.cfRange, &insertionRange)
        var boundsValue: CFTypeRef?
        guard setRemainingTimeout(focused) else { return nil }
        var result = AXUIElementCopyParameterizedAttributeValue(
            focused, kAXBoundsForRangeParameterizedAttribute as CFString, insertionValue ?? selection, &boundsValue
        )
        if result != .success, range.length > 0 {
            guard setRemainingTimeout(focused) else { return nil }
            result = AXUIElementCopyParameterizedAttributeValue(focused, kAXBoundsForRangeParameterizedAttribute as CFString, selection, &boundsValue)
        }
        guard result == .success, let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
        let bounds = boundsValue as! AXValue
        var rect = CGRect.zero
        guard AXValueGetType(bounds) == .cgRect, AXValueGetValue(bounds, .cgRect, &rect),
              rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.width >= 0, rect.height > 0,
              let primary = NSScreen.screens.first else { return nil }
        // AX uses the top left of the primary display; AppKit uses its bottom left.
        let appKitRect = NSRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: max(1, rect.width), height: rect.height)
        guard NSScreen.screens.contains(where: { $0.frame.intersects(appKitRect) }) else { return nil }
        return appKitRect
    }

    private static func position(size requestedSize: NSSize, anchor: NSRect) -> NSRect {
        let center = NSPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) })
            ?? NSScreen.screens.first(where: { $0.frame.intersects(anchor) })
            ?? NSScreen.main
        guard let screen else { return NSRect(x: anchor.minX, y: anchor.minY - requestedSize.height - 8, width: requestedSize.width, height: requestedSize.height) }
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let size = NSSize(width: min(requestedSize.width, visible.width), height: min(requestedSize.height, visible.height))
        let below = anchor.minY - size.height - 8
        let above = anchor.maxY + 8
        let y: CGFloat
        if below >= visible.minY { y = below }
        else if above + size.height <= visible.maxY { y = above }
        else {
            let roomBelow = anchor.minY - visible.minY
            let roomAbove = visible.maxY - anchor.maxY
            y = roomBelow >= roomAbove ? below : above
        }
        return NSRect(
            x: max(visible.minX, min(anchor.minX - 12, visible.maxX - size.width)),
            y: max(visible.minY, min(y, visible.maxY - size.height)),
            width: size.width, height: size.height
        )
    }

    private func installDismissalObservers() {
        removeDismissalObservers()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.attachedSheet == nil else { return }
                self.hide()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.panel.isVisible, self.panel.attachedSheet == nil else { return false }
                if event.type == .keyDown {
                    guard self.belongsToPanel(event.window), event.keyCode == 53 else { return false }
                    if let input = event.window?.firstResponder as? NSTextInputClient, input.hasMarkedText() { return false }
                    self.hide()
                    return true
                }
                if !self.belongsToPanel(event.window) { self.hide() }
                return false
            }
            return consumed ? nil : event
        }
        let presentingApplicationPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let activatedPID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible, self.panel.attachedSheet == nil,
                      let activatedPID, activatedPID != presentingApplicationPID,
                      activatedPID != ProcessInfo.processInfo.processIdentifier else { return }
                self.hide()
            }
        }
    }

    private func belongsToPanel(_ candidate: NSWindow?) -> Bool {
        guard let candidate else { return false }
        if candidate === panel { return true }
        return belongsToPanel(candidate.sheetParent ?? candidate.parent)
    }

    private func removeDismissalObservers() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver); self.activationObserver = nil }
    }
}
