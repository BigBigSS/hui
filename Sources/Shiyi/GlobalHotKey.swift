import Carbon
import Foundation

// Registration and callbacks are confined to the application main event loop.
final class GlobalHotKey: @unchecked Sendable {
    private static let hotKeySignature = fourCharCode("MCHP")
    private let hotKeyIDValue: UInt32
    private let keyCode: UInt32
    private let modifiers: UInt32

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let onPressed: () -> Void
    private let onReleased: (() -> Void)?
    private var held = false

    init(id: UInt32 = 1, keyCode: UInt32 = UInt32(kVK_ANSI_C), modifiers: UInt32 = UInt32(cmdKey | shiftKey), onReleased: (() -> Void)? = nil, onPressed: @escaping () -> Void) {
        self.hotKeyIDValue = id
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.onPressed = onPressed
        self.onReleased = onReleased
    }

    @discardableResult
    func register() -> Bool {
        unregister()

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let eventRef else { return noErr }

                var eventHotKeyID = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &eventHotKeyID
                )

                guard parameterStatus == noErr,
                      eventHotKeyID.signature == GlobalHotKey.hotKeySignature,
                      let userData,
                      eventHotKeyID.id == Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().hotKeyIDValue else {
                    return OSStatus(eventNotHandledErr)
                }

                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                let released = GetEventKind(eventRef) == UInt32(kEventHotKeyReleased)

                DispatchQueue.main.async { [weak hotKey] in
                    guard let hotKey else { return }
                    if released {
                        guard hotKey.held else { return }
                        hotKey.held = false
                        hotKey.onReleased?()
                    } else if !hotKey.held {
                        hotKey.held = true
                        hotKey.onPressed()
                    }
                }

                return noErr
            },
            2,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        guard handlerStatus == noErr else {
            NSLog("Failed to install hotkey handler: \(handlerStatus)")
            return false
        }

        let hotKeyID = EventHotKeyID(
            signature: Self.hotKeySignature,
            id: hotKeyIDValue
        )

        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard registerStatus == noErr else {
            NSLog("Failed to register hotkey: \(registerStatus)")
            unregister()
            return false
        }

        return true
    }

    func unregister() {
        held = false
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }

    }

    deinit {
        unregister()
    }

    private static func fourCharCode(_ value: String) -> OSType {
        value.utf8.reduce(0) { result, character in
            (result << 8) + OSType(character)
        }
    }
}
