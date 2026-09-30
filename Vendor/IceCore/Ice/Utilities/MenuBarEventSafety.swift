// Misdirected-event detection adapted from Thaw's MenuBarItemManager+EventHelpers.
// Copyright (Ice) © 2023–2025 Jordan Baird
// Copyright (Thaw) © 2026 Toni Förster. Licensed under GNU GPLv3.
// Upstream revision: 2f5818785b3909d63e71a358e42a5fc313741476

import Cocoa
import OSLog

/// A session filter for our own synthetic mouse events only. WindowServer can
/// rebind an off-screen event to the Apple menu despite its original window ID.
/// A passive listener cannot stop that event from reaching the wrong window.
final class MenuBarEventSafety: @unchecked Sendable {
    static let shared = MenuBarEventSafety()
    private static let logger = Logger(subsystem: "Shiyi.MenuCore", category: "MenuBarEventSafety")
    private static let recordLimit = 512
    // Event posting is serialized. Leave room for the normal paired release
    // and one recovery release after the last admitted mouse-down.
    private static let reservedReleaseRecords = 2

    struct Fingerprint: Equatable {
        let windowUnderPointer: Int64
        let windowHandlingEvent: Int64
        let windowID: Int64

        init(event: CGEvent) {
            windowUnderPointer = event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
            windowHandlingEvent = event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
            windowID = event.getIntegerValueField(CGEventField(rawValue: 0x33)!)
        }
    }

    private struct Record {
        let type: CGEventType
        let fingerprint: Fingerprint
        let targetPID: pid_t
        let point: CGPoint
        let expires: ContinuousClock.Instant
        var reported = false
    }

    private let lock = NSLock()
    private var identifier = Int64.random(in: 1...(Int64.max / 2))
    private var records = [Int64: Record]()
    private var tap: EventTap?

    private init() {
        tap = EventTap(
            label: "Shiyi synthetic event safety",
            types: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                    .otherMouseDown, .otherMouseUp],
            location: .sessionEventTap,
            placement: .headInsertEventTap,
            option: .defaultTap
        ) { [weak self] _, event in
            guard self?.shouldDiscard(event) == true else { return event }
            return nil
        }
    }

    /// An allocation address can be reused while a delayed echo is in flight.
    /// These identifiers remain distinct across released CGEvent objects.
    func nextIdentifier() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        identifier &+= 1
        return identifier
    }

    /// Register before posting. Keep protection after completion/cancellation,
    /// since neither means an event already queued in WindowServer disappeared.
    /// Records are bounded; this creates one filter, not a tap per mouse event.
    func protect(_ event: CGEvent, targetPID: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let tap, tap.isValid else { return false }
        tap.enable()
        guard tap.isEnabled else { return false }
        let now = ContinuousClock.now
        records = records.filter { $0.value.expires > now }
        let marker = event.getIntegerValueField(.eventSourceUserData)
        guard marker != 0 else { return false }
        let limit: Int
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            limit = Self.recordLimit - Self.reservedReleaseRecords
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            limit = Self.recordLimit
        default:
            return false
        }
        guard records[marker] != nil || records.count < limit else { return false }
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(targetPID))
        records[marker] = Record(
            type: event.type, fingerprint: Fingerprint(event: event), targetPID: targetPID,
            point: event.location, expires: now.advanced(by: .seconds(30))
        )
        return true
    }

    private func shouldDiscard(_ event: CGEvent) -> Bool {
        let identifier = event.getIntegerValueField(.eventSourceUserData)
        lock.lock()
        guard var record = records[identifier] else { lock.unlock(); return false }
        if record.expires <= .now {
            records.removeValue(forKey: identifier)
            lock.unlock()
            return false
        }
        let received = Fingerprint(event: event)
        let discard = Self.isMisdirected(
            expectedType: record.type, receivedType: event.type,
            expected: record.fingerprint, received: received
        )
        let report = discard && !record.reported
        if report {
            record.reported = true
            records[identifier] = record
        }
        lock.unlock()
        if report {
            Self.logger.warning(
                "Blocked misdirected Shiyi event: type=\(event.type.rawValue, privacy: .public) targetPID=\(record.targetPID, privacy: .public) expected=\(record.fingerprint.windowUnderPointer, privacy: .public)/\(record.fingerprint.windowHandlingEvent, privacy: .public)/\(record.fingerprint.windowID, privacy: .public) received=\(received.windowUnderPointer, privacy: .public)/\(received.windowHandlingEvent, privacy: .public)/\(received.windowID, privacy: .public) from=\(String(describing: record.point), privacy: .public) at=\(String(describing: event.location), privacy: .public)"
            )
        }
        return discard
    }

    /// Called only after the exact, unique marker has identified our event.
    static func isMisdirected(expectedType: CGEventType, receivedType: CGEventType,
                              expected: Fingerprint, received: Fingerprint) -> Bool {
        expectedType == receivedType && expected != received
    }
}
