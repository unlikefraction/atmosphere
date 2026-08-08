import XCTest
@testable import Atmosphere

final class ClaudeStreamEventParserTests: XCTestCase {
    private let thread = "session-1"
    private let turn = "turn-1"
    private let item = "item-1"

    private func outcome(_ json: String) throws -> ClaudeStreamEventParser.Outcome {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        return ClaudeStreamEventParser.outcome(
            for: object,
            threadID: thread,
            turnID: turn,
            itemID: item
        )
    }

    func testInitCarriesTheSessionIdentifier() throws {
        let result = try outcome(#"{"type":"system","subtype":"init","session_id":"abc-123"}"#)

        XCTAssertEqual(result.sessionID, "abc-123")
        XCTAssertTrue(result.events.isEmpty)
    }

    func testTextDeltasBecomeAssistantDeltas() throws {
        let result = try outcome(
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hello"}}}"#
        )

        XCTAssertEqual(
            result.events,
            [.assistantDelta(threadID: thread, turnID: turn, itemID: item, delta: "hello")]
        )
    }

    func testEmptyDeltasAreDropped() throws {
        let result = try outcome(
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":""}}}"#
        )

        XCTAssertTrue(result.events.isEmpty)
    }

    func testTextBlockStartOpensTheAssistantMessage() throws {
        let result = try outcome(
            #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text","text":""}}}"#
        )

        XCTAssertEqual(
            result.events,
            [
                .assistantMessageStarted(
                    threadID: thread,
                    turnID: turn,
                    itemID: item,
                    phase: .finalAnswer
                )
            ]
        )
    }

    func testThinkingAndToolBlocksStayGenericActivity() throws {
        let thinking = try outcome(
            #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"thinking"}}}"#
        )
        let tool = try outcome(
            #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use","name":"Read","input":{"file_path":"/private/secret.txt"}}}}"#
        )

        XCTAssertTrue(thinking.events.isEmpty)
        XCTAssertEqual(thinking.activities.first?.kind, .reasoningSummary)
        XCTAssertEqual(tool.activities.first?.kind, .localContext)
        // Tool names, arguments, and paths must never reach the transcript.
        XCTAssertFalse(tool.activities.first?.message.contains("secret") ?? true)
        XCTAssertFalse(tool.activities.first?.message.contains("Read") ?? true)
    }

    func testThinkingDeltasNeverLeakRawReasoning() throws {
        let result = try outcome(
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"private chain of thought"}}}"#
        )

        XCTAssertTrue(result.events.isEmpty)
        XCTAssertTrue(result.activities.allSatisfy { !$0.message.contains("private") })
    }

    func testSuccessfulResultEndsTheTurnWithText() throws {
        let result = try outcome(
            #"{"type":"result","subtype":"success","is_error":false,"result":"final answer"}"#
        )

        XCTAssertTrue(result.turnDidEnd)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.completedText, "final answer")
    }

    func testErrorResultCarriesAFailure() throws {
        let result = try outcome(
            #"{"type":"result","subtype":"error_during_execution","is_error":true}"#
        )

        XCTAssertTrue(result.turnDidEnd)
        XCTAssertEqual(
            result.failure?.message,
            "Claude Code stopped before finishing the answer."
        )
        XCTAssertNil(result.completedText)
    }

    func testAssistantMessageProvidesFallbackText() throws {
        let result = try outcome(
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"whole message"}]}}"#
        )

        XCTAssertEqual(result.completedText, "whole message")
        XCTAssertFalse(result.turnDidEnd)
    }

    func testUnknownLinesAreIgnored() throws {
        let result = try outcome(#"{"type":"rate_limit_event","rate_limit_info":{}}"#)

        XCTAssertEqual(result, ClaudeStreamEventParser.Outcome())
    }
}

final class ClaudeCodeClientLaunchTests: XCTestCase {
    func testFirstLaunchClaimsASessionAndResumeReusesIt() {
        let fresh = ClaudeCodeClient.arguments(sessionID: "abc", resuming: false)
        let resumed = ClaudeCodeClient.arguments(sessionID: "abc", resuming: true)

        XCTAssertEqual(fresh.suffix(2), ["--session-id", "abc"])
        XCTAssertEqual(resumed.suffix(2), ["--resume", "abc"])
    }

