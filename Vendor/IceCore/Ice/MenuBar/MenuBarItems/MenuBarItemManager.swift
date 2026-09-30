//
//  MenuBarItemManager.swift
//  Ice
//

import Cocoa
import Combine
import OSLog
import Semaphore

/// Manager for menu bar items.
@MainActor
final class MenuBarItemManager: ObservableObject {
    /// The current cache of menu bar items.
    @Published private(set) var itemCache = ItemCache(displayID: nil)

    /// Logger for the menu bar item manager.
    private nonisolated let logger = Logger.menuBarItemManager

    /// Semaphore to prevent overlapping event operations.
    private nonisolated let eventSemaphore = AsyncSemaphore(value: 1)

    /// A complete activation or restoration owns the interaction, not just an
    /// individual mouse event. New requests invalidate queued timer callbacks.
    private let interactionSemaphore = AsyncSemaphore(value: 1)
    private var interactionGeneration = 0
    private var rehideGeneration = 0
    private var activeBarItemTag: MenuBarItemTag?
    private var isHandlingInteraction = false
    private var activeHandoffTask: Task<Void, Error>?
    private var isShuttingDown = false

    /// Actor for managing menu bar item cache operations.
    private let cacheActor = CacheActor()

    /// Contexts for temporarily shown menu bar items.
    private var temporarilyShownItemContexts = [TemporarilyShownItemContext]()

    /// A timer for rehiding temporarily shown menu bar items.
    private var rehideTimer: Timer?

    /// Timestamp of the most recent menu bar item move operation.
    private var lastMoveOperationTimestamp: ContinuousClock.Instant?

    /// Cached timeouts for move operations.
    private var moveOperationTimeouts = [MenuBarItemTag: Duration]()

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// Sets up the manager.
    func performSetup(with appState: AppState) async {
        self.appState = appState
        MouseHelpers.startInputMonitoring()
        await cacheItemsRegardless()
        configureCancellables(with: appState)
    }

    func shutdown() {
        isShuttingDown = true
        interactionGeneration &+= 1
        invalidateRehideTimer()
        activeHandoffTask?.cancel()
        MouseHelpers.restoreCursorImmediately()
        cancellables.removeAll()
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables(with appState: AppState) {
        var c = Set<AnyCancellable>()

        NSWorkspace.shared.publisher(for: \.runningApplications)
            .delay(for: 0.25, scheduler: DispatchQueue.main)
            .discardMerge(Timer.publish(every: 5, on: .main, in: .default).autoconnect())
            .debounce(for: 1, scheduler: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else {
                    return
                }
                Task {
                    await self.cacheItemsIfNeeded()
                }
            }
            .store(in: &c)

        appState.navigationState.$settingsNavigationIdentifier
            .sink { [weak self] identifier in
                guard let self, identifier == .menuBarLayout else {
                    return
                }
                Task {
                    await self.cacheItemsRegardless()
                }
            }
            .store(in: &c)

        cancellables = c
    }

    /// Returns a Boolean value that indicates whether the most recent
    /// menu bar item move operation occurred within the given duration.
    func lastMoveOperationOccurred(within duration: Duration) -> Bool {
        guard let timestamp = lastMoveOperationTimestamp else {
            return false
        }
        return timestamp.duration(to: .now) <= duration
    }
}

// MARK: - Item Cache

extension MenuBarItemManager {
    /// An actor that manages menu bar item cache operations.
    private final actor CacheActor {
        /// Stored task for the current cache operation.
        private var cacheTask: Task<Void, Never>?

        /// A list of the menu bar item window identifiers at the time
        /// of the previous cache.
        private(set) var cachedItemWindowIDs = [CGWindowID]()

        /// Runs the given async closure as a task and waits for it to
        /// complete before returning.
        ///
        /// If a task from a previous call to this method is currently
        /// running, that task is cancelled and replaced.
        func runCacheTask(_ operation: @escaping () async -> Void) async {
            cacheTask.take()?.cancel()
            let task = Task(operation: operation)
            cacheTask = task
            await task.value
        }

        /// Updates the list of cached menu bar item window identifiers.
        func updateCachedItemWindowIDs(_ itemWindowIDs: [CGWindowID]) {
            cachedItemWindowIDs = itemWindowIDs
        }

        /// Clears the list of cached menu bar item window identifiers.
        func clearCachedItemWindowIDs() {
            cachedItemWindowIDs.removeAll()
        }
    }

    /// Cache for menu bar items.
    struct ItemCache: Hashable {
        /// Storage for cached menu bar items, keyed by section.
        private var storage = [MenuBarSection.Name: [MenuBarItem]]()

        /// The identifier of the display with the active menu bar at
        /// the time this cache was created.
        let displayID: CGDirectDisplayID?

        /// The cached menu bar items as an array.
        var managedItems: [MenuBarItem] {
            MenuBarSection.Name.allCases.reduce(into: []) { result, section in
                guard let items = storage[section] else {
                    return
                }
                result.append(contentsOf: items)
            }
        }

        /// Creates a cache with the given display identifier.
        init(displayID: CGDirectDisplayID?) {
            self.displayID = displayID
        }

        // TODO: This is redundant now, so remove it.
        /// Returns the managed menu bar items for the given section.
        func managedItems(for section: MenuBarSection.Name) -> [MenuBarItem] {
            self[section]
        }

        /// Returns the address for the menu bar item with the given tag,
        /// if it exists in the cache.
        func address(for tag: MenuBarItemTag) -> (section: MenuBarSection.Name, index: Int)? {
            for (section, items) in storage {
                guard let index = items.firstIndex(matching: tag) else {
                    continue
                }
                return (section, index)
            }
            return nil
        }

        /// Inserts the given menu bar item into the cache at the specified
        /// destination.
        mutating func insert(_ item: MenuBarItem, at destination: MoveDestination) {
            let targetTag = destination.targetItem.tag

            if targetTag == .hiddenControlItem {
                switch destination {
                case .leftOfItem:
                    self[.hidden].append(item)
                case .rightOfItem:
                    self[.visible].insert(item, at: 0)
                }
                return
            }

            if targetTag == .alwaysHiddenControlItem {
                switch destination {
                case .leftOfItem:
                    self[.alwaysHidden].append(item)
                case .rightOfItem:
                    self[.hidden].insert(item, at: 0)
                }
                return
            }

            guard case (let section, var index)? = address(for: targetTag) else {
                return
            }

            if case .rightOfItem = destination {
                let range = self[section].startIndex...self[section].endIndex
                index = (index + 1).clamped(to: range)
            }

            self[section].insert(item, at: index)
        }

        /// Accesses the items in the given section.
        subscript(section: MenuBarSection.Name) -> [MenuBarItem] {
            get { storage[section, default: []] }
            set { storage[section] = newValue }
        }
    }

    /// A pair of control items, taken from a list of menu bar items
    /// during a menu bar item cache operation.
    private struct ControlItemPair {
        let hidden: MenuBarItem
        let alwaysHidden: MenuBarItem?

        init?(items: inout [MenuBarItem]) {
            guard let hidden = items.removeFirst(matching: .hiddenControlItem) else {
                return nil
            }
            self.hidden = hidden
            self.alwaysHidden = items.removeFirst(matching: .alwaysHiddenControlItem)
        }
    }

    /// Context maintained during a menu bar item cache operation.
    private struct CacheContext {
        let controlItems: ControlItemPair

        var cache: ItemCache
        var temporarilyShownItems = [(MenuBarItem, MoveDestination)]()
        var shouldClearCachedItemWindowIDs = false

        private(set) lazy var hiddenControlItemBounds = bestBounds(for: controlItems.hidden)
        private(set) lazy var alwaysHiddenControlItemBounds = controlItems.alwaysHidden.map(bestBounds)

        init(controlItems: ControlItemPair, displayID: CGDirectDisplayID?) {
            self.controlItems = controlItems
            self.cache = ItemCache(displayID: displayID)
        }

        func bestBounds(for item: MenuBarItem) -> CGRect {
            Bridging.getWindowBounds(for: item.windowID) ?? item.bounds
        }

        func isValidForCaching(_ item: MenuBarItem) -> Bool {
            if !item.canBeHidden {
                return false
            }
            if item.isSystemClone {
                return false
            }
            if item.isControlItem, item.tag != .visibleControlItem {
                return false
            }
            return true
        }

        mutating func findSection(for item: MenuBarItem) -> MenuBarSection.Name? {
            lazy var itemBounds = bestBounds(for: item)
            return MenuBarSection.Name.allCases.first { section in
                switch section {
                case .visible:
                    return itemBounds.minX >= hiddenControlItemBounds.maxX
                case .hidden:
                    if let alwaysHiddenControlItemBounds {
                        return itemBounds.maxX <= hiddenControlItemBounds.minX &&
                        itemBounds.minX >= alwaysHiddenControlItemBounds.maxX
                    } else {
                        return itemBounds.maxX <= hiddenControlItemBounds.minX
                    }
                case .alwaysHidden:
                    if let alwaysHiddenControlItemBounds {
                        return itemBounds.maxX <= alwaysHiddenControlItemBounds.minX
                    } else {
                        return false
                    }
                }
            }
        }
    }

