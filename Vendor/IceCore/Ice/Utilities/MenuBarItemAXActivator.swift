//
//  MenuBarItemAXActivator.swift
//  Shiyi
//
//  AXPress activation and reaction checks adapted from Thaw, commit
//  2f5818785b3909d63e71a358e42a5fc313741476 (AXItemActivator.swift and
//  ClickReactionVerifier.swift). Copyright (Ice) 2023–2025 Jordan Baird;
//  Copyright (Thaw) 2026 Toni Förster. Licensed under GNU GPLv3.
//

import Cocoa
import OSLog

/// A left-click alternative which never posts mouse events or moves the cursor.
enum MenuBarItemAXActivator {
    enum Outcome: Equatable, Sendable {
        case activated
        /// No action was performed.
        case unavailable
        /// An action may have landed. The caller must not synthesize a retry.
        case uncertain
    }

    struct ReactionSnapshot {
        let windowIDs: Set<CGWindowID>
        let frontmostPID: pid_t?
    }

    struct Candidate {
        let pid: pid_t
        let role: String
        let frame: CGRect?
        let supportsActivation: Bool
    }

    private final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(650))

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var canResolve: Bool { !isCancelled && ContinuousClock.now < deadline }
    }

    private struct Target {
        let windowID: CGWindowID
        let ownerPID: pid_t
        let sourcePID: pid_t?
        let pids: [pid_t]
        let frame: CGRect
        let allowOffscreen: Bool
        let sourceBundleID: String?
    }

    private static let queue = DispatchQueue(label: "Shiyi.menu-bar.ax-activation", qos: .userInitiated)
    private static let logger = Logger(subsystem: "Shiyi.MenuCore", category: "MenuBarItemAXActivator")

    @MainActor
    static func activate(item: MenuBarItem, allowOffscreen: Bool = false) async -> Outcome {
        guard !Task.isCancelled else { return .uncertain }
        guard let frame = Bridging.getWindowBounds(for: item.windowID),
              validFrame(frame) else {
            return .unavailable
        }
        let isVisible = Bridging.isWindowOnScreen(item.windowID) &&
            NSScreen.screens.contains(where: { CGDisplayBounds($0.displayID).contains(CGPoint(x: frame.midX, y: frame.midY)) })
        let sourceBundleID = item.sourcePID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        let useOffscreen = !isVisible && permitsOffscreen(requested: allowOffscreen, sourceBundleID: sourceBundleID)
        guard isVisible || useOffscreen else { return .unavailable }
        let target = Target(
            windowID: item.windowID,
            ownerPID: item.ownerPID,
            sourcePID: item.sourcePID,
            pids: [item.sourcePID, item.ownerPID].compactMap { $0 }.reduce(into: []) { pids, pid in
                if !pids.contains(pid) { pids.append(pid) }
            },
            frame: frame,
            allowOffscreen: useOffscreen,
            sourceBundleID: sourceBundleID
        )
        let nativeMenu = usesNativeMenu(sourceBundleID: sourceBundleID)
        let reactionPIDs = nativeMenu ? Set([target.sourcePID].compactMap { $0 }) : Set(target.pids)
        let before = snapshot(pids: reactionPIDs, requiresVisibleScreenIntersection: nativeMenu)
        let request = Request()
        let result: Outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: perform(target: target, request: request))
                }
            }
        } onCancel: {
            request.cancel()
        }
        guard !Task.isCancelled else { return .uncertain }
        guard result == .uncertain else { return result }

        // Native NSStatusItem menus may acknowledge an action without opening
        // anything, or open a tracking menu and time out waiting for its reply.
        // For these items, a reply or application focus alone is not success.
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(nativeMenu ? 500 : 250))
        repeat {
            if didReact(before: before, after: snapshot(pids: reactionPIDs, requiresVisibleScreenIntersection: nativeMenu), pids: reactionPIDs, requiresWindowChange: nativeMenu) {
                return .activated
            }
            guard !Task.isCancelled else { return .uncertain }
            do { try await Task.sleep(for: .milliseconds(25)) }
            catch { return .uncertain }
        } while ContinuousClock.now < deadline
        if nativeMenu {
            logger.warning("Native status menu did not show an observable reaction for window \(target.windowID); no duplicate activation")
        }
        return .uncertain
    }

    private static func perform(target: Target, request: Request) -> Outcome {
        guard request.canResolve else { return .uncertain }
        // Resolve within the two known owners' extras bars. A system-wide
        // hit test can land on a neighboring menu or our own overlay; it is
        // deliberately unnecessary here. No global AX timeout is changed.
        for pid in target.pids {
            guard request.canResolve else { return .uncertain }
            let app = AXUIElementCreateApplication(pid)
            guard let extras = element(attribute(app, kAXExtrasMenuBarAttribute, request: request)),
                  let children = attribute(extras, kAXChildrenAttribute, request: request) as? [AXUIElement] else { continue }
            if target.allowOffscreen {
                var candidates = [Candidate]()
                var elements = [AXUIElement]()
                var completeScan = children.count <= 128
                for child in children.prefix(128) {
                    guard request.canResolve else { return .uncertain }
                    var childPID: pid_t = 0
                    guard AXUIElementGetPid(child, &childPID) == .success,
                          let role = attribute(child, kAXRoleAttribute, request: request) as? String else {
                        completeScan = false
                        continue
                    }
                    guard allowedRoles.contains(role) else { continue }
                    guard let names = actionNames(child, request: request) else {
                        completeScan = false
                        continue
                    }
                    candidates.append(Candidate(pid: childPID, role: role, frame: frame(of: child, request: request), supportsActivation: preferredAction(actionNames: names, sourceBundleID: target.sourceBundleID) != nil))
                    elements.append(child)
                }
                if let index = candidateIndex(
                    candidates, target: target.frame, expectedPIDs: Set(target.pids),
                    sourcePID: target.sourcePID, extrasPID: pid, allowOffscreen: true, completeScan: completeScan
                ) {
                    let matchingFrame = candidates[index].frame.map { framesMatch($0, target.frame) } ?? false
                    return press(elements[index], app: app, target: target, request: request, requiresFrameMatch: matchingFrame)
                }
                continue
            }
            for child in children.prefix(128) {
                guard request.canResolve else { return .uncertain }
                var childPID: pid_t = 0
                guard AXUIElementGetPid(child, &childPID) == .success,
                      let role = attribute(child, kAXRoleAttribute, request: request) as? String,
                      let candidateFrame = frame(of: child, request: request),
                      matchesCandidate(pid: childPID, role: role, frame: candidateFrame, expectedPIDs: Set(target.pids), target: target.frame) else { continue }
                guard let names = actionNames(child, request: request),
                      preferredAction(actionNames: names, sourceBundleID: target.sourceBundleID) != nil else { continue }
                return press(child, app: app, target: target, request: request, requiresFrameMatch: true)
            }
        }
        return request.canResolve ? .unavailable : .uncertain
    }

    private static func press(_ child: AXUIElement, app: AXUIElement, target: Target, request: Request, requiresFrameMatch: Bool) -> Outcome {
        let nativeMenu = usesNativeMenu(sourceBundleID: target.sourceBundleID)
        let expandedBefore = nativeMenu ? nil : attribute(child, kAXExpandedAttribute, request: request) as? Bool
        let menuBefore = nativeMenu ? nil : menuState(app: app, request: request)
        // Resolve the exact live window again. A source app with one extra
        // can identify its parked item even when AX retains its old frame;
        // a shared Control Center host must never use that shortcut.
        guard request.canResolve,
              let liveWindow = WindowInfo(windowID: target.windowID), liveWindow.ownerPID == target.ownerPID,
              let live = Bridging.getWindowBounds(for: target.windowID), validFrame(live) else { return .uncertain }
        if requiresFrameMatch {
            guard let liveAX = frame(of: child, request: request), framesMatch(liveAX, live) else { return .uncertain }
        } else {
            var childPID: pid_t = 0
            guard target.allowOffscreen, let sourcePID = target.sourcePID,
                  AXUIElementGetPid(child, &childPID) == .success, childPID == sourcePID else { return .uncertain }
        }
        // Re-read supported actions on the exact live element immediately
        // before dispatch. Exactly one action can be sent by this request.
        guard request.canResolve else { return .uncertain }
        guard let names = actionNames(child, request: request) else { return .uncertain }
        guard let action = preferredAction(actionNames: names, sourceBundleID: target.sourceBundleID) else { return .unavailable }
        guard request.canResolve else { return .uncertain }
        AXUIElementSetMessagingTimeout(child, 0.25)
        let result = AXUIElementPerformAction(child, action as CFString)
        if nativeMenu {
            logger.notice("Native status menu action \(action, privacy: .public) returned \(result.rawValue) for window \(target.windowID); checking visible source-window reaction")
        }
        let immediateOutcome = outcome(for: result, didReact: false, offscreenActionAttempted: target.allowOffscreen, requiresReaction: nativeMenu)
        if immediateOutcome != .uncertain { return immediateOutcome }

        // AX can report a menu as expanded while its anchor is still offscreen.
        // Native items therefore require the source application's visible-window
        // evidence checked by activate(), not this internal state alone.
        guard !nativeMenu else { return .uncertain }
        // After a potentially delivered action, cancellation or an expired
        // resolution budget must never permit a mouse retry.
        guard request.canResolve else { return .uncertain }
        let expandedAfter = attribute(child, kAXExpandedAttribute, request: request) as? Bool
        let menuAfter = menuState(app: app, request: request)
        if let before = expandedBefore, let after = expandedAfter, before != after { return .activated }
        if let before = menuBefore, let after = menuAfter, before != after { return .activated }
        return .uncertain
    }

    static func permitsOffscreen(requested: Bool, sourceBundleID: String?) -> Bool {
        requested && sourceBundleID == "com.openai.codex"
    }

    static func usesNativeMenu(sourceBundleID: String?) -> Bool {
        sourceBundleID == "com.openai.codex"
    }

    /// Preserve ordinary button activation, including the verified hidden-item
    /// AXPress path. Native menu-only elements may advertise ShowMenu instead.
    static func preferredAction(actionNames: [String], sourceBundleID: String?) -> String? {
        if actionNames.contains(kAXPressAction as String) {
            return kAXPressAction as String
        }
        if usesNativeMenu(sourceBundleID: sourceBundleID), actionNames.contains(kAXShowMenuAction as String) {
            return kAXShowMenuAction as String
        }
        return nil
    }

    /// Prefer exactly one strict frame match. Only a complete scan of the
    /// source application's own extras can establish a unique hidden item.
    static func candidateIndex(_ candidates: [Candidate], target: CGRect, expectedPIDs: Set<pid_t>, sourcePID: pid_t?, extrasPID: pid_t, allowOffscreen: Bool, completeScan: Bool) -> Int? {
        let eligible = candidates.indices.filter {
            expectedPIDs.contains(candidates[$0].pid) && allowedRoles.contains(candidates[$0].role) && candidates[$0].supportsActivation
        }
        let matching = eligible.filter { index in
            candidates[index].frame.map { framesMatch($0, target) } ?? false
        }
        if matching.count == 1 { return matching[0] }
        guard matching.isEmpty, allowOffscreen, completeScan,
              let sourcePID, extrasPID == sourcePID else { return nil }
        let sourceChildren = eligible.filter { candidates[$0].pid == sourcePID }
        return sourceChildren.count == 1 ? sourceChildren[0] : nil
    }

    private static let allowedRoles = [kAXMenuBarItemRole as String, kAXMenuButtonRole as String, kAXButtonRole as String]

    private static func actionNames(_ child: AXUIElement, request: Request) -> [String]? {
        guard request.canResolve else { return nil }
        var actions: CFArray?
        AXUIElementSetMessagingTimeout(child, 0.08)
        guard AXUIElementCopyActionNames(child, &actions) == .success, let names = actions as? [String] else { return nil }
        return names
    }

    /// Strict geometry avoids choosing an adjacent status item in the same
    /// host process. Differently padded AX buttons can share the same center.
    static func framesMatch(_ candidate: CGRect, _ target: CGRect) -> Bool {
        guard validFrame(candidate), validFrame(target) else { return false }
        let tolerance = min(4, target.width / 4)
        let centersMatch = abs(candidate.midX - target.midX) <= tolerance && abs(candidate.midY - target.midY) <= 4
        let overlap = candidate.intersection(target)
        let smallerArea = min(candidate.width * candidate.height, target.width * target.height)
        return centersMatch && !overlap.isNull && overlap.width * overlap.height >= smallerArea * 0.8
    }

    static func matchesCandidate(pid: pid_t, role: String, frame: CGRect, expectedPIDs: Set<pid_t>, target: CGRect) -> Bool {
        return expectedPIDs.contains(pid) && allowedRoles.contains(role) && framesMatch(frame, target)
    }

    static func didReact(before: ReactionSnapshot, after: ReactionSnapshot, pids: Set<pid_t>, requiresWindowChange: Bool = false) -> Bool {
        if before.windowIDs != after.windowIDs { return true }
        if requiresWindowChange { return false }
        if before.frontmostPID != after.frontmostPID, let pid = after.frontmostPID, pids.contains(pid) { return true }
        return false
    }

    static func outcome(for error: AXError, didReact: Bool, offscreenActionAttempted: Bool = false, requiresReaction: Bool = false) -> Outcome {
        if didReact { return .activated }
        if error == .success && !offscreenActionAttempted && !requiresReaction { return .activated }
        // Once attempted, even an error cannot authorize a second input.
        return .uncertain
    }

    private static func validFrame(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite && !frame.isEmpty &&
        [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite)
    }

    @MainActor
    private static func snapshot(pids: Set<pid_t>, requiresVisibleScreenIntersection: Bool = false) -> ReactionSnapshot {
        let screens = requiresVisibleScreenIntersection ? NSScreen.screens.map { CGDisplayBounds($0.displayID) } : []
        let owned = WindowInfo.createWindows(option: .onScreen).filter {
            pids.contains($0.ownerPID) && validFrame($0.bounds) &&
            (!requiresVisibleScreenIntersection || intersectsVisibleScreen($0.bounds, screens: screens))
        }
        return ReactionSnapshot(windowIDs: Set(owned.map(\.windowID)), frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    static func intersectsVisibleScreen(_ frame: CGRect, screens: [CGRect]) -> Bool {
        validFrame(frame) && screens.contains { $0.intersects(frame) }
    }

    private static func attribute(_ object: AXUIElement, _ name: String, request: Request) -> CFTypeRef? {
        guard request.canResolve else { return nil }
        AXUIElementSetMessagingTimeout(object, 0.08)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(object, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func frame(of object: AXUIElement, request: Request) -> CGRect? {
        guard let position = attribute(object, kAXPositionAttribute, request: request),
              let size = attribute(object, kAXSizeAttribute, request: request),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        let positionValue = unsafeBitCast(position, to: AXValue.self)
        let sizeValue = unsafeBitCast(size, to: AXValue.self)
        guard AXValueGetType(positionValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    /// The focused menu can be a modal tracking loop without a fresh CG
    /// window ID. Keep only this boolean, never the menu's text or contents.
    private static func menuState(app: AXUIElement, request: Request) -> Bool? {
        guard let focused = element(attribute(app, kAXFocusedUIElementAttribute, request: request)),
              let role = attribute(focused, kAXRoleAttribute, request: request) as? String else { return nil }
        if role == kAXMenuRole as String || role == kAXMenuItemRole as String { return true }
        guard let window = element(attribute(app, kAXFocusedWindowAttribute, request: request)) else { return false }
        return (attribute(window, kAXModalAttribute, request: request) as? Bool) ?? false
    }
}
