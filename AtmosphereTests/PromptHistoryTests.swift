import XCTest
@testable import Atmosphere

final class PromptHistoryTests: XCTestCase {
    func testNewestPromptComesFirstAndRepeatsMoveUp() {
        var history = PromptHistoryStore.appending("first", to: [])
        history = PromptHistoryStore.appending("second", to: history)
        history = PromptHistoryStore.appending("first", to: history)

        XCTAssertEqual(history, ["first", "second"])
    }

    func testBlankAndOversizedPromptsAreNotRecorded() {
        let history = ["kept"]

        XCTAssertEqual(PromptHistoryStore.appending("   \n ", to: history), history)
        XCTAssertEqual(
            PromptHistoryStore.appending(
                String(repeating: "x", count: PromptHistoryStore.maximumPromptLength + 1),
                to: history
            ),
            history
        )
    }

    func testHistoryIsCapped() {
        var history: [String] = []
        for index in 0..<(PromptHistoryStore.limit + 15) {
            history = PromptHistoryStore.appending("prompt \(index)", to: history)
        }

        XCTAssertEqual(history.count, PromptHistoryStore.limit)
        XCTAssertEqual(history.first, "prompt \(PromptHistoryStore.limit + 14)")
    }

    func testPromptsPersistAcrossStoreInstances() {
        let suiteName = "PromptHistoryTests-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = PromptHistoryStore(userDefaults: userDefaults)
        let updated = store.record("remembered", in: store.load())

        XCTAssertEqual(updated, ["remembered"])
        XCTAssertEqual(PromptHistoryStore(userDefaults: userDefaults).load(), ["remembered"])
    }

    func testCursorWalksBackwardThenRestoresTheUnsentDraft() {
        let history = ["newest", "older", "oldest"]
        var cursor = PromptHistoryCursor()

        XCTAssertEqual(cursor.older(in: history, currentDraft: "half typed"), "newest")
        XCTAssertEqual(cursor.older(in: history, currentDraft: "ignored"), "older")
        XCTAssertEqual(cursor.older(in: history, currentDraft: "ignored"), "oldest")
        XCTAssertNil(cursor.older(in: history, currentDraft: "ignored"))

        XCTAssertEqual(cursor.newer(in: history), "older")
        XCTAssertEqual(cursor.newer(in: history), "newest")
        XCTAssertEqual(cursor.newer(in: history), "half typed")
        XCTAssertNil(cursor.newer(in: history))
    }

    func testCursorDoesNothingWithoutHistory() {
        var cursor = PromptHistoryCursor()

        XCTAssertNil(cursor.older(in: [], currentDraft: "draft"))
        XCTAssertNil(cursor.newer(in: []))
    }

    func testResetForgetsTheStashedDraft() {
        let history = ["newest"]
        var cursor = PromptHistoryCursor()

        XCTAssertEqual(cursor.older(in: history, currentDraft: "draft"), "newest")
        cursor.reset()

        XCTAssertNil(cursor.newer(in: history))
        XCTAssertEqual(cursor.older(in: history, currentDraft: "typed again"), "newest")
        XCTAssertEqual(cursor.newer(in: history), "typed again")
    }
}
