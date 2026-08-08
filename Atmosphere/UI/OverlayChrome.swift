import Foundation

/// State the panel and its SwiftUI content both need to agree on.
///
/// The overlay is an AppKit panel wrapping a SwiftUI tree, and a few concerns —
/// the shortcut sheet, panel opacity, keyboard commands arriving from the event
/// monitor — belong to neither side alone. Keeping them in one observable
/// object avoids threading a growing pile of bindings through `ChatView`.
@MainActor
final class OverlayChrome: ObservableObject {
    struct CommandEnvelope: Equatable {
        let id: UUID
        let command: AtmosphereCommand
    }

    @Published var isShortcutsVisible = false
    @Published private(set) var opacity: Double
    /// Identified so two presses of the same shortcut are two distinct events.
    @Published private(set) var pendingCommand: CommandEnvelope?

    init(opacity: Double = 1) {
        self.opacity = opacity
    }

    func dispatch(_ command: AtmosphereCommand) {
        pendingCommand = CommandEnvelope(id: UUID(), command: command)
    }

    func setOpacity(_ value: Double) {
        opacity = value
    }

    /// True when Escape was consumed by chrome and must not also hide the panel.
    ///
    /// One key press can reach both the SwiftUI tree and the panel's
    /// `cancelOperation(_:)`, depending on where first responder sits. Whoever
    /// gets there first wins, and the echo is swallowed — closing the shortcut
    /// sheet must never hide the overlay in the same keystroke.
    func consumeEscape() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if isShortcutsVisible {
            isShortcutsVisible = false
            lastEscapeConsumedAt = now
            return true
        }
        return now - lastEscapeConsumedAt < Self.escapeEchoWindow
    }

    static let escapeEchoWindow: TimeInterval = 0.25
    private var lastEscapeConsumedAt: TimeInterval = -.greatestFiniteMagnitude
}