    func testLaunchUsesStreamingJSONOnBothEnds() {
        let arguments = ClaudeCodeClient.arguments(sessionID: "abc", resuming: false)

        for expected in [
            "--print",
            "--verbose",
            "--include-partial-messages",
            "--dangerously-skip-permissions",
            "--strict-mcp-config"
        ] {
            XCTAssertTrue(arguments.contains(expected), expected)
        }
        XCTAssertEqual(value(after: "--input-format", in: arguments), "stream-json")
        XCTAssertEqual(value(after: "--output-format", in: arguments), "stream-json")
    }

    func testLaunchPinsOpusAtLightThinking() {
        let arguments = ClaudeCodeClient.arguments(sessionID: "abc", resuming: false)

        XCTAssertEqual(value(after: "--model", in: arguments), "claude-opus-5")
        XCTAssertEqual(value(after: "--effort", in: arguments), "low")
    }

    func testPermissionSkippingIsPairedWithReadOnlyTools() {
        let arguments = ClaudeCodeClient.arguments(sessionID: "abc", resuming: false)
        let tools = value(after: "--tools", in: arguments)?.split(separator: ",").map(String.init)

        XCTAssertEqual(tools?.sorted(), ["Glob", "Grep", "Read"])
        for forbidden in ["Bash", "Write", "Edit"] {
            XCTAssertFalse(tools?.contains(forbidden) ?? true, forbidden)
        }
    }

    /// Reports nothing as executable, so discovery can be tested on a machine
    /// that genuinely has the CLI installed.
    private final class EmptyFileManager: FileManager {
        override func isExecutableFile(atPath path: String) -> Bool { false }
    }

    func testMissingExecutableReportsWhereItLooked() {
        XCTAssertThrowsError(
            try ClaudeCodeClient.discoverExecutableURL(
                userDefaults: UserDefaults(suiteName: "ClaudeDiscovery-\(UUID().uuidString)")!,
                environment: ["PATH": "/nonexistent"],
                fileManager: EmptyFileManager()
            )
        ) { error in
            guard case ClaudeCodeError.executableNotFound(let paths) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(paths.contains("/nonexistent/claude"))
            XCTAssertTrue(paths.contains { $0.hasSuffix("/.local/bin/claude") })
        }
    }

    func testEncodedInputIsExactlyOneLine() throws {
        let line = try ClaudeCodeClient.encodeLine(["type": "user"])

        XCTAssertEqual(line.last, 0x0A)
        XCTAssertEqual(line.dropLast().filter { $0 == 0x0A }.count, 0)
    }

    func testScreenshotAttachmentsAnnounceTheirMediaType() {
        XCTAssertEqual(ClaudeCodeClient.mediaType(for: URL(fileURLWithPath: "/a/b.png")), "image/png")
        XCTAssertEqual(ClaudeCodeClient.mediaType(for: URL(fileURLWithPath: "/a/b.JPG")), "image/jpeg")
        XCTAssertEqual(ClaudeCodeClient.mediaType(for: URL(fileURLWithPath: "/a/b")), "image/png")
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
}

final class AssistantModelPreferenceTests: XCTestCase {
    func testDefaultsToLunaAndRoundTripsTheChoice() {
        let suite = "AssistantModel-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = AssistantModelPreference(userDefaults: defaults)

        XCTAssertEqual(preference.value(), .gptLuna)

        preference.save(.claudeOpus)

        XCTAssertEqual(preference.value(), .claudeOpus)
        XCTAssertEqual(AssistantModelPreference(userDefaults: defaults).value(), .claudeOpus)
    }

    func testUnknownStoredValueFallsBackToTheDefault() {
        let suite = "AssistantModel-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("gemini", forKey: AssistantModelPreference.defaultStorageKey)

        XCTAssertEqual(AssistantModelPreference(userDefaults: defaults).value(), .gptLuna)
    }

    func testSwitchingAlternatesBetweenTheTwoEngines() {
        XCTAssertEqual(AssistantModel.gptLuna.next, .claudeOpus)
        XCTAssertEqual(AssistantModel.claudeOpus.next, .gptLuna)
    }
}
