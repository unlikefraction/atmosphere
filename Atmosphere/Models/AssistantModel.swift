import Foundation

/// The two answer engines Atmosphere can talk to.
///
/// Both are local, first-party CLIs the user already has and is already signed
/// in to — Atmosphere never holds a key for either. Switching is a whole-thread
/// change: a conversation belongs to one engine and does not migrate.
enum AssistantModel: String, CaseIterable, Sendable {
    case gptLuna
    case claudeOpus

    static let `default` = AssistantModel.gptLuna

    /// The footer label. Short enough to sit beside the folder chip.
    var shortTitle: String {
        switch self {
        case .gptLuna: return "GPT‑5.6 Luna"
        case .claudeOpus: return "Claude Opus 5"
        }
    }

    var menuTitle: String {
        switch self {
        case .gptLuna: return "GPT-5.6 Luna · Medium"
        case .claudeOpus: return "Claude Opus 5 · Light thinking"
        }
    }

    var helpText: String {
        switch self {
        case .gptLuna:
            return "Answer model: GPT-5.6 Luna with medium reasoning effort, through the Codex app server. ⌘M switches."
        case .claudeOpus:
            return "Answer model: Claude Opus 5 with low effort, through the Claude Code CLI. ⌘M switches."
        }
    }

    /// The connection label shown beside the status dot.
    var providerName: String {
        switch self {
        case .gptLuna: return "ChatGPT"
        case .claudeOpus: return "Claude"
        }
    }

    var next: AssistantModel {
        self == .gptLuna ? .claudeOpus : .gptLuna
    }
}

/// Remembers the chosen engine across launches.
struct AssistantModelPreference {
    static let defaultStorageKey = "assistantModel"

    private let userDefaults: UserDefaults
    private let storageKey: String

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = Self.defaultStorageKey
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
    }

    func value() -> AssistantModel {
        guard let raw = userDefaults.string(forKey: storageKey),
              let model = AssistantModel(rawValue: raw) else {
            return .default
        }
        return model
    }

    @discardableResult
    func save(_ model: AssistantModel) -> AssistantModel {
        userDefaults.set(model.rawValue, forKey: storageKey)
        return model
    }
}
