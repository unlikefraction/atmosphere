import Foundation
import XCTest
@testable import Atmosphere

@MainActor
final class ChatViewModelWorkingDirectoryTests: XCTestCase {
    private var suiteName: String!
    private var userDefaults: UserDefaults!
    private var testRoot: URL!

    override func setUpWithError() throws {
        suiteName = "ChatViewModelWorkingDirectoryTests-\(UUID().uuidString)"
        userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)

        testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AtmosphereViewModelWorkingDirectoryTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: testRoot,
            withIntermediateDirectories: false
        )
    }

    override func tearDownWithError() throws {
        if let testRoot {
            try? FileManager.default.removeItem(at: testRoot)
        }
        if let suiteName {
            userDefaults?.removePersistentDomain(forName: suiteName)
        }
        testRoot = nil
        userDefaults = nil
        suiteName = nil
    }

    func testInitializationLoadsPersistedWorkingDirectory() async throws {
        let preference = makePreference()
        try preference.selectDirectory(testRoot)

        let viewModel = makeViewModel(preference: preference)

        XCTAssertEqual(viewModel.selectedWorkingDirectory, testRoot.standardizedFileURL)
        await viewModel.shutdown()
    }

    func testSelectingWorkingDirectoryPersistsAndUpdatesPublishedState() async {
        let preference = makePreference()
        let viewModel = makeViewModel(preference: preference)

        let changed = await viewModel.selectWorkingDirectory(testRoot)

        XCTAssertTrue(changed)
        XCTAssertFalse(viewModel.isChangingWorkingDirectory)
        XCTAssertEqual(viewModel.selectedWorkingDirectory, testRoot.standardizedFileURL)
        XCTAssertEqual(try? preference.selectedDirectory(), testRoot.standardizedFileURL)
        await viewModel.shutdown()
    }

    func testRemovingWorkingDirectoryPersistsAndUpdatesPublishedState() async throws {
        let preference = makePreference()
        try preference.selectDirectory(testRoot)
        let viewModel = makeViewModel(preference: preference)

        let changed = await viewModel.removeWorkingDirectory()

        XCTAssertTrue(changed)
        XCTAssertNil(viewModel.selectedWorkingDirectory)
        XCTAssertNil(try preference.selectedDirectory())
        await viewModel.shutdown()
    }

    func testInvalidSelectionKeepsExistingWorkingDirectory() async throws {
        let preference = makePreference()
        try preference.selectDirectory(testRoot)
        let viewModel = makeViewModel(preference: preference)
        let missingURL = testRoot.appendingPathComponent("Missing", isDirectory: true)

        let changed = await viewModel.selectWorkingDirectory(missingURL)

        XCTAssertFalse(changed)
        XCTAssertEqual(viewModel.selectedWorkingDirectory, testRoot.standardizedFileURL)
        XCTAssertEqual(try preference.selectedDirectory(), testRoot.standardizedFileURL)
        XCTAssertNotNil(viewModel.errorMessage)
        await viewModel.shutdown()
    }

    func testWorkingDirectoryChangeIsBlockedDuringScreenshotCapture() async throws {
        let preference = makePreference()
        try preference.selectDirectory(testRoot)
        let replacement = testRoot.appendingPathComponent("Replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
        let viewModel = makeViewModel(preference: preference)
        XCTAssertNotNil(viewModel.beginScreenshotCapture())

        let changed = await viewModel.selectWorkingDirectory(replacement)

        XCTAssertFalse(changed)
        XCTAssertFalse(viewModel.canChangeWorkingDirectory)
        XCTAssertEqual(viewModel.selectedWorkingDirectory, testRoot.standardizedFileURL)
        XCTAssertEqual(try preference.selectedDirectory(), testRoot.standardizedFileURL)
        viewModel.cancelScreenshotCapture()
        await viewModel.shutdown()
    }

    func testOrdinaryConversationResetsPreserveWorkingDirectory() async throws {
        let preference = makePreference()
        try preference.selectDirectory(testRoot)
        let viewModel = makeViewModel(preference: preference)

        viewModel.newConversation()
        await waitForConversationReset(viewModel)
        viewModel.clearConversation()
        await waitForConversationReset(viewModel)

        XCTAssertEqual(viewModel.selectedWorkingDirectory, testRoot.standardizedFileURL)
        XCTAssertEqual(try preference.selectedDirectory(), testRoot.standardizedFileURL)
        await viewModel.shutdown()
    }

    private func makePreference() -> WorkingDirectoryPreference {
        WorkingDirectoryPreference(userDefaults: userDefaults)
    }

    private func makeViewModel(
        preference: WorkingDirectoryPreference
    ) -> ChatViewModel {
        ChatViewModel(workingDirectoryPreference: preference)
    }

    private func waitForConversationReset(_ viewModel: ChatViewModel) async {
        for _ in 0..<100 where viewModel.isResettingConversation {
            await Task.yield()
        }
        XCTAssertFalse(viewModel.isResettingConversation)
    }
}
