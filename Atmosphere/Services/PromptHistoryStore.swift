import Foundation

/// Recall of previously sent prompts, in the spirit of a shell history.
///
/// A keyboard-first tool should never make you retype a prompt you already
/// wrote. History is capped and stored in preferences rather than the private
/// application directory: these are the user's own words, already visible in
/// the transcript, and no attachment or transcript content is kept here.
struct PromptHistoryStore {
    static let defaultStorageKey = "promptHistory"
    static let limit = 60
    static let maximumPromptLength = 4_000

    private let userDefaults: UserDefaults
    private let storageKey: String

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = Self.defaultStorageKey
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
    }

    /// Most recent first.
    func load() -> [String] {
        let stored = userDefaults.array(forKey: storageKey) as? [String] ?? []
        return Array(stored.prefix(Self.limit))
    }

    /// Returns the updated history so a caller can keep its in-memory copy in
    /// step without a second read.
    @discardableResult
    func record(_ prompt: String, in history: [String]) -> [String] {
        let updated = Self.appending(prompt, to: history)
        guard updated != history else { return history }
        userDefaults.set(updated, forKey: storageKey)
        return updated
    }

    static func appending(_ prompt: String, to history: [String]) -> [String] {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumPromptLength else { return history }

        var updated = history.filter { $0 != trimmed }
        updated.insert(trimmed, at: 0)
        return Array(updated.prefix(limit))
    }
}

/// Cursor over the history list plus the draft the user was in the middle of.
///
/// Stepping back from the newest entry restores that draft verbatim, so
/// browsing history can never eat text the user had not sent yet.
struct PromptHistoryCursor {
    private(set) var index: Int?
    private var stashedDraft = ""

    mutating func older(in history: [String], currentDraft: String) -> String? {
        guard !history.isEmpty else { return nil }

        switch index {
        case nil:
            stashedDraft = currentDraft
            index = 0
        case let current? where current + 1 < history.count:
            index = current + 1
        default:
            return nil
        }

        return index.map { history[$0] }
    }

    mutating func newer(in history: [String]) -> String? {
        guard let current = index else { return nil }

        if current == 0 {
            index = nil
            let draft = stashedDraft
            stashedDraft = ""
            return draft
        }

        index = current - 1
        return history[current - 1]
    }

    mutating func reset() {
        index = nil
        stashedDraft = ""
    }
}
