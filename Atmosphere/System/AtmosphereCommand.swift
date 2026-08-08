import AppKit
import Carbon.HIToolbox

/// Every keyboard command the overlay answers while it is visible.
///
/// The overlay has no menu bar to hang key equivalents on, so the mapping is a
/// pure function over key code and modifiers. That keeps it testable and keeps
/// the two bare reserved keys (`\` and `` ` ``) in one place with the rest.
enum AtmosphereCommand: String, CaseIterable, Sendable {
    case newConversation
    case switchModel
    case clearAndHide
    case focusPrompt
    case stopGenerating
    case copyLastAnswer
    case chooseFolder
    case toggleShortcuts
    case historyOlder
    case historyNewer
    case opacityQuarter
    case opacityHalf
    case opacityFull

    var title: String {
        switch self {
        case .newConversation: return "New conversation"
        case .switchModel: return "Switch answer model"
        case .clearAndHide: return "Clear and hide"
        case .focusPrompt: return "Focus prompt"
        case .stopGenerating: return "Stop generating"
        case .copyLastAnswer: return "Copy last answer"
        case .chooseFolder: return "Choose operating folder"
        case .toggleShortcuts: return "Keyboard shortcuts"
        case .historyOlder: return "Previous prompt"
        case .historyNewer: return "Next prompt"
        case .opacityQuarter: return "Opacity 25%"
        case .opacityHalf: return "Opacity 50%"
        case .opacityFull: return "Opacity 100%"
        }
    }

    /// Holding the keys down should keep stepping only where repeating is the
    /// point; everything else fires once per press.
    var repeatsWhenHeld: Bool {
        self == .historyOlder || self == .historyNewer
    }

    /// Display keys, in the order Apple writes them.
    var keys: [String] {
        switch self {
        case .newConversation: return ["⌘", "N"]
        case .switchModel: return ["⌘", "M"]
        case .clearAndHide: return ["⌘", "⌫"]
        case .focusPrompt: return ["⌘", "L"]
        case .stopGenerating: return ["⌘", "."]
        case .copyLastAnswer: return ["⌘", "⇧", "C"]
        case .chooseFolder: return ["⌘", "O"]
        case .toggleShortcuts: return ["⌘", "/"]
        case .historyOlder: return ["⌘", "↑"]
        case .historyNewer: return ["⌘", "↓"]
        case .opacityQuarter: return ["⌘", "1"]
        case .opacityHalf: return ["⌘", "2"]
        case .opacityFull: return ["⌘", "3"]
        }
    }
}

enum AtmosphereCommandMap {
    /// `⌘\` stays with the global show/hide hot key and `⌘\`` stays with the
    /// system's window cycling, so neither appears here.
    static func command(
        forKeyCode keyCode: Int,
        modifiers: NSEvent.ModifierFlags
    ) -> AtmosphereCommand? {
        let active = modifiers.intersection([.command, .shift, .option, .control, .function])

        if active == [.command, .shift] {
            return keyCode == kVK_ANSI_C ? .copyLastAnswer : nil
        }

        // Arrow keys carry .function on real hardware events.
        if active == [.command] || active == [.command, .function] {
            switch keyCode {
            case kVK_UpArrow: return .historyOlder
            case kVK_DownArrow: return .historyNewer
            default: break
            }
        }

        guard active == [.command] else { return nil }

        switch keyCode {
        case kVK_ANSI_N: return .newConversation
        case kVK_ANSI_M: return .switchModel
        case kVK_Delete: return .clearAndHide
        case kVK_ANSI_L: return .focusPrompt
        case kVK_ANSI_Period: return .stopGenerating
        case kVK_ANSI_O: return .chooseFolder
        case kVK_ANSI_Slash: return .toggleShortcuts
        case kVK_ANSI_1: return .opacityQuarter
        case kVK_ANSI_2: return .opacityHalf
        case kVK_ANSI_3: return .opacityFull
        default: return nil
        }
    }
}
