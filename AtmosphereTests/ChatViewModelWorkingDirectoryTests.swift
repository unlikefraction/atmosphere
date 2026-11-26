import AppKit
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

@MainActor
final class ChatViewModelReconnectTests: XCTestCase {
    private var suiteName: String!
    private var userDefaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "ChatViewModelReconnectTests-\(UUID().uuidString)"
        userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        AssistantModelPreference(userDefaults: userDefaults).save(.gptTerra)
    }

    override func tearDownWithError() throws {
        userDefaults?.removePersistentDomain(forName: suiteName)
        userDefaults = nil
        suiteName = nil
    }

    func testTransientStartupFailuresRetryUntilReadyToSend() async throws {
        let backend = ReconnectTestBackend(outcomes: [.transientFailure, .transientFailure, .ready])
        let viewModel = makeViewModel(backend: backend)

        await viewModel.connect()
        await waitUntil { viewModel.canSend }

        XCTAssertEqual(viewModel.connectionStatus, .connected)
        XCTAssertNil(viewModel.errorMessage)
        let starts = await backend.startCount
        XCTAssertEqual(starts, 3)
        await viewModel.shutdown()
    }

    func testBackendFailureEventReconnectsAndRestoresSending() async {
        let backend = ReconnectTestBackend(outcomes: [.ready])
        let viewModel = makeViewModel(backend: backend)
        await viewModel.connect()
        await waitUntil { viewModel.canSend }

        await backend.failConnection()
        await waitUntil { await backend.startCount == 2 && viewModel.canSend }

        XCTAssertEqual(viewModel.connectionStatus, .connected)
        XCTAssertNil(viewModel.errorMessage)
        await viewModel.shutdown()
    }

    func testVisibleOverlayLaysOutAcrossRepeatedConnectionFailures() async throws {
        let frameKey = "NSWindow Frame \(OverlayFramePersistence.autosaveName)"
        let savedFrame = UserDefaults.standard.object(forKey: frameKey)
        defer {
            if let savedFrame {
                UserDefaults.standard.set(savedFrame, forKey: frameKey)
            } else {
                UserDefaults.standard.removeObject(forKey: frameKey)
            }
        }
        let existingWindows = Set(NSApp.windows.map { ObjectIdentifier($0) })
        let backend = ReconnectTestBackend(outcomes: [.ready])
        let viewModel = makeViewModel(backend: backend, reconnectDelay: 0.25)
        await viewModel.connect()
        await waitUntil { viewModel.canSend }
        let overlay = OverlayController(
            viewModel: viewModel,
            opacityPreference: OverlayOpacityPreference(userDefaults: userDefaults)
        )
        overlay.show()
        let panel = NSApp.windows.first {
            $0 is OverlayPanel && !existingWindows.contains(ObjectIdentifier($0))
        }
        XCTAssertNotNil(panel)
        try await exerciseLayout(panel, duration: 0.3)

        for expectedStarts in 2...4 {
            await backend.failConnection()
            await waitUntil { viewModel.connectionStatus == .failed }
            try await exerciseLayout(panel, duration: 0.05)
            assertWindowFitsScreen(panel)
            await waitUntil { await backend.startCount == expectedStarts && viewModel.canSend }
            try await exerciseLayout(panel, duration: 0.3)

            XCTAssertTrue(overlay.isVisible)
            XCTAssertEqual(viewModel.connectionStatus, .connected)
            assertWindowFitsScreen(panel)
        }

        await overlay.shutdown()
        await viewModel.shutdown()
        XCTAssertFalse(overlay.isVisible)
    }

    func testReconnectStopsPartialResponseWithoutReplayingRequest() async throws {
        let backend = ReconnectTestBackend(outcomes: [.ready])
        let viewModel = makeViewModel(backend: backend)
        await viewModel.connect()
        await waitUntil { viewModel.canSend }
        viewModel.send("Run the requested task")
        await waitUntil {
            viewModel.messages.contains { $0.role == .assistant && $0.text == "Partial response" }
        }

        await backend.failConnection()
        await waitUntil { await backend.startCount == 2 && viewModel.canSend }

        let starts = await backend.startCount
        let sends = await backend.sendCount
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(sends, 1)
        let response = try XCTUnwrap(viewModel.messages.first { $0.role == .assistant })
        XCTAssertEqual(response.text, "Partial response")
        XCTAssertFalse(response.isStreaming)
        XCTAssertFalse(viewModel.isGenerating)
        XCTAssertTrue(viewModel.errorMessage?.localizedCaseInsensitiveContains("interrupted") == true)
        await viewModel.shutdown()
    }

    func testAuthenticationFailureDoesNotRetry() async throws {
        for outcome in [ReconnectTestBackend.StartOutcome.authenticationError, .signedOut] {
            let backend = ReconnectTestBackend(outcomes: [outcome])
            let viewModel = makeViewModel(backend: backend)
            await viewModel.connect()
            await waitUntil { viewModel.connectionStatus == .authenticationRequired }

            try await Task.sleep(nanoseconds: 80_000_000)

            let starts = await backend.startCount
            XCTAssertEqual(starts, 1)
            XCTAssertTrue(viewModel.requiresAuthentication)
            XCTAssertFalse(viewModel.canSend)
            await viewModel.shutdown()
        }
    }

    func testShutdownCancelsPendingReconnect() async throws {
        let backend = ReconnectTestBackend(outcomes: [.transientFailure, .ready])
        let viewModel = makeViewModel(backend: backend, reconnectDelay: 0.05)
        await viewModel.connect()
        XCTAssertEqual(viewModel.connectionStatus, .failed)

        await viewModel.shutdown()
        try await Task.sleep(nanoseconds: 100_000_000)

        let starts = await backend.startCount
        XCTAssertEqual(starts, 1)
        XCTAssertFalse(viewModel.canSend)
    }

    func testDelayedFailureEventDoesNotRetryPermanentStartupFailure() async throws {
        let backend = ReconnectTestBackend(outcomes: [.executableNotFound, .ready])
        let viewModel = makeViewModel(backend: backend)
        await viewModel.connect()
        XCTAssertEqual(viewModel.connectionStatus, .failed)

        await backend.failConnection()
        await waitUntil { viewModel.errorMessage == "Test connection dropped" }
        try await Task.sleep(nanoseconds: 80_000_000)

        let starts = await backend.startCount
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(viewModel.connectionStatus, .failed)
        XCTAssertFalse(viewModel.canSend)
        await viewModel.shutdown()
    }

    private func makeViewModel(
        backend: ReconnectTestBackend,
        reconnectDelay: TimeInterval = 0.01
    ) -> ChatViewModel {
        ChatViewModel(
            client: backend,
            modelPreference: AssistantModelPreference(userDefaults: userDefaults),
            workingDirectoryPreference: WorkingDirectoryPreference(userDefaults: userDefaults),
            reconnectDelay: reconnectDelay
        )
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for reconnect state", file: file, line: line)
    }

    private func exerciseLayout(_ window: NSWindow?, duration: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(duration)
        repeat {
            window?.contentView?.layoutSubtreeIfNeeded()
            window?.displayIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline
    }

    private func assertWindowFitsScreen(
        _ window: NSWindow?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let window, let screen = window.screen else {
            XCTFail("Visible overlay must belong to a screen", file: file, line: line)
            return
        }
        XCTAssertLessThanOrEqual(window.frame.height, screen.visibleFrame.height, file: file, line: line)
    }
}