    /// Caches the given menu bar items, without ensuring that the provided
    /// control items are correctly ordered.
    private func uncheckedCacheItems(
        items: [MenuBarItem],
        controlItems: ControlItemPair,
        displayID: CGDirectDisplayID?
    ) async {
        var context = CacheContext(controlItems: controlItems, displayID: displayID)

        for item in items where context.isValidForCaching(item) {
            if item.sourcePID == nil {
                logger.warning("Missing sourcePID for \(item.logString, privacy: .public)")
                context.shouldClearCachedItemWindowIDs = true
            }

            if let temp = temporarilyShownItemContexts.first(where: { $0.tag == item.tag }) {
                // Cache temporarily shown items as if they were in their original locations.
                // Keep track of them separately and use their return destinations to insert
                // them into the cache once all other items have been handled.
                context.temporarilyShownItems.append((item, temp.returnDestination))
                continue
            }

            if let section = context.findSection(for: item) {
                context.cache[section].append(item)
                continue
            }

            logger.warning("Couldn't find section for caching \(item.logString, privacy: .public)")
            context.shouldClearCachedItemWindowIDs = true
        }

        for (item, destination) in context.temporarilyShownItems {
            context.cache.insert(item, at: destination)
        }

        if context.shouldClearCachedItemWindowIDs {
            logger.info("Clearing cached menu bar item windowIDs")
            await cacheActor.clearCachedItemWindowIDs() // Ensure next cache isn't skipped.
        }

        itemCache = context.cache
        logger.debug("Updated menu bar item cache")
    }

    /// Caches the current menu bar items, regardless of whether the
    /// items have changed since the previous cache.
    ///
    /// Before caching, this method ensures that the control items for
    /// the hidden and always-hidden sections are correctly ordered,
    /// arranging them into valid positions if needed.
    func cacheItemsRegardless(_ currentItemWindowIDs: [CGWindowID]? = nil) async {
        await cacheActor.runCacheTask { [weak self] in
            guard let self else {
                return
            }

            guard !isShuttingDown, !isHandlingInteraction, !lastMoveOperationOccurred(within: .seconds(1)) else {
                logger.debug("Skipping menu bar item cache due to recent item movement")
                return
            }

            let displayID = Bridging.getActiveMenuBarDisplayID()
            var items = await MenuBarItem.getMenuBarItems(option: .activeSpace)

            let itemWindowIDs = currentItemWindowIDs ?? items.reversed().map { $0.windowID }
            await cacheActor.updateCachedItemWindowIDs(itemWindowIDs)

            guard let controlItems = ControlItemPair(items: &items) else {
                // ???: Is clearing the cache the best thing to do here?
                logger.warning("Missing control item for hidden section, clearing menu bar item cache")
                itemCache = ItemCache(displayID: nil)
                return
            }

            await enforceControlItemOrder(controlItems: controlItems)
            await uncheckedCacheItems(items: items, controlItems: controlItems, displayID: displayID)
        }
    }

    /// Caches the current menu bar items, if the items have changed
    /// since the previous cache.
    ///
    /// Before caching, this method ensures that the control items for
    /// the hidden and always-hidden sections are correctly ordered,
    /// arranging them into valid positions if needed.
    func cacheItemsIfNeeded() async {
        let itemWindowIDs = Bridging.getMenuBarWindowList(option: [.itemsOnly, .activeSpace])
        if await cacheActor.cachedItemWindowIDs != itemWindowIDs {
            await cacheItemsRegardless(itemWindowIDs)
        }
    }
}

// MARK: - Event Helpers

extension MenuBarItemManager {
    /// Tracks actual posts and acknowledgements rather than inferring them
    /// from which await was cancelled. A release cannot precede its own down.
    private final class MouseEventProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var didPostDown = false
        private var acknowledgedUps = 0

        var needsRelease: Bool {
            lock.lock()
            defer { lock.unlock() }
            return didPostDown && acknowledgedUps < 2
        }

        func posted(_ type: CGEventType) {
            lock.lock()
            defer { lock.unlock() }
            if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
                didPostDown = true
            }
        }

