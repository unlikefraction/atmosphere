import AppKit
import Carbon.HIToolbox

/// Handles panel-scoped single-key actions without observing other apps.
///
/// Keep this controller alive for as long as the overlay can be shown and set
/// `isEnabled` only while the panel is visible. Matching events are consumed so
/// they do not also insert characters into the composer.
@MainActor
final class OverlayLocalShortcutController {
    private static let actionModifiers: NSEvent.ModifierFlags = [
        .command,
        .control,
        .option,
        .shift,
        .function
    ]

    private let onToggleAudio: () -> Void
    private let onCaptureScreenshot: () -> Void
    private let onCommand: (AtmosphereCommand) -> Void
    private var monitor: Any?

    private(set) var isEnabled = false

    init(
        onToggleAudio: @escaping () -> Void,
        onCaptureScreenshot: @escaping () -> Void,
        onCommand: @escaping (AtmosphereCommand) -> Void = { _ in }
    ) {
        self.onToggleAudio = onToggleAudio
        self.onCaptureScreenshot = onCaptureScreenshot
        self.onCommand = onCommand

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { @MainActor [weak self] event in
            Self.routeMonitoredEvent(event, through: self)
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    static func routeMonitoredEvent(
        _ event: NSEvent,
        through controller: OverlayLocalShortcutController?
    ) -> NSEvent? {
        guard let controller else { return event }
        return controller.filter(event)
    }

    private func filter(_ event: NSEvent) -> NSEvent? {
        guard isEnabled else { return event }

        let modifiers = event.modifierFlags.intersection(Self.actionModifiers)
        guard modifiers.isEmpty else {
            // In particular, Command-backslash remains available to the Carbon
            // global shortcut and is never consumed by this local monitor.
            guard let command = AtmosphereCommandMap.command(
                forKeyCode: Int(event.keyCode),
                modifiers: modifiers
            ) else { return event }

            if !event.isARepeat || command.repeatsWhenHeld {
                onCommand(command)
            }
            return nil
        }

        let action: (() -> Void)?
        switch Int(event.keyCode) {
        case kVK_ANSI_Backslash:
            action = onToggleAudio
        case kVK_ANSI_Grave:
            action = onCaptureScreenshot
        default:
            action = nil
        }

        guard let action else { return event }
        if !event.isARepeat {
            action()
        }
        return nil
    }
}
