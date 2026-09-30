//
//  MouseHelpers.swift
//  Ice
//

import CoreGraphics
import Foundation
import OSLog

/// One physical hide for all nested operations, with a last-resort deadline.
/// The lock also covers the WindowServer calls so an expiring hide cannot race
/// with a new operation and leave the cursor hidden after its cleanup.
private final class CursorVisibility: @unchecked Sendable {
    private let lock = NSLock()
    private var depth = 0
    private var generation = 0
    private var isPhysicallyHidden = false
    private var expired = false
    private var originalPosition: CGPoint?
    private var originalMouseGeneration: UInt64 = 0

    func hide() -> Int {
        lock.lock()
        defer { lock.unlock() }
        if depth == 0 {
            generation &+= 1
            expired = false
            let mouse = PhysicalInputState.shared.mouseSnapshot
            originalPosition = CGEvent(source: nil)?.location
            originalMouseGeneration = mouse.generation
            let result = CGDisplayHideCursor(CGMainDisplayID())
            isPhysicallyHidden = result == .success
            expired = result != .success
            if result != .success {
                Logger.default.error("CGDisplayHideCursor failed with error \(result.logString, privacy: .public)")
            }
            let currentGeneration = generation
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 1.25) { [weak self] in
                self?.expire(generation: currentGeneration)
            }
        }
        depth += 1
        return generation
    }

    func show(generation expectedGeneration: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let expectedGeneration, expectedGeneration != generation { return }
        guard depth > 0 else { return }
        depth -= 1
        if depth == 0 { restore() }
    }

    func hasExpired(generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.generation != generation || expired
    }

    func restoreImmediately() {
        lock.lock()
        defer { lock.unlock() }
        expired = true
        restore()
    }

    private func expire(generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard self.generation == generation, depth > 0, !expired else { return }
        expired = true
        restore()
        Logger.default.warning("Restored cursor after the menu operation exceeded its hiding deadline")
    }

    private func restore() {
        guard isPhysicallyHidden else { return }
        let mouse = PhysicalInputState.shared.mouseSnapshot
        let destination = mouse.generation == originalMouseGeneration ? originalPosition : mouse.location
        if let destination, destination.x.isFinite, destination.y.isFinite {
            let result = CGWarpMouseCursorPosition(destination)
            if result != .success {
                Logger.default.error("CGWarpMouseCursorPosition failed with error \(result.logString, privacy: .public)")
            }
        }
        let result = CGDisplayShowCursor(CGMainDisplayID())
        if result != .success {
            Logger.default.error("CGDisplayShowCursor failed with error \(result.logString, privacy: .public)")
        }
        isPhysicallyHidden = false
    }
}

/// A namespace for mouse helper operations.
enum MouseHelpers {
    private static let cursorVisibility = CursorVisibility()

    static func startInputMonitoring() { _ = PhysicalInputState.shared }
    static var inputGeneration: UInt64 { PhysicalInputState.shared.generation }
    static var physicalModifierFlags: CGEventFlags { PhysicalInputState.shared.modifierFlags }
    static func hasUserPausedInput(for duration: Duration) -> Bool {
        PhysicalInputState.shared.hasPaused(for: duration)
    }

    /// Keeps the cursor hidden across nested move/click calls. Finishing more
    /// than once is safe; the deadline also releases the physical hide even if
    /// a nested event operation is still waiting for another process.
    final class CursorHidingScope: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private let generation: Int

        fileprivate init() { generation = cursorVisibility.hide() }

        var hasExpired: Bool { cursorVisibility.hasExpired(generation: generation) }

        func finish() {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            lock.unlock()
            cursorVisibility.show(generation: generation)
        }

        deinit { finish() }
    }

    static func beginCursorHiding() -> CursorHidingScope { CursorHidingScope() }

    static func restoreCursorImmediately() { cursorVisibility.restoreImmediately() }
    /// Returns the location of the mouse cursor in the coordinate
    /// space used by `AppKit`, with the origin at the bottom left
    /// of the screen.
    static var locationAppKit: CGPoint? {
        CGEvent(source: nil)?.unflippedLocation
    }

    /// Returns the location of the mouse cursor in the coordinate
    /// space used by `CoreGraphics`, with the origin at the top left
    /// of the screen.
    static var locationCoreGraphics: CGPoint? {
        CGEvent(source: nil)?.location
    }

    /// Hides the mouse cursor and increments the hide cursor count.
    static func hideCursor() {
        _ = cursorVisibility.hide()
    }

    /// Decrements the hide cursor count and shows the mouse cursor
    /// if the count is `0`.
    static func showCursor() {
        cursorVisibility.show()
    }

    /// Connects or disconnects the positions of the mouse and cursor.
    ///
    /// - Parameter connected: A Boolean value that determines whether
    ///   to connect or disconnect the positions.
    static func associateMouseAndCursor(_ connected: Bool) {
        let result = CGAssociateMouseAndMouseCursorPosition(connected ? 1 : 0)
        if result != .success {
            Logger.default.error("CGAssociateMouseAndMouseCursorPosition failed with error \(result.logString, privacy: .public)")
        }
    }

    /// Returns a Boolean value that indicates whether a mouse button
    /// is pressed.
    ///
    /// - Parameter button: The mouse button to check. Pass `nil` to
    ///   check all available mouse buttons (Quartz supports up to 32).
    static func isButtonPressed(_ button: CGMouseButton? = nil) -> Bool {
        let stateID = CGEventSourceStateID.combinedSessionState
        if let button {
            return CGEventSource.buttonState(stateID, button: button)
        }
        for n: UInt32 in 0...31 {
            guard
                let button = CGMouseButton(rawValue: n),
                CGEventSource.buttonState(stateID, button: button)
            else {
                continue
            }
            return true
        }
        return false
    }

    /// Returns a Boolean value that indicates whether the last mouse
    /// movement event occurred within the given duration.
    ///
    /// - Parameter duration: The duration within which the last mouse
    ///   movement event must have occurred in order to return `true`.
    static func lastMovementOccurred(within duration: Duration) -> Bool {
        let stateID = CGEventSourceStateID.combinedSessionState
        let seconds = CGEventSource.secondsSinceLastEventType(stateID, eventType: .mouseMoved)
        return .seconds(seconds) <= duration
    }

    /// Returns a Boolean value that indicates whether the last scroll
    /// wheel event occurred within the given duration.
    ///
    /// - Parameter duration: The duration within which the last scroll
    ///   wheel event must have occurred in order to return `true`.
    static func lastScrollWheelOccurred(within duration: Duration) -> Bool {
        let stateID = CGEventSourceStateID.combinedSessionState
        let seconds = CGEventSource.secondsSinceLastEventType(stateID, eventType: .scrollWheel)
        return .seconds(seconds) <= duration
    }
}