private actor ReconnectTestBackend: AssistantBackend {
    enum StartOutcome: Sendable {
        case transientFailure
        case ready
        case authenticationError
        case signedOut
        case executableNotFound
    }

    nonisolated let events: AsyncStream<AssistantEvent>
    nonisolated let activityEvents: AsyncStream<AssistantActivity>
    private let eventContinuation: AsyncStream<AssistantEvent>.Continuation
    private let activityContinuation: AsyncStream<AssistantActivity>.Continuation
    private let outcomes: [StartOutcome]
    private(set) var startCount = 0
    private(set) var sendCount = 0

    init(outcomes: [StartOutcome]) {
        self.outcomes = outcomes
        let eventStream = AsyncStream<AssistantEvent>.makeStream()
        events = eventStream.stream
        eventContinuation = eventStream.continuation
        let activityStream = AsyncStream<AssistantActivity>.makeStream()
        activityEvents = activityStream.stream
        activityContinuation = activityStream.continuation
    }

    func setWorkingDirectory(_ directory: URL?) {}

    func start() async throws -> AssistantAccountStatus {
        let outcome = outcomes[min(startCount, outcomes.count - 1)]
        startCount += 1
        switch outcome {
        case .transientFailure:
            throw CodexAppServerError.connectionClosed(exitCode: 1, details: "Temporary test failure")
        case .authenticationError:
            throw CodexAppServerError.authenticationRequired
        case .executableNotFound:
            throw CodexAppServerError.executableNotFound(searchedPaths: ["/missing/test-codex"])
        case .signedOut:
            return AssistantAccountStatus(account: nil, requiresOpenAIAuth: true)
        case .ready:
            eventContinuation.yield(.threadReady(threadID: "test-thread-\(startCount)"))
            return AssistantAccountStatus(account: nil, requiresOpenAIAuth: false)
        }
    }

    func failConnection() {
        eventContinuation.yield(.connectionStateChanged(.failed("Test connection dropped")))
    }

    func startManagedChatGPTLogin() async throws -> CodexLoginChallenge {
        throw AssistantBackendError.signInNotSupported(provider: "Test")
    }

    func cancelLogin() async throws {}
    func send(_ text: String, localImages: [URL]) async throws -> String {
        sendCount += 1
        let threadID = "test-thread-\(startCount)"
        let turnID = "test-turn-\(sendCount)"
        eventContinuation.yield(.turnStarted(threadID: threadID, turnID: turnID))
        eventContinuation.yield(.assistantDelta(
            threadID: threadID,
            turnID: turnID,
            itemID: "test-item-\(sendCount)",
            delta: "Partial response"
        ))
        return turnID
    }
    func cancelCurrentTurn() async throws -> Bool { false }
    func resetConversation() async throws -> String? { "test-thread" }

    func stop() {
        eventContinuation.finish()
        activityContinuation.finish()
    }
}
