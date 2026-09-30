import CoreGraphics
import Foundation

/// Tracks input activity without retaining characters or text. This tap stays
/// active while the menu's own event monitors are paused for synthetic events.
final class PhysicalInputState: @unchecked Sendable {
    static let shared = PhysicalInputState()

    struct MouseSnapshot {
        let generation: UInt64
        let location: CGPoint?
    }

    private static let heldModifierMask: CGEventFlags = [
        .maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn,
    ]
    private static let modifierKeys: [(CGEventFlags, [CGKeyCode])] = [
        (.maskCommand, [54, 55]), (.maskShift, [56, 60]),
        (.maskAlternate, [58, 61]), (.maskControl, [59, 62]),
        (.maskSecondaryFn, [63]),
    ]
    private static let inputTypes: [CGEventType] = [
        .keyDown, .keyUp, .flagsChanged, .mouseMoved, .scrollWheel,
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
    ]

    private let lock = NSLock()
    private var activityGeneration: UInt64 = 0
    private var lastActivity = ContinuousClock.now
    private var heldKeys = Set<CGKeyCode>()
    private var mouseGeneration: UInt64 = 0
    private var mouseLocation: CGPoint?
    private var tap: EventTap?

    private init() {
        // Also cover keys already held when the core starts. Later snapshots
        // recheck actual key state, so a missed key-up cannot leave a stale latch.
        heldKeys = Set((0..<128).map(CGKeyCode.init).filter {
            $0 != 57 && CGEventSource.keyState(.hidSystemState, key: $0)
        })
        mouseLocation = CGEvent(source: nil)?.location
        let tap = EventTap(
            label: "Physical input activity",
            types: Self.inputTypes,
            location: .hidEventTap,
            placement: .headInsertEventTap,
            // Use the already granted Accessibility permission. A listen-only
            // keyboard tap would require separate Input Monitoring permission.
            option: .defaultTap
        ) { [weak self] _, event in
            self?.observe(event)
            return event
        }
        self.tap = tap
        if tap.isValid { tap.enable() }
    }

    var generation: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return activityGeneration
    }

    /// The hardware table is kept independent by the core's private synthetic
    /// event source. Explicit key state also covers a held Fn/Globe key.
    var modifierFlags: CGEventFlags {
        var flags = CGEventSource.flagsState(.hidSystemState)
            .intersection(Self.heldModifierMask.union(.maskAlphaShift))
        for (mask, keys) in Self.modifierKeys where keys.contains(where: {
            CGEventSource.keyState(.hidSystemState, key: $0)
        }) {
            flags.insert(mask)
        }
        return flags
    }

    var mouseSnapshot: MouseSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return MouseSnapshot(generation: mouseGeneration, location: mouseLocation)
    }

    func hasPaused(for duration: Duration) -> Bool {
        guard modifierFlags.intersection(Self.heldModifierMask).isEmpty else { return false }
        for number: UInt32 in 0..<32 {
            if let button = CGMouseButton(rawValue: number),
               CGEventSource.buttonState(.hidSystemState, button: button) { return false }
        }

        lock.lock()
        let keys = heldKeys
        let snapshotGeneration = activityGeneration
        let timestamp = lastActivity
        lock.unlock()

        let stillHeld = keys.filter { CGEventSource.keyState(.hidSystemState, key: $0) }
        lock.lock()
        if snapshotGeneration == activityGeneration { heldKeys = stillHeld }
        let changed = snapshotGeneration != activityGeneration
        lock.unlock()
        guard !changed, stillHeld.isEmpty, timestamp.duration(to: .now) >= duration else { return false }

        // This remains available if macOS temporarily suppresses the observing
        // tap (for example during secure input); no additional permission prompt.
        guard Self.inputTypes.allSatisfy({
            .seconds(CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0)) >= duration
        }) else { return false }
        // A suppressed/unavailable tap can miss a nonrepeating key-down. Read
        // the small virtual-key table only after all cheaper idle checks pass.
        return (0..<128).allSatisfy {
            $0 == 57 || !CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0))
        }
    }

    private func observe(_ event: CGEvent) {
        // Session/PID reposts do not cross this HID tap. Also reject a local
        // synthesized event should another route deliver it here.
        guard event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(ProcessInfo.processInfo.processIdentifier) else { return }
        lock.lock()
        defer { lock.unlock() }
        activityGeneration &+= 1
        lastActivity = .now
        switch event.type {
        case .keyDown:
            let key = CGKeyCode(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            if key != 57 { heldKeys.insert(key) }
        case .keyUp:
            heldKeys.remove(CGKeyCode(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)))
        case .flagsChanged:
            break
        default:
            let point = event.location
            if point.x.isFinite, point.y.isFinite, mouseLocation != point {
                mouseGeneration &+= 1
                mouseLocation = point
            }
        }
    }
}