        func received(_ type: CGEventType) {
            lock.lock()
            defer { lock.unlock() }
            if type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp {
                acknowledgedUps += 1
            }
        }
    }

    private struct PhysicalInputGuard: Sendable {
        let generation: UInt64
        let quietPeriod: Duration
        let cursorScope: MouseHelpers.CursorHidingScope?

        init(quietPeriod: Duration, cursorScope: MouseHelpers.CursorHidingScope? = nil) {
            generation = MouseHelpers.inputGeneration
            self.quietPeriod = quietPeriod
            self.cursorScope = cursorScope
        }

        var canStart: Bool {
            generation == MouseHelpers.inputGeneration &&
            MouseHelpers.hasUserPausedInput(for: quietPeriod) &&
            cursorScope?.hasExpired != true
        }

        var inputUnchanged: Bool {
            generation == MouseHelpers.inputGeneration && cursorScope?.hasExpired != true
        }
    }

    /// Never use an off-screen drop coordinate as a recovery click. The
    /// original visible item is preferred; a hidden item may use its visible
    /// destination. Keep clear of the screen's Apple-menu corner as well.
    private nonisolated static func visibleReleasePoint(
        itemBounds: CGRect,
        targetBounds: CGRect,
        displays: [CGRect]
    ) -> CGPoint? {
        for bounds in [itemBounds, targetBounds] {
            guard !bounds.isEmpty, !bounds.isInfinite,
                  bounds.minX.isFinite, bounds.minY.isFinite else { continue }
            if displays.contains(where: { $0.contains(bounds) && bounds.minX >= $0.minX + 64 }) {
                return bounds.center
            }
        }
        return nil
    }

    /// Only a down which actually entered the event stream can need recovery.
    /// Keep the original targeted handshake and double release, using a known
    /// visible point instead of the hidden destination or an unpaired global up.
    private func releaseInterruptedMouseOperation(
        item: MenuBarItem,
        source: CGEventSource,
        type: MenuBarItemEventType,
        fallbackPoint: CGPoint?,
        progress: MouseEventProgress,
        cursorScope: MouseHelpers.CursorHidingScope?,
        isMove: Bool
    ) async {
        guard progress.needsRelease else { return }
        guard let point = fallbackPoint,
              let current = WindowInfo(windowID: item.windowID),
              current.ownerPID == item.ownerPID,
              !current.bounds.isEmpty, !current.bounds.isInfinite,
              current.bounds.minX.isFinite, current.bounds.minY.isFinite,
              NSScreen.screens.contains(where: {
                  let display = CGDisplayBounds($0.displayID)
                  return display.contains(point) && point.x >= display.minX + 64
              }),
              let release = CGEvent.menuBarItemEvent(item: item, source: source, type: type, location: point)
        else {
            logger.warning("Skipped unsafe mouse recovery for \(item.logString, privacy: .public)")
            return
        }
        logger.debug("Releasing interrupted menu operation at a validated visible point")
        // Cleanup must run even when its parent was cancelled; its own event
        // completion still has a short, explicit timeout and no retry loop.
        let cleanup = Task {
            if isMove {
                try await self.scrombleEvent(release, item: item, timeout: .milliseconds(100), repeating: 2, progress: progress, cursorScope: cursorScope)
            } else {
                try await self.postEventWithBarrier(release, to: item, timeout: .milliseconds(100), repeating: 2, progress: progress, cursorScope: cursorScope)
            }
        }
        do { try await cleanup.value } catch {
            logger.warning("Targeted mouse recovery did not complete: \(error, privacy: .public)")
        }
    }

    /// An error that can occur during menu bar item event operations.
    enum EventError: CustomStringConvertible, LocalizedError {
        case userInputActive
        /// A generic indication of a failure.
        case cannotComplete
        /// An event source cannot be created or is otherwise invalid.
        case invalidEventSource
        /// The location of the mouse cannot be found.
        case missingMouseLocation
        /// A failure during the creation of an event.
        case eventCreationFailure(MenuBarItem)
        /// A timeout during an event operation.
        case eventOperationTimeout(MenuBarItem)
        /// A menu bar item is not movable.
        case itemNotMovable(MenuBarItem)
        /// A timeout waiting for a menu bar item to respond to an event.
        case itemResponseTimeout(MenuBarItem)
        /// A menu bar item's bounds cannot be found.
        case missingItemBounds(MenuBarItem)

        var description: String {
            switch self {
            case .userInputActive:
                "\(Self.self).userInputActive"
            case .cannotComplete:
                "\(Self.self).cannotComplete"
            case .invalidEventSource:
                "\(Self.self).invalidEventSource"
            case .missingMouseLocation:
                "\(Self.self).missingMouseLocation"
            case .eventCreationFailure(let item):
                "\(Self.self).eventCreationFailure(item: \(item.tag))"
            case .eventOperationTimeout(let item):
                "\(Self.self).eventOperationTimeout(item: \(item.tag))"
            case .itemNotMovable(let item):
                "\(Self.self).itemNotMovable(item: \(item.tag))"
            case .itemResponseTimeout(let item):
                "\(Self.self).itemResponseTimeout(item: \(item.tag))"
            case .missingItemBounds(let item):
                "\(Self.self).missingItemBounds(item: \(item.tag))"
            }
        }

        var errorDescription: String? {
            switch self {
            case .userInputActive:
                "User input resumed before the menu operation completed"
            case .cannotComplete:
                "Operation could not be completed"
            case .invalidEventSource:
                "Invalid event source"
            case .missingMouseLocation:
                "Missing mouse location"
            case .eventCreationFailure(let item):
                "Could not create event for \"\(item.displayName)\""
            case .eventOperationTimeout(let item):
                "Event operation timed out for \"\(item.displayName)\""
            case .itemNotMovable(let item):
                "\"\(item.displayName)\" is not movable"
            case .itemResponseTimeout(let item):
                "\"\(item.displayName)\" took too long to respond"
            case .missingItemBounds(let item):
                "Missing bounds rectangle for \"\(item.displayName)\""
            }
        }

        var recoverySuggestion: String? {
            if case .itemNotMovable = self { return nil }
            return "Please try again. If the error persists, please file a bug report."
        }
    }

    /// Returns a Boolean value that indicates whether the user has
    /// paused input for at least the given duration.
    ///
    /// - Parameter duration: The duration that certain types of input
    ///   events must not have occured within in order to return `true`.
    private nonisolated func hasUserPausedInput(for duration: Duration) -> Bool {
        MouseHelpers.hasUserPausedInput(for: duration)
    }

    /// Waits asynchronously for the user to pause input.
    private nonisolated func waitForUserToPauseInput(timeout: Duration? = nil) async throws {
        let deadline = timeout.map { ContinuousClock.now.advanced(by: $0) }
        while !hasUserPausedInput(for: .milliseconds(50)) {
            try Task.checkCancellation()
            if let deadline, ContinuousClock.now >= deadline {
                throw EventError.cannotComplete
            }
            try await Task.sleep(for: .milliseconds(16))
        }
        try Task.checkCancellation()
    }

    /// Waits between move operations for a dynamic amount of time,
    /// based on the timestamp of the last move operation.
    private nonisolated func waitForMoveOperationBuffer() async throws {
        if let timestamp = await lastMoveOperationTimestamp {
            let buffer = max(.milliseconds(25) - timestamp.duration(to: .now), .zero)
            logger.debug("Move operation buffer: \(buffer)")
            do {
                try await Task.sleep(for: buffer)
            } catch {
                throw EventError.cannotComplete
            }
        }
    }

    /// Waits for the given duration between event operations.
    ///
    /// Since most event operations must perform cleanup or otherwise
    /// run to completion, this method ignores task cancellation.
    private nonisolated func eventSleep(for duration: Duration = .milliseconds(25)) async {
        let task = Task {
            try? await Task.sleep(for: duration)
        }
        await task.value
    }

    /// Returns the current bounds for the given item.
    private nonisolated func getCurrentBounds(for item: MenuBarItem) async throws -> CGRect {
        let task = Task.detached(priority: .userInitiated) {
            guard let bounds = Bridging.getWindowBounds(for: item.windowID) else {
                throw EventError.missingItemBounds(item)
            }
            return bounds
        }
        return try await task.value
    }

    /// Returns the current mouse location.
    private nonisolated func getMouseLocation() throws -> CGPoint {
        guard let location = MouseHelpers.locationCoreGraphics else {
            throw EventError.missingMouseLocation
        }
        return location
    }

    /// Returns the process identifier that can be used to create
    /// and post a menu bar item event.
    private nonisolated func getEventPID(for item: MenuBarItem) -> pid_t {
        // On macOS 26 the logical source can differ from the process hosting
        // the status-item window (notably Control Center). Deliver to its owner.
        item.ownerPID
    }

    /// Returns an event source for a menu bar item event operation.
    private nonisolated func getEventSource(
        with stateID: CGEventSourceStateID = .privateState
    ) throws -> CGEventSource {
        enum Context {
            static var cache = [CGEventSourceStateID: CGEventSource]()
        }
        if let source = Context.cache[stateID] {
            return source
        }
        guard let source = CGEventSource(stateID: stateID) else {
            throw EventError.invalidEventSource
        }
        Context.cache[stateID] = source
        return source
    }

    /// Prevents local events from being suppressed.
    private nonisolated func permitLocalEvents(for source: CGEventSource) {
        let states: [CGEventSuppressionState] = [
            .eventSuppressionStateRemoteMouseDrag,
            .eventSuppressionStateSuppressionInterval,
        ]
        for state in states {
            source.setLocalEventsFilterDuringSuppressionState(.permitAllEvents, state: state)
        }
        source.localEventsSuppressionInterval = 0
    }

    private nonisolated func prepareEventForPosting(
        _ event: CGEvent,
        inputGuard: PhysicalInputGuard?,
        progress: MouseEventProgress?
    ) -> Bool {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if let inputGuard, !inputGuard.canStart { return false }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            // A paired release must not erase a real Fn/modifier press which
            // began while our short drag was in flight.
            event.flags = MouseHelpers.physicalModifierFlags
        default:
            break
        }
        progress?.posted(event.type)
        return true
    }

    private nonisolated static func requiresPIDOnlyRelease(_ type: CGEventType, cursorExpired: Bool) -> Bool {
        cursorExpired && (type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp)
    }

    /// Posts an event to the given menu bar item and waits until
    /// it is received before returning.
    ///
    /// - Parameters:
    ///   - event: The event to post.
    ///   - item: The menu bar item that the event targets.
    ///   - timeout: The base duration to wait before throwing an error.
    ///     The value of this parameter is multiplied by `count` to
    ///     produce the actual timeout duration.
    ///   - count: The number of times to repeat the operation. As it
    ///     is considerably more efficient, prefer increasing this value
    ///     over repeatedly calling `postEventWithBarrier`.
    private nonisolated func postEventWithBarrier(
        _ event: CGEvent,
        to item: MenuBarItem,
        timeout: Duration,
        repeating count: Int = 1,
        inputGuard: PhysicalInputGuard? = nil,
        progress: MouseEventProgress? = nil,
        cursorScope: MouseHelpers.CursorHidingScope? = nil
    ) async throws {
        guard MenuBarEventSafety.shared.protect(event, targetPID: getEventPID(for: item)) else {
            throw EventError.cannotComplete
        }
        MouseHelpers.hideCursor()
        defer {
            MouseHelpers.showCursor()
        }

        guard
            let entryEvent = CGEvent.uniqueNullEvent(),
            let exitEvent = CGEvent.uniqueNullEvent()
        else {
            throw EventError.eventCreationFailure(item)
        }

        let firstLocation = EventTap.Location.pid(getEventPID(for: item))
        let secondLocation = EventTap.Location.sessionEventTap

        var count = count
        var isDirectRelease = false
        let completion = EventOperationCompletion()
        let operationTimeout = timeout * count
        let watchdog = Task {
            do {
                try await Task.sleep(for: operationTimeout)
                completion.finish(.failure(EventError.eventOperationTimeout(item)))
            } catch { }
        }
        defer {
            watchdog.cancel()
            completion.finish(.failure(CancellationError()))
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                // Listen for the following events at the first location and
                // perform the following actions:
                //
                // - Entry event: Decrement the count and post the real event
                //   to the second location.
                // - Exit event: Disable the tap and resume the continuation.
                let eventTap1 = EventTap(
                    label: "EventTap 1",
                    types: [.null, event.type],
                    location: firstLocation,
                    placement: .headInsertEventTap,
                    option: .defaultTap
                ) { tap, rEvent in
                    return completion.performIfPending { () -> CGEvent? in
                        if rEvent.matches(entryEvent, byIntegerFields: [.eventSourceUserData]) {
                            guard self.prepareEventForPosting(event, inputGuard: inputGuard, progress: progress) else {
                                completion.finish(.failure(EventError.userInputActive))
                                return nil
                            }
                            count -= 1
                            if Self.requiresPIDOnlyRelease(event.type, cursorExpired: cursorScope?.hasExpired == true) {
                                isDirectRelease = true
                                event.post(to: firstLocation)
                            } else {
                                event.post(to: secondLocation)
                            }
                            return nil
                        }
                        if rEvent.matches(exitEvent, byIntegerFields: [.eventSourceUserData]) {
                            tap.disable()
                            completion.finish(.success(()))
                            return nil
                        }
                        if isDirectRelease, rEvent.matches(event, byIntegerFields: CGEventField.menuBarItemEventFields) {
                            progress?.received(event.type)
                            if count <= 0 {
                                completion.finish(.success(()))
                            } else {
                                entryEvent.post(to: firstLocation)
                            }
                        }
                        return rEvent
                    } ?? rEvent
                }

                // Listen for the real event at the second location and
                // perform the following actions:
                //
                // - If count <= 0: Disable the tap and post the exit event.
                // - Otherwise: Repost the entry event to start another pass.
                let eventTap2 = EventTap(
                    label: "EventTap 2",
                    type: event.type,
                    location: secondLocation,
                    placement: .tailAppendEventTap,
                    option: .listenOnly
                ) { tap, rEvent in
                    return completion.performIfPending { () -> CGEvent? in
                        guard rEvent.matches(event, byIntegerFields: CGEventField.menuBarItemEventFields) else {
                            return rEvent
                        }
                        progress?.received(event.type)
                        if count <= 0 {
                            tap.disable()
                            exitEvent.post(to: firstLocation)
                        } else {
                            entryEvent.post(to: firstLocation)
                        }
                        return rEvent
                    } ?? rEvent
                }

                completion.install(continuation) {
                    eventTap1.enable()
                    eventTap2.enable()
                    entryEvent.post(to: firstLocation)
                } cleanup: {
                    eventTap1.disable()
                    eventTap2.disable()
                }
            }
        } onCancel: {
            completion.finish(.failure(CancellationError()))
        }
    }

    /// Casts forbidden magic to make a menu bar item receive and
    /// respond to an event during a move operation.
    ///
    /// - Parameters:
    ///   - event: The event to post.
    ///   - item: The menu bar item that the event targets.
    ///   - timeout: The base duration to wait before throwing an error.
    ///     The value of this parameter is multiplied by `count` to
    ///     produce the actual timeout duration.
    ///   - count: The number of times to repeat the operation. As it
    ///     is considerably more efficient, prefer increasing this value
    ///     over repeatedly calling `scrombleEvent`.
    private nonisolated func scrombleEvent(
        _ event: CGEvent,
        item: MenuBarItem,
        timeout: Duration,
        repeating count: Int = 1,
        inputGuard: PhysicalInputGuard? = nil,
        progress: MouseEventProgress? = nil,
        cursorScope: MouseHelpers.CursorHidingScope? = nil
    ) async throws {
        guard MenuBarEventSafety.shared.protect(event, targetPID: getEventPID(for: item)) else {
            throw EventError.cannotComplete
        }
        MouseHelpers.hideCursor()
        defer {
            MouseHelpers.showCursor()
        }

        guard
            let entryEvent = CGEvent.uniqueNullEvent(),
            let exitEvent = CGEvent.uniqueNullEvent()
        else {
            throw EventError.eventCreationFailure(item)
        }

        let firstLocation = EventTap.Location.pid(getEventPID(for: item))
        let secondLocation = EventTap.Location.sessionEventTap

        var count = count
        let completion = EventOperationCompletion()
        let operationTimeout = timeout * count
        let watchdog = Task {
            do {
                try await Task.sleep(for: operationTimeout)
                completion.finish(.failure(EventError.eventOperationTimeout(item)))
            } catch { }
        }
        defer {
            watchdog.cancel()
            completion.finish(.failure(CancellationError()))
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                // Listen for the following events at the first location and
                // perform the following actions:
                //
                // - Entry event: Decrement the count and post the real event
                //   to the second location.
                // - Exit event: Disable the tap and resume the continuation.
                // - Real event:
                //   - If count <= 0: Post the exit event.
                //   - Otherwise: Repost the entry event to start another pass.
                let eventTap1 = EventTap(
                    label: "EventTap 1",
                    types: [.null, event.type],
                    location: firstLocation,
                    placement: .headInsertEventTap,
                    option: .defaultTap
                ) { tap, rEvent in
                    return completion.performIfPending { () -> CGEvent? in
                        switch rEvent.type {
                        case .null where rEvent.matches(entryEvent, byIntegerFields: [.eventSourceUserData]):
                            guard self.prepareEventForPosting(event, inputGuard: inputGuard, progress: progress) else {
                                completion.finish(.failure(EventError.userInputActive))
                                return nil
                            }
                            count -= 1
                            if Self.requiresPIDOnlyRelease(event.type, cursorExpired: cursorScope?.hasExpired == true) {
                                event.post(to: firstLocation)
                            } else {
                                event.post(to: secondLocation)
                            }
                            return nil
                        case .null where rEvent.matches(exitEvent, byIntegerFields: [.eventSourceUserData]):
                            tap.disable()
                            completion.finish(.success(()))
                            return nil
                        case event.type where rEvent.matches(event, byIntegerFields: CGEventField.menuBarItemEventFields):
                            progress?.received(event.type)
                            if count <= 0 {
                                exitEvent.post(to: firstLocation)
                            } else {
                                entryEvent.post(to: firstLocation)
                            }
                            return rEvent
                        default:
                            return rEvent
                        }
                    } ?? rEvent
                }

                // Listen for the real event at the second location and forward
                // it back to the first location. If count <= 0, disable the tap.
                let eventTap2 = EventTap(
                    label: "EventTap 2",
                    type: event.type,
                    location: secondLocation,
                    placement: .tailAppendEventTap,
                    option: .listenOnly
                ) { tap, rEvent in
                    return completion.performIfPending { () -> CGEvent? in
                        guard rEvent.matches(event, byIntegerFields: CGEventField.menuBarItemEventFields) else {
                            return rEvent
                        }
                        if let inputGuard, !inputGuard.inputUnchanged,
                           event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
                            completion.finish(.failure(EventError.userInputActive))
                            return rEvent
                        }
                        if count <= 0 {
                            tap.disable()
                        }
                        event.post(to: firstLocation)
                        return rEvent
                    } ?? rEvent
                }

                completion.install(continuation) {
                    eventTap1.enable()
                    eventTap2.enable()
                    entryEvent.post(to: firstLocation)
                } cleanup: {
                    eventTap1.disable()
                    eventTap2.disable()
                }
            }
        } onCancel: {
            completion.finish(.failure(CancellationError()))
        }
    }
}

