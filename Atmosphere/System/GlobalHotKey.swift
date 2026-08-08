import Carbon.HIToolbox
import Foundation

/// Registers one system-wide shortcut without Accessibility or Input Monitoring
/// permission. Carbon hot keys are old but remain the smallest supported way to
/// receive a single global shortcut without observing arbitrary keyboard input.
final class GlobalHotKey {
    private static let signature: OSType = 0x41544D4F // "ATMO"

    private let action: () -> Void
    private let identifier = EventHotKeyID(signature: signature, id: 1)
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private static let eventCallback: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }

        let instance = Unmanaged<GlobalHotKey>
            .fromOpaque(userData)
            .takeUnretainedValue()

        var incomingID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &incomingID
        )

        guard status == noErr,
              incomingID.signature == instance.identifier.signature,
              incomingID.id == instance.identifier.id else {
            return OSStatus(eventNotHandledErr)
        }

        DispatchQueue.main.async {
            instance.action()
        }
        return noErr
    }

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventCallback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        guard handlerStatus == noErr else { return nil }

        let registrationStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard registrationStatus == noErr else {
            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
                self.eventHandlerRef = nil
            }
            return nil
        }
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }
}