// MARK: - Moving Items

extension MenuBarItemManager {
    /// Destinations for menu bar item move operations.
    enum MoveDestination {
        /// The destination to the left of the given target item.
        case leftOfItem(MenuBarItem)
        /// The destination to the right of the given target item.
        case rightOfItem(MenuBarItem)

        /// The destination's target item.
        var targetItem: MenuBarItem {
            switch self {
            case .leftOfItem(let item), .rightOfItem(let item): item
            }
        }

        /// A string to use for logging purposes.
        var logString: String {
            switch self {
            case .leftOfItem(let item): "left of \(item.logString)"
            case .rightOfItem(let item): "right of \(item.logString)"
            }
        }
    }

    /// Returns the default timeout for move operations associated
    /// with the given item.
    private func getDefaultMoveOperationTimeout(for item: MenuBarItem) -> Duration {
        if item.isBentoBox {
            // Bento Boxes (i.e. Control Center groups) generally
            // take a little longer to respond.
            return .milliseconds(100)
        }
        return .milliseconds(50)
    }

    /// Returns the cached timeout for move operations associated
    /// with the given item.
    private func getMoveOperationTimeout(for item: MenuBarItem) -> Duration {
        if let timeout = moveOperationTimeouts[item.tag] {
            return timeout
        }
        return getDefaultMoveOperationTimeout(for: item)
    }

    /// Updates the cached timeout for move operations associated
    /// with the given item.
    private func updateMoveOperationTimeout(_ timeout: Duration, for item: MenuBarItem) {
        let current = getMoveOperationTimeout(for: item)
        let average = (timeout + current) / 2
        let clamped = average.clamped(min: .milliseconds(25), max: .milliseconds(150))
        moveOperationTimeouts[item.tag] = clamped
    }

    /// Returns the target points for creating the events needed to
    /// move a menu bar item to the given destination.
    private nonisolated func getTargetPoints(
        forMoving item: MenuBarItem,
        to destination: MoveDestination
    ) async throws -> (start: CGPoint, end: CGPoint) {
        let itemBounds = try await getCurrentBounds(for: item)
        let targetBounds = try await getCurrentBounds(for: destination.targetItem)
        let displayMinX = NSScreen.screenWithActiveMenuBar.map { CGDisplayBounds($0.displayID).minX } ?? 0
        // A parked target must not use the top Hot Corner as its vertical
        // coordinate. Preserve horizontal placement; do not clamp to Apple.
        let targetY = targetBounds.maxX <= displayMinX ? targetBounds.midY : targetBounds.minY
        switch destination {
        case .leftOfItem:
            var start = CGPoint(x: targetBounds.minX, y: targetY)
            var end = start
            if itemBounds.maxX <= targetBounds.minX {
                // Direction of movement: ->
                end.x -= itemBounds.width
            } else {
                // Direction of movement: <-
                start.x -= 1
            }
            return (start, end)
        case .rightOfItem:
            var start = CGPoint(x: targetBounds.maxX, y: targetY)
            var end = start
            if itemBounds.minX <= targetBounds.maxX {
                // Direction of movement: ->
                end.x -= itemBounds.width
            } else {
                // Direction of movement: <-
                start.x += 1
            }
            return (start, end)
        }
    }

    /// Returns a Boolean value that indicates whether the given menu bar
    /// item has the correct position, relative to the given destination.
    private nonisolated func itemHasCorrectPosition(
        item: MenuBarItem,
        for destination: MoveDestination
    ) async throws -> Bool {
        let itemBounds = try await getCurrentBounds(for: item)
        let targetBounds = try await getCurrentBounds(for: destination.targetItem)
        return switch destination {
        case .leftOfItem: itemBounds.maxX == targetBounds.minX
        case .rightOfItem: itemBounds.minX == targetBounds.maxX
        }
    }

    /// Waits for a menu bar item to respond to a series of previously
    /// posted move events.
    ///
    /// - Parameters:
    ///   - item: The item to check for a response.
    ///   - initialOrigin: The origin of the item before the events were posted.
    ///   - timeout: The duration to wait before throwing an error.
    private nonisolated func waitForMoveEventResponse(
        from item: MenuBarItem,
        initialOrigin: CGPoint,
        timeout: Duration
    ) async throws -> CGPoint {
        MouseHelpers.hideCursor()
        defer {
            MouseHelpers.showCursor()
        }
        let responseTask = Task.detached {
            while true {
                try Task.checkCancellation()
                let origin = try await self.getCurrentBounds(for: item).origin
                if origin != initialOrigin {
                    return origin
                }
                // Yield between WindowServer queries while waiting for movement.
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        let timeoutTask = Task(timeout: timeout) {
            try await withTaskCancellationHandler {
                try await responseTask.value
            } onCancel: {
                responseTask.cancel()
            }
        }
        do {
            let origin = try await withTaskCancellationHandler {
                try await timeoutTask.value
            } onCancel: { timeoutTask.cancel() }
            logger.debug(
                """
                Item responded to events with new origin: \
                \(String(describing: origin), privacy: .public)
                """
            )
            return origin
        } catch let error as EventError {
            throw error
        } catch is TaskTimeoutError {
            throw EventError.itemResponseTimeout(item)
        } catch {
            throw EventError.cannotComplete
        }
    }

    /// Creates and posts a series of events to move a menu bar item
    /// to the given destination.
    ///
    /// - Parameters:
    ///   - item: The menu bar item to move.
    ///   - destination: The destination to move the menu bar item.
    private func postMoveEvents(item: MenuBarItem, destination: MoveDestination, inputQuietPeriod: Duration, cursorScope: MouseHelpers.CursorHidingScope?) async throws {
        try await eventSemaphore.waitUnlessCancelled()
        defer {
            eventSemaphore.signal()
        }
        guard !isShuttingDown else { throw CancellationError() }

        let inputGuard = PhysicalInputGuard(quietPeriod: inputQuietPeriod, cursorScope: cursorScope)
        let initialBounds = try await getCurrentBounds(for: item)
        let targetBounds = try await getCurrentBounds(for: destination.targetItem)
        var itemOrigin = initialBounds.origin
        let targetPoints = try await getTargetPoints(forMoving: item, to: destination)
        let source = try getEventSource()

        permitLocalEvents(for: source)
        guard inputGuard.canStart else { throw EventError.userInputActive }
        let progress = MouseEventProgress()
        let fallbackPoint = Self.visibleReleasePoint(
            itemBounds: initialBounds,
            targetBounds: targetBounds,
            displays: NSScreen.screens.map { CGDisplayBounds($0.displayID) }
        )

        guard
            let mouseDown = CGEvent.menuBarItemEvent(
                item: item,
                source: source,
                type: .move(.mouseDown),
                location: targetPoints.start
            ),
            let mouseUp = CGEvent.menuBarItemEvent(
                item: destination.targetItem,
                source: source,
                type: .move(.mouseUp),
                location: targetPoints.end
            )
        else {
            throw EventError.eventCreationFailure(item)
        }

        var timeout = getMoveOperationTimeout(for: item)
        logger.debug("Move operation timeout: \(timeout)")

        lastMoveOperationTimestamp = .now
        MouseHelpers.hideCursor()
        defer {
            MouseHelpers.showCursor()
            lastMoveOperationTimestamp = .now
            updateMoveOperationTimeout(timeout, for: item)
        }

        do {
            try await scrombleEvent(
                mouseDown,
                item: item,
                timeout: timeout,
                inputGuard: inputGuard,
                progress: progress,
                cursorScope: cursorScope
            )
            guard inputGuard.inputUnchanged else { throw EventError.userInputActive }
            itemOrigin = try await waitForMoveEventResponse(
                from: item,
                initialOrigin: itemOrigin,
                timeout: timeout
            )
            guard inputGuard.inputUnchanged else { throw EventError.userInputActive }
            try await scrombleEvent(
                mouseUp,
                item: item,
                timeout: timeout,
                repeating: 2, // Double mouse up prevents invalid item state.
                progress: progress,
                cursorScope: cursorScope
            )
            // Some extras reach their final position on mouse-down. Once both
            // releases have completed, do not wait for a second origin change
            // that will never occur while keeping the pointer hidden.
            if try await !itemHasCorrectPosition(item: item, for: destination) {
                do {
                    itemOrigin = try await waitForMoveEventResponse(
                        from: item,
                        initialOrigin: itemOrigin,
                        timeout: timeout
                    )
                } catch {
                    guard try await itemHasCorrectPosition(item: item, for: destination) else { throw error }
                }
                guard try await itemHasCorrectPosition(item: item, for: destination) else {
                    throw EventError.itemResponseTimeout(item)
                }
            }
            timeout -= timeout / 4
        } catch {
            await releaseInterruptedMouseOperation(
                item: item, source: source, type: .move(.mouseUp),
                fallbackPoint: fallbackPoint, progress: progress, cursorScope: cursorScope, isMove: true
            )
            if Task.isCancelled || isShuttingDown { throw CancellationError() }
            timeout += timeout / 2
            throw error
        }
    }

    /// Moves a menu bar item to the given destination.
    ///
    /// - Parameters:
    ///   - item: The menu bar item to move.
    ///   - destination: The destination to move the item to.
    func move(
        item: MenuBarItem,
        to destination: MoveDestination,
        waitForInput: Bool = true,
        maxAttempts: Int = 8,
        cursorScope: MouseHelpers.CursorHidingScope? = nil,
        inputQuietPeriod: Duration = .milliseconds(50)
    ) async throws {
        guard !isShuttingDown, !Task.isCancelled else { throw CancellationError() }
        guard item.isMovable else {
            throw EventError.itemNotMovable(item)
        }
        guard let appState else {
            throw EventError.cannotComplete
        }

        if waitForInput { try await waitForUserToPauseInput() }
        try await waitForMoveOperationBuffer()

        logger.log(
            """
            Moving \(item.logString, privacy: .public) to \
            \(destination.logString, privacy: .public)
            """
        )

        guard try await !itemHasCorrectPosition(item: item, for: destination) else {
            logger.debug("Item has correct position, cancelling move")
            return
        }

        appState.eventManager.stopAll()
        MouseHelpers.hideCursor()
        defer {
            MouseHelpers.showCursor()
            if !isShuttingDown { appState.eventManager.startAll() }
        }

        for n in 1...maxAttempts {
            guard !Task.isCancelled, cursorScope?.hasExpired != true else {
                throw EventError.cannotComplete
            }
            do {
                if try await itemHasCorrectPosition(item: item, for: destination) {
                    logger.debug("Item has correct position, finished with move")
                    return
                }
                try await postMoveEvents(item: item, destination: destination, inputQuietPeriod: inputQuietPeriod, cursorScope: cursorScope)
                logger.debug("Attempt \(n, privacy: .public) succeeded, finished with move")
                return
            } catch {
                logger.debug("Attempt \(n, privacy: .public) failed: \(error, privacy: .public)")
                if case EventError.userInputActive = error { throw error }
                if n < maxAttempts {
                    try await waitForMoveOperationBuffer()
                    continue
                }
                if error is EventError {
                    throw error
                }
                throw EventError.cannotComplete
            }
        }
    }
}

// MARK: - Clicking Items

extension MenuBarItemManager {
    /// Returns the equivalent event subtypes for clicking a menu bar
    /// item with the given mouse button.
    private nonisolated func getClickSubtypes(
        for mouseButton: CGMouseButton
    ) -> (down: MenuBarItemEventType.ClickSubtype, up: MenuBarItemEventType.ClickSubtype) {
        switch mouseButton {
        case .left: (.leftMouseDown, .leftMouseUp)
        case .right: (.rightMouseDown, .rightMouseUp)
        default: (.otherMouseDown, .otherMouseUp)
        }
    }

    /// Creates and posts a series of events to click a menu bar item.
    ///
    /// - Parameters:
    ///   - item: The menu bar item to click.
    ///   - mouseButton: The mouse button to click the item with.
    private func postClickEvents(item: MenuBarItem, mouseButton: CGMouseButton, cursorScope: MouseHelpers.CursorHidingScope?) async throws {
        try await eventSemaphore.waitUnlessCancelled()
        defer {
            eventSemaphore.signal()
        }
        guard !isShuttingDown else { throw CancellationError() }

        let inputGuard = PhysicalInputGuard(quietPeriod: .milliseconds(50), cursorScope: cursorScope)
        let itemBounds = try await getCurrentBounds(for: item)
        let clickPoint = itemBounds.center
        let source = try getEventSource()

        permitLocalEvents(for: source)
        guard inputGuard.canStart else { throw EventError.userInputActive }
        let progress = MouseEventProgress()
        let fallbackPoint = Self.visibleReleasePoint(
            itemBounds: itemBounds, targetBounds: itemBounds,
            displays: NSScreen.screens.map { CGDisplayBounds($0.displayID) }
        )

        let clickTypes = getClickSubtypes(for: mouseButton)
        let timeout = Duration.milliseconds(250)

        guard
            let mouseDown = CGEvent.menuBarItemEvent(
                item: item,
                source: source,
                type: .click(clickTypes.down),
                location: clickPoint
            ),
            let mouseUp = CGEvent.menuBarItemEvent(
                item: item,
                source: source,
                type: .click(clickTypes.up),
                location: clickPoint
            )
        else {
            throw EventError.eventCreationFailure(item)
        }

        MouseHelpers.hideCursor()
        defer {
            MouseHelpers.showCursor()
        }

        do {
            try await postEventWithBarrier(
                mouseDown,
                to: item,
                timeout: timeout,
                inputGuard: inputGuard,
                progress: progress,
                cursorScope: cursorScope
            )
            try await postEventWithBarrier(
                mouseUp,
                to: item,
                timeout: timeout,
                repeating: 2, // Double mouse up prevents invalid item state.
                progress: progress,
                cursorScope: cursorScope
            )
        } catch {
            await releaseInterruptedMouseOperation(
                item: item, source: source, type: .click(clickTypes.up),
                fallbackPoint: fallbackPoint, progress: progress, cursorScope: cursorScope, isMove: false
            )
            if Task.isCancelled || isShuttingDown { throw CancellationError() }
            throw error
        }
    }

    /// Clicks a menu bar item with the given mouse button.
    ///
    /// - Parameters:
    ///   - item: The menu bar item to click.
    ///   - mouseButton: The mouse button to click the item with.
    func click(
        item: MenuBarItem,
        with mouseButton: CGMouseButton,
        waitForInput: Bool = true,
        maxAttempts: Int = 4,
        cursorScope: MouseHelpers.CursorHidingScope? = nil
    ) async throws {
        guard !isShuttingDown, !Task.isCancelled else { throw CancellationError() }
        guard let appState else {
            throw EventError.cannotComplete
        }

        if waitForInput { try await waitForUserToPauseInput() }

        logger.log(
            """
            Clicking \(item.logString, privacy: .public) with \
            \(mouseButton.logString, privacy: .public)
            """
        )

        appState.eventManager.stopAll()
        defer {
            if !isShuttingDown { appState.eventManager.startAll() }
        }

        if mouseButton == .left {
            switch await MenuBarItemAXActivator.activate(item: item) {
            case .activated:
                logger.notice("Activated \(item.logString, privacy: .public) using native accessibility action; no synthetic click")
                return
            case .uncertain:
                // A modal menu may have opened while the accessibility action timed out. Do not
                // turn it back off with a second, synthetic activation.
                logger.warning("Native accessibility action result uncertain for \(item.logString, privacy: .public); skipped duplicate click")
                return
            case .unavailable:
                logger.notice("Native accessibility action unavailable for \(item.logString, privacy: .public); using protected synthetic click")
                break
            }
        }

        let fallbackScope = cursorScope ?? MouseHelpers.beginCursorHiding()
        defer { if cursorScope == nil { fallbackScope.finish() } }
        for n in 1...maxAttempts {
            guard !Task.isCancelled, !fallbackScope.hasExpired else {
                throw EventError.cannotComplete
            }
            do {
                try await postClickEvents(item: item, mouseButton: mouseButton, cursorScope: fallbackScope)
                logger.debug("Attempt \(n, privacy: .public) succeeded, finished with click")
                return
            } catch {
                logger.debug("Attempt \(n, privacy: .public) failed: \(error, privacy: .public)")
                if case EventError.userInputActive = error { throw error }
                if n < maxAttempts {
                    await eventSleep()
                    continue
                }
                if error is EventError {
                    throw error
                }
                throw EventError.cannotComplete
            }
        }
    }
}

// MARK: - Temporarily Showing Items

extension MenuBarItemManager {
    /// The original placement remains stable across repeated clicks while the
    /// menu's current window set and anchor are refreshed on each activation.
    private final class TemporarilyShownItemContext {
        let tag: MenuBarItemTag
        let returnDestination: MoveDestination
        var sourcePID: pid_t?
        var itemWindowID: CGWindowID
        var anchorBounds: CGRect
        var displayBounds: CGRect
        var interfaceWindows = [WindowInfo]()
        var rehideAttempts = 0

        init(item: MenuBarItem, returnDestination: MoveDestination, displayBounds: CGRect) {
            tag = item.tag
            self.returnDestination = returnDestination
            sourcePID = item.sourcePID
            itemWindowID = item.windowID
            anchorBounds = item.bounds
            self.displayBounds = displayBounds
        }
    }

    /// Menu surfaces must belong to the source process and be attached to the
    /// clicked item (or a previously observed parent menu). Status items and
    /// regular application windows cannot keep a temporary item alive forever.
    private nonisolated static func menuInterfaceWindows(
        in windows: [WindowInfo],
        sourcePID: pid_t?,
        excluding excludedIDs: Set<CGWindowID>,
        anchor: CGRect,
        displayBounds: CGRect,
        previouslySeen: [WindowInfo]
    ) -> [WindowInfo] {
        guard let sourcePID, sourcePID != ProcessInfo.processInfo.processIdentifier else { return [] }
        let surfaces = windows.filter { window in
            window.ownerPID == sourcePID && window.isOnScreen &&
            !window.isWindowServerWindow && !excludedIDs.contains(window.windowID) &&
            window.layer > CGWindowLevelForKey(.normalWindow) &&
            window.layer < CGWindowLevelForKey(.cursorWindow) &&
            window.bounds.width >= 20 && window.bounds.height >= 20 &&
            window.bounds.width.isFinite && window.bounds.height.isFinite &&
            displayBounds.intersects(window.bounds)
        }
        func attachedToAnchor(_ bounds: CGRect) -> Bool {
            bounds.minY >= anchor.minY - 8 && bounds.minY <= anchor.maxY + 96 &&
            bounds.maxY > anchor.maxY &&
            bounds.minX - 48 <= anchor.midX && bounds.maxX + 48 >= anchor.midX
        }
        func adjacent(_ bounds: CGRect, to parent: CGRect) -> Bool {
            let horizontalGap = min(abs(parent.minX - bounds.maxX), abs(bounds.minX - parent.maxX))
            return horizontalGap <= 24 && bounds.maxY >= parent.minY && bounds.minY <= parent.maxY
        }
        var matched = surfaces.filter { window in
            attachedToAnchor(window.bounds) || previouslySeen.contains { previous in
                // Reused IDs are not enough: owner, layer and geometry must
                // still describe the same menu or its adjacent submenu.
                previous.ownerPID == window.ownerPID && previous.layer == window.layer &&
                (previous.bounds == window.bounds || adjacent(window.bounds, to: previous.bounds))
            }
        }
        for window in surfaces where !matched.contains(where: { $0.windowID == window.windowID }) {
            if matched.contains(where: { $0.layer == window.layer && adjacent(window.bounds, to: $0.bounds) }) {
                matched.append(window)
            }
        }
        return matched
    }

    private func refreshInterfaceWindows(for context: TemporarilyShownItemContext) -> Bool {
        if let bounds = Bridging.getWindowBounds(for: context.itemWindowID) {
            context.anchorBounds = bounds
        }
        var excludedIDs = Set(Bridging.getMenuBarWindowList(option: .itemsOnly))
        excludedIDs.insert(context.itemWindowID)
        let current = Self.menuInterfaceWindows(
            in: WindowInfo.createWindows(option: .onScreen),
            sourcePID: context.sourcePID,
            excluding: excludedIDs,
            anchor: context.anchorBounds,
            displayBounds: context.displayBounds,
            previouslySeen: context.interfaceWindows
        )
        // Keep the last geometry during a brief parent-to-submenu transition;
        // every reuse is still revalidated against the current window list.
        if !current.isEmpty { context.interfaceWindows = current }
        return !current.isEmpty
    }

    /// Gets the destination to return the given item to after it is
    /// temporarily shown.
    private func getReturnDestination(for item: MenuBarItem, in items: [MenuBarItem]) -> MoveDestination? {
        guard let index = items.firstIndex(matching: item.tag) else {
            return nil
        }
        if items.indices.contains(index + 1) {
            return .leftOfItem(items[index + 1])
        }
        if items.indices.contains(index - 1) {
            return .rightOfItem(items[index - 1])
        }
        return nil
    }

    private func invalidateRehideTimer() {
        rehideGeneration &+= 1
        rehideTimer?.invalidate()
        rehideTimer = nil
    }

    /// Timer callbacks carry a generation so an already queued old callback
    /// cannot undo a newer activation after acquiring the interaction lock.
    private func runRehideTimer(for interval: TimeInterval? = nil) {
        invalidateRehideTimer()
        guard !isShuttingDown, !temporarilyShownItemContexts.isEmpty, let appState else { return }
        let interval = interval ?? appState.settings.advanced.tempShowInterval
        let generation = rehideGeneration
        rehideTimer = .scheduledTimer(withTimeInterval: max(0.1, interval), repeats: false) { [weak self] _ in
            Task { await self?.rehideTemporarilyShownItems(generation: generation) }
        }
    }

    /// Compatibility entry point for the search panel. Bar activations always
    /// enter here even when the item is already temporarily visible.
    func temporarilyShow(item: MenuBarItem, clickingWith mouseButton: CGMouseButton) async {
        await activateFromBar(item: item, with: mouseButton)
    }

    /// The bar can outlive a status window while its owner updates or
    /// recreates the item. A unique stable tag can rebind that same logical
    /// item; an unknown source or multiple matching extras cannot.
    static func resolvedActivationItem(_ requested: MenuBarItem, in items: [MenuBarItem]) -> MenuBarItem? {
        if let exact = items.first(where: { $0.windowID == requested.windowID }),
           exact.ownerPID == requested.ownerPID,
           (exact.sourcePID == requested.sourcePID && exact.tag == requested.tag) ||
            (requested.sourcePID == nil && exact.title == requested.title) {
            return exact
        }
        guard case .string(let bundleID) = requested.tag.namespace else { return nil }
        let candidates = items.filter { candidate in
            candidate.tag == requested.tag && candidate.sourcePID != nil &&
                (candidate.sourcePID == requested.sourcePID ||
                    candidate.sourceApplication?.bundleIdentifier == bundleID)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    func activateFromBar(item: MenuBarItem, with mouseButton: CGMouseButton) async {
        guard !isShuttingDown, activeBarItemTag != item.tag else { return }
        interactionGeneration &+= 1
        let request = interactionGeneration
        invalidateRehideTimer()
        do {
            try await interactionSemaphore.waitUnlessCancelled()
        } catch {
            if request == interactionGeneration { runRehideTimer() }
            return
        }
        defer { interactionSemaphore.signal() }
        guard !isShuttingDown, request == interactionGeneration, !Task.isCancelled else { return }
        isHandlingInteraction = true
        activeBarItemTag = item.tag
        defer {
            activeBarItemTag = nil
            isHandlingInteraction = false
            if request == interactionGeneration { runRehideTimer() }
        }

        do {
            // No cursor hide is held while waiting for the user to stop input.
            try await waitForUserToPauseInput(timeout: .seconds(1))
            guard !isShuttingDown, request == interactionGeneration else { return }
            let items = await MenuBarItem.getMenuBarItems(option: .activeSpace)
            guard !isShuttingDown, request == interactionGeneration, !Task.isCancelled else { return }
            guard let liveItem = Self.resolvedActivationItem(item, in: items) else {
                logger.warning("No unambiguous live status item for \(item.logString, privacy: .public); activation skipped")
                return
            }
            if liveItem.windowID != item.windowID {
                logger.notice("Rebound recreated status item \(item.logString, privacy: .public) to windowID \(liveItem.windowID, privacy: .public)")
            }
            let item = liveItem
            let needsMove = !Bridging.isWindowOnScreen(item.windowID)

            var context = temporarilyShownItemContexts.first { $0.tag == item.tag }
            var targetItem: MenuBarItem?

            if needsMove {
                guard let screen = NSScreen.screenWithActiveMenuBar,
                      let applicationMenuFrame = screen.getApplicationMenuFrame() else { return }
                let displayBounds = CGDisplayBounds(screen.displayID)
                var leftLimit = max(displayBounds.minX, applicationMenuFrame.maxX)
                if let notch = screen.frameOfNotch { leftLimit = max(leftLimit, notch.maxX + 30) }
                guard let target = temporaryShowTarget(for: item, in: items, displayBounds: displayBounds, leftLimit: leftLimit) else {
                    logger.warning("No temporary placement for \(item.logString, privacy: .public)")
                    let alert = NSAlert()
                    alert.messageText = "菜单栏暂时放不下这个图标"
                    alert.informativeText = "请切换到菜单较少的应用后，再打开“\(item.displayName)”。"
                    alert.addButton(withTitle: "好")
                    alert.runModal()
                    return
                }
                targetItem = target
                if context == nil {
                    guard let destination = getReturnDestination(for: item, in: items) else { return }
                    let newContext = TemporarilyShownItemContext(item: item, returnDestination: destination, displayBounds: displayBounds)
                    temporarilyShownItemContexts.append(newContext)
                    context = newContext
                }
            }
            if let context {
                context.sourcePID = item.sourcePID
                context.itemWindowID = item.windowID
                context.rehideAttempts = 0
            }

            // End synthetic movement and restore the pointer before asking the
            // owner to open its interface. Accessibility activation needs no cursor hide/warp;
            // switching apps while holding a hide can otherwise reveal it at
            // the synthetic event position in the newly activated process.
            let target = targetItem
            let handoff = Task {
                guard !self.isShuttingDown, !Task.isCancelled else { throw CancellationError() }
                if let target {
                    do {
                        let cursorScope = MouseHelpers.beginCursorHiding()
                        defer { cursorScope.finish() }
                        try await self.move(item: item, to: .leftOfItem(target), waitForInput: false, maxAttempts: 2, cursorScope: cursorScope)
                        guard !cursorScope.hasExpired else { throw CancellationError() }
                    }
                    // The owner may need a layout turn; waiting for it must not
                    // keep the real pointer invisible for another 100 ms.
                    try await Task.sleep(for: .milliseconds(100))
                }
                try Task.checkCancellation()
                guard !self.isShuttingDown else { throw CancellationError() }
                // Never wait invisibly for continued user input. Let the next
                // deliberate click retry if input resumed during movement.
                guard self.hasUserPausedInput(for: .milliseconds(50)) else { throw EventError.cannotComplete }
                try await self.click(item: item, with: mouseButton, waitForInput: false, maxAttempts: 1)
            }
            activeHandoffTask = handoff
            let watchdog = Task {
                do {
                    try await Task.sleep(for: .milliseconds(1100))
                    handoff.cancel()
                } catch { }
            }
            defer { watchdog.cancel(); activeHandoffTask = nil }
            try await withTaskCancellationHandler {
                try await handoff.value
            } onCancel: { handoff.cancel() }

            // Cursor is already restored. Polling also catches reused window
            // IDs and delayed popovers; restoration scans again much later.
            if let context {
                let observationDeadline = ContinuousClock.now.advanced(by: .milliseconds(1200))
                repeat {
                    guard !isShuttingDown, request == interactionGeneration else { break }
                    if refreshInterfaceWindows(for: context) { break }
                    try await Task.sleep(for: .milliseconds(100))
                } while ContinuousClock.now < observationDeadline
            }
        } catch {
            logger.error("Menu bar activation did not complete: \(error, privacy: .public)")
        }
    }

    /// Only the clicked item moves. A protected or fixed item is still a valid
    /// insertion anchor, including Shiyi's own status item and Control Center.
    private func temporaryShowTarget(for item: MenuBarItem, in items: [MenuBarItem], displayBounds: CGRect, leftLimit: CGFloat) -> MenuBarItem? {
        guard item.bounds.width.isFinite, item.bounds.width > 0, leftLimit.isFinite else { return nil }
        return items.filter { candidate in
            candidate.windowID != item.windowID &&
            candidate.isOnScreen && !candidate.isControlItem && !candidate.isSystemClone &&
            !candidate.bounds.isEmpty && !candidate.bounds.isInfinite &&
            displayBounds.contains(candidate.bounds) &&
            candidate.bounds.minX - item.bounds.width >= leftLimit
        }.min { $0.bounds.minX < $1.bounds.minX }
    }

    /// Rechecks the menu after taking the same lock as activation. Each timer
    /// firing makes at most one move attempt per item, then backs off on failure.
    private func rehideTemporarilyShownItems(generation: Int) async {
        guard !isShuttingDown, generation == rehideGeneration else { return }
        do { try await interactionSemaphore.waitUnlessCancelled() } catch { return }
        defer { interactionSemaphore.signal() }
        guard !isShuttingDown, generation == rehideGeneration, !Task.isCancelled else { return }
        isHandlingInteraction = true
        var retryInterval: TimeInterval = 3
        defer {
            isHandlingInteraction = false
            if generation == rehideGeneration { runRehideTimer(for: retryInterval) }
        }
        let quietPeriod = Duration.milliseconds(750)
        guard hasUserPausedInput(for: quietPeriod) else { retryInterval = 1; return }
        for context in temporarilyShownItemContexts.reversed() {
            guard !isShuttingDown, generation == rehideGeneration, !Task.isCancelled else { return }
            if refreshInterfaceWindows(for: context) { continue }
            // Parent menus can briefly disappear while a submenu replaces them.
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard !isShuttingDown, generation == rehideGeneration else { return }
            if refreshInterfaceWindows(for: context) { continue }
            guard hasUserPausedInput(for: quietPeriod) else { retryInterval = 1; return }
            let restoreInputGeneration = MouseHelpers.inputGeneration
            let items = await MenuBarItem.getMenuBarItems(option: .activeSpace)
            guard let item = items.first(matching: context.tag) else {
                temporarilyShownItemContexts.removeAll { $0 === context }
                continue
            }
            guard !isShuttingDown, generation == rehideGeneration,
                  temporarilyShownItemContexts.contains(where: { $0 === context }) else { return }
            guard restoreInputGeneration == MouseHelpers.inputGeneration,
                  hasUserPausedInput(for: quietPeriod) else { retryInterval = 1; return }
            // Refresh once more immediately before the actual move.
            if refreshInterfaceWindows(for: context) { continue }
            let restoreTask = Task {
                guard !self.isShuttingDown, !Task.isCancelled else { throw CancellationError() }
                guard restoreInputGeneration == MouseHelpers.inputGeneration,
                      self.hasUserPausedInput(for: quietPeriod) else { throw EventError.userInputActive }
                let cursorScope = MouseHelpers.beginCursorHiding()
                defer { cursorScope.finish() }
                try await self.move(item: item, to: context.returnDestination, waitForInput: false, maxAttempts: 1, cursorScope: cursorScope, inputQuietPeriod: quietPeriod)
            }
            activeHandoffTask = restoreTask
            let watchdog = Task {
                do { try await Task.sleep(for: .milliseconds(1100)); restoreTask.cancel() } catch { }
            }
            do {
                try await withTaskCancellationHandler {
                    try await restoreTask.value
                } onCancel: { restoreTask.cancel() }
                temporarilyShownItemContexts.removeAll { $0 === context }
            } catch {
                if case EventError.userInputActive = error {
                    retryInterval = 1
                } else {
                    context.rehideAttempts += 1
                    retryInterval = max(retryInterval, min(30, Double(context.rehideAttempts) * 5))
                }
                logger.warning("Deferred restoring \(item.logString, privacy: .public): \(error, privacy: .public)")
            }
            watchdog.cancel()
            activeHandoffTask = nil
        }
    }

    /// Removes a temporarily shown item from the cache, ensuring that
    /// the item is _not_ returned to its original location.
    func removeTemporarilyShownItemFromCache(with tag: MenuBarItemTag) {
        while let index = temporarilyShownItemContexts.firstIndex(where: { $0.tag == tag }) {
            logger.debug(
                """
                Removing temporarily shown item from cache: \
                \(tag, privacy: .public)
                """
            )
            temporarilyShownItemContexts.remove(at: index)
        }
    }
}

// MARK: - Control Item Order

extension MenuBarItemManager {
    /// Enforces the order of the given control items, ensuring that the
    /// control item for the always-hidden section is positioned to the
    /// left of control item for the hidden section.
    private func enforceControlItemOrder(controlItems: ControlItemPair) async {
        let hidden = controlItems.hidden

        guard
            let alwaysHidden = controlItems.alwaysHidden,
            hidden.bounds.maxX <= alwaysHidden.bounds.minX
        else {
            return
        }

        do {
            logger.debug("Control items have incorrect order")
            try await move(item: alwaysHidden, to: .leftOfItem(hidden))
        } catch {
            logger.error("Error enforcing control item order: \(error, privacy: .public)")
        }
    }
}

// MARK: - MenuBarItemEventType

/// Event types for menu bar item events.
private enum MenuBarItemEventType {
    /// The event type for moving a menu bar item.
    case move(MoveSubtype)
    /// The event type for clicking a menu bar item.
    case click(ClickSubtype)

    var cgEventType: CGEventType {
        switch self {
        case .move(let subtype): subtype.cgEventType
        case .click(let subtype): subtype.cgEventType
        }
    }

    var cgEventFlags: CGEventFlags {
        switch self {
        case .move(.mouseDown): .maskCommand
        case .move, .click: []
        }
    }

    var cgMouseButton: CGMouseButton {
        switch self {
        case .move: .left
        case .click(let subtype): subtype.cgMouseButton
        }
    }

    // MARK: Subtypes

    /// Subtype for menu bar item move events.
    enum MoveSubtype {
        case mouseDown
        case mouseUp

        var cgEventType: CGEventType {
            switch self {
            case .mouseDown: .leftMouseDown
            case .mouseUp: .leftMouseUp
            }
        }
    }

    /// Subtype for menu bar item click events.
    enum ClickSubtype {
        case leftMouseDown
        case leftMouseUp
        case rightMouseDown
        case rightMouseUp
        case otherMouseDown
        case otherMouseUp

        var cgEventType: CGEventType {
            switch self {
            case .leftMouseDown: .leftMouseDown
            case .leftMouseUp: .leftMouseUp
            case .rightMouseDown: .rightMouseDown
            case .rightMouseUp: .rightMouseUp
            case .otherMouseDown: .otherMouseDown
            case .otherMouseUp: .otherMouseUp
            }
        }

        var cgMouseButton: CGMouseButton {
            switch self {
            case .leftMouseDown, .leftMouseUp: .left
            case .rightMouseDown, .rightMouseUp: .right
            case .otherMouseDown, .otherMouseUp: .center
            }
        }

        var clickState: Int64 {
            switch self {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown: 1
            case .leftMouseUp, .rightMouseUp, .otherMouseUp: 0
            }
        }
    }
}

// MARK: - CGEventField Helpers

private extension CGEventField {
    /// Key to access a field that contains the event's window identifier.
    static let windowID = CGEventField(rawValue: 0x33)! // swiftlint:disable:this force_unwrapping

    /// Fields that can be used to compare menu bar item events.
    static let menuBarItemEventFields: [CGEventField] = [
        .eventSourceUserData,
        .mouseEventWindowUnderMousePointer,
        .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
        .windowID,
    ]
}

// MARK: - CGEventFilterMask Helpers

private extension CGEventFilterMask {
    /// Specifies that all events should be permitted during event suppression states.
    static let permitAllEvents: CGEventFilterMask = [
        .permitLocalMouseEvents,
        .permitLocalKeyboardEvents,
        .permitSystemDefinedEvents,
    ]
}

// MARK: - CGEventType Helpers

private extension CGEventType {
    /// A string to use for logging purposes.
    var logString: String {
        switch self {
        case .null: "null event"
        case .leftMouseDown: "leftMouseDown event"
        case .leftMouseUp: "leftMouseUp event"
        case .rightMouseDown: "rightMouseDown event"
        case .rightMouseUp: "rightMouseUp event"
        case .mouseMoved: "mouseMoved event"
        case .leftMouseDragged: "leftMouseDragged event"
        case .rightMouseDragged: "rightMouseDragged event"
        case .keyDown: "keyDown event"
        case .keyUp: "keyUp event"
        case .flagsChanged: "flagsChanged event"
        case .scrollWheel: "scrollWheel event"
        case .tabletPointer: "tabletPointer event"
        case .tabletProximity: "tabletProximity event"
        case .otherMouseDown: "otherMouseDown event"
        case .otherMouseUp: "otherMouseUp event"
        case .otherMouseDragged: "otherMouseDragged event"
        case .tapDisabledByTimeout: "tapDisabledByTimeout event"
        case .tapDisabledByUserInput: "tapDisabledByUserInput event"
        @unknown default: "unknown event"
        }
    }
}

// MARK: - CGMouseButton Helpers

private extension CGMouseButton {
    /// A string to use for logging purposes.
    var logString: String {
        switch self {
        case .left: "left mouse button"
        case .right: "right mouse button"
        case .center: "center mouse button"
        @unknown default: "unknown mouse button"
        }
    }
}

// MARK: - CGEvent Helpers

private extension CGEvent {
    /// Returns an event that can be sent to a menu bar item.
    ///
    /// - Parameters:
    ///   - item: The event's target item.
    ///   - source: The event's source.
    ///   - type: The event's specialized type.
    ///   - location: The event's location. Does not need to be
    ///     within the bounds of the item.
    static func menuBarItemEvent(
        item: MenuBarItem,
        source: CGEventSource,
        type: MenuBarItemEventType,
        location: CGPoint
    ) -> CGEvent? {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type.cgEventType,
            mouseCursorPosition: location,
            mouseButton: type.cgMouseButton
        ) else {
            return nil
        }
        event.setFlags(for: type)
        event.setIntegerValueField(.eventSourceUserData, value: MenuBarEventSafety.shared.nextIdentifier())
        event.setWindowID(item.windowID, for: type)
        event.setClickState(for: type)
        return event
    }

    /// Returns a null event with unique user data.
    static func uniqueNullEvent() -> CGEvent? {
        guard let event = CGEvent(source: nil) else {
            return nil
        }
        event.setIntegerValueField(.eventSourceUserData, value: MenuBarEventSafety.shared.nextIdentifier())
        return event
    }

    /// Posts the event to the given event tap location.
    ///
    /// - Parameter location: The event tap location to post the event to.
    func post(to location: EventTap.Location) {
        let type = self.type
        Logger.menuBarItemManager.debug(
            """
            Posting \(type.logString, privacy: .public) \
            to \(location.logString, privacy: .public)
            """
        )
        switch location {
        case .hidEventTap: post(tap: .cghidEventTap)
        case .sessionEventTap: post(tap: .cgSessionEventTap)
        case .annotatedSessionEventTap: post(tap: .cgAnnotatedSessionEventTap)
        case .pid(let pid): postToPid(pid)
        }
    }

    /// Returns a Boolean value that indicates whether the given integer
    /// fields from this event are equivalent to the same integer fields
    /// from the specified event.
    ///
    /// - Parameters:
    ///   - other: The event to compare with this event.
    ///   - fields: The integer fields to check.
    func matches(_ other: CGEvent, byIntegerFields fields: [CGEventField]) -> Bool {
        fields.allSatisfy { field in
            getIntegerValueField(field) == other.getIntegerValueField(field)
        }
    }

    private func setFlags(for type: MenuBarItemEventType) {
        flags = type.cgEventFlags
    }

    private func setUserData(_ bitPattern: ObjectIdentifier) {
        let userData = Int64(Int(bitPattern: bitPattern))
        setIntegerValueField(.eventSourceUserData, value: userData)
    }

    private func setWindowID(_ windowID: CGWindowID, for type: MenuBarItemEventType) {
        let windowID = Int64(windowID)

        setIntegerValueField(.mouseEventWindowUnderMousePointer, value: windowID)
        setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: windowID)

        if case .move = type {
            setIntegerValueField(.windowID, value: windowID)
        }
    }

    private func setClickState(for type: MenuBarItemEventType) {
        if case .click(let subtype) = type {
            setIntegerValueField(.mouseEventClickState, value: subtype.clickState)
        }
    }
}

// MARK: - Logger Helpers

private extension Logger {
    /// Logger for the menu bar item manager.
    static let menuBarItemManager = Logger(category: "MenuBarItemManager")
}
