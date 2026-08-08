import Foundation
import XCTest
@testable import Atmosphere

final class CodexJSONRPCEventParserTests: XCTestCase {
    func testParsesAssistantDelta() throws {
        let line = Data(#"{"method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","delta":"Hello"}}"#.utf8)

        let event = try CodexJSONRPCEventParser.parseEvent(from: line)

        XCTAssertEqual(
            event,
            .assistantDelta(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "item-1",
                delta: "Hello"
            )
        )
    }

    func testParsesCompletedAssistantMessage() throws {
        let line = Data(#"{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","completedAtMs":12,"item":{"type":"agentMessage","id":"item-1","text":"Full answer"}}}"#.utf8)

        let event = try CodexJSONRPCEventParser.parseEvent(from: line)

        XCTAssertEqual(
            event,
            .assistantMessageCompleted(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "item-1",
                text: "Full answer",
                phase: nil
            )
        )
    }

    func testParsesCommentaryMessagePhase() throws {
        let line = Data(#"{"method":"item/started","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"agentMessage","id":"item-1","text":"","phase":"commentary"}}}"#.utf8)

        let event = try CodexJSONRPCEventParser.parseEvent(from: line)

        XCTAssertEqual(
            event,
            .assistantMessageStarted(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "item-1",
                phase: .commentary
            )
        )
    }

    func testParsesFinalAnswerPhase() throws {
        let line = Data(#"{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"agentMessage","id":"item-1","text":"Done","phase":"final_answer"}}}"#.utf8)

        let event = try CodexJSONRPCEventParser.parseEvent(from: line)

        XCTAssertEqual(
            event,
            .assistantMessageCompleted(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "item-1",
                text: "Done",
                phase: .finalAnswer
            )
        )
    }

    func testParsesFailedTurn() throws {
        let line = Data(#"{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"failed","items":[],"error":{"message":"Rate limit reached","additionalDetails":"Try later"}}}}"#.utf8)

        let event = try CodexJSONRPCEventParser.parseEvent(from: line)

        XCTAssertEqual(
            event,
            .turnCompleted(
                threadID: "thread-1",
                turnID: "turn-1",
                status: .failed,
                failure: AssistantTurnFailure(
                    message: "Rate limit reached",
                    additionalDetails: "Try later",
                    willRetry: false
                )
            )
        )
    }

    func testParsesRetryingTurnError() throws {
        let line = Data(#"{"method":"error","params":{"threadId":"thread-1","turnId":"turn-1","willRetry":true,"error":{"message":"Connection interrupted","additionalDetails":null}}}"#.utf8)

        let event = try CodexJSONRPCEventParser.parseEvent(from: line)

        XCTAssertEqual(
            event,
            .turnError(
                threadID: "thread-1",
                turnID: "turn-1",
                failure: AssistantTurnFailure(
                    message: "Connection interrupted",
                    additionalDetails: nil,
                    willRetry: true
                )
            )
        )
    }

    func testParsesManagedLoginCompletion() throws {
        let line = Data(#"{"method":"account/login/completed","params":{"loginId":"login-1","success":true,"error":null}}"#.utf8)

        let event = try CodexJSONRPCEventParser.parseEvent(from: line)

        XCTAssertEqual(
            event,
            .loginCompleted(loginID: "login-1", success: true, error: nil)
        )
    }

    func testIgnoresUnknownNotification() throws {
        let line = Data(#"{"method":"future/newNotification","params":{"value":1}}"#.utf8)

        XCTAssertNil(try CodexJSONRPCEventParser.parseEvent(from: line))
    }

    func testRejectsMalformedJSON() {
        XCTAssertThrowsError(
            try CodexJSONRPCEventParser.parseEvent(from: Data("{".utf8))
        )
    }

    func testThreadStartParametersPinLunaMediumAndConciseSummary() throws {
        let directory = URL(fileURLWithPath: "/tmp/atmosphere-assistant")
        let params = CodexAppServerRequestBuilder.threadStartParameters(
            workingDirectory: directory,
            developerInstructions: "Be concise."
        )
        let config = try XCTUnwrap(params["config"] as? JSONObject)
        let features = try XCTUnwrap(config["features"] as? JSONObject)
        let agents = try XCTUnwrap(config["agents"] as? JSONObject)
        let apps = try XCTUnwrap(config["apps"] as? JSONObject)
        let defaultApp = try XCTUnwrap(apps["_default"] as? JSONObject)

        XCTAssertEqual(params["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual(config["model_reasoning_effort"] as? String, "medium")
        XCTAssertEqual(config["model_reasoning_summary"] as? String, "concise")
        XCTAssertEqual(config["allow_login_shell"] as? Bool, false)
        XCTAssertEqual(config["web_search"] as? String, "disabled")
        XCTAssertEqual(agents["enabled"] as? Bool, false)
        XCTAssertEqual(defaultApp["enabled"] as? Bool, false)
        XCTAssertEqual(features["apps"] as? Bool, false)
        XCTAssertEqual(features["plugins"] as? Bool, false)
        XCTAssertEqual(features["multi_agent"] as? Bool, false)
        XCTAssertEqual(features["code_mode"] as? Bool, false)
        XCTAssertEqual(features["code_mode_only"] as? Bool, false)
        XCTAssertEqual(features["computer_use"] as? Bool, false)
        XCTAssertEqual(features["browser_use"] as? Bool, false)
        XCTAssertEqual(params["cwd"] as? String, directory.path)
        XCTAssertEqual(params["sandbox"] as? String, "read-only")
        XCTAssertEqual(params["approvalPolicy"] as? String, "never")
        XCTAssertEqual(params["developerInstructions"] as? String, "Be concise.")
    }

    func testAppServerLaunchDisablesInteractiveAndConnectedTools() {
        let arguments = CodexAppServerLaunchConfiguration.arguments

        XCTAssertTrue(arguments.suffix(2).elementsEqual(["app-server", "--stdio"]))
        XCTAssertTrue(arguments.contains("features.computer_use=false"))
        XCTAssertTrue(arguments.contains("features.browser_use=false"))
        XCTAssertTrue(arguments.contains("features.plugins=false"))
        XCTAssertTrue(arguments.contains("features.multi_agent=false"))
        XCTAssertTrue(arguments.contains("features.code_mode=false"))
        XCTAssertTrue(arguments.contains("features.code_mode_only=false"))
        XCTAssertTrue(arguments.contains("mcp_servers={}"))
        XCTAssertTrue(arguments.contains("web_search=\"disabled\""))
    }

    func testTurnStartParametersReassertPinnedModelEffortAndSummary() throws {
        let directory = URL(fileURLWithPath: "/tmp/atmosphere-assistant")
        let input: [JSONObject] = [["type": "text", "text": "Hello"]]
        let params = CodexAppServerRequestBuilder.turnStartParameters(
            threadID: "thread-1",
            userInput: input,
            workingDirectory: directory
        )
        let sandbox = try XCTUnwrap(params["sandboxPolicy"] as? JSONObject)

        XCTAssertEqual(params["threadId"] as? String, "thread-1")
        XCTAssertEqual(params["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual(params["effort"] as? String, "medium")
        XCTAssertEqual(params["summary"] as? String, "concise")
        XCTAssertEqual(sandbox["type"] as? String, "readOnly")
        XCTAssertEqual(sandbox["networkAccess"] as? Bool, false)
        XCTAssertEqual((params["input"] as? [JSONObject])?.count, 1)
    }

    func testParsesCurrentPlanStepAsReadableActivity() throws {
        let line = Data(
            #"{"method":"turn/plan/updated","params":{"threadId":"thread-1","turnId":"turn-1","explanation":"Plan","plan":[{"step":"Check the latest sources","status":"inProgress"},{"step":"Answer","status":"pending"}]}}"#.utf8
        )

        let signal = try CodexJSONRPCActivityParser.parseSignal(from: line)

        XCTAssertEqual(
            signal,
            .replace(
                AssistantActivity(
                    threadID: "thread-1",
                    turnID: "turn-1",
                    itemID: nil,
                    kind: .planning,
                    message: "Check the latest sources"
                )
            )
        )
    }

    func testAccumulatesReadableReasoningSummaryDeltas() throws {
        let first = Data(
            #"{"method":"item/reasoning/summaryTextDelta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"reason-1","summaryIndex":0,"delta":"Checking "}}"#.utf8
        )
        let second = Data(
            #"{"method":"item/reasoning/summaryTextDelta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"reason-1","summaryIndex":0,"delta":"the available context"}}"#.utf8
        )
        var tracker = AssistantActivityTracker()
        let firstSignal = try XCTUnwrap(CodexJSONRPCActivityParser.parseSignal(from: first))
        let secondSignal = try XCTUnwrap(CodexJSONRPCActivityParser.parseSignal(from: second))

        XCTAssertEqual(tracker.consume(firstSignal)?.message, "Checking")
        let activity = tracker.consume(secondSignal)

        XCTAssertEqual(activity?.kind, .reasoningSummary)
        XCTAssertEqual(activity?.message, "Checking the available context")
    }

    func testNeverExposesRawReasoningTextDelta() throws {
        let line = Data(
            #"{"method":"item/reasoning/textDelta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"reason-1","contentIndex":0,"delta":"private raw reasoning"}}"#.utf8
        )

        XCTAssertNil(try CodexJSONRPCActivityParser.parseSignal(from: line))
    }

    func testToolLifecycleUsesGenericLabelWithoutCommandOrArguments() throws {
        let line = Data(
            #"{"method":"item/started","params":{"threadId":"thread-1","turnId":"turn-1","startedAtMs":1,"item":{"type":"commandExecution","id":"command-1","command":"cat /private/secret","cwd":"/tmp","status":"inProgress","commandActions":[]}}}"#.utf8
        )
        let signal = try CodexJSONRPCActivityParser.parseSignal(from: line)

        XCTAssertEqual(
            signal,
            .replace(
                AssistantActivity(
                    threadID: "thread-1",
                    turnID: "turn-1",
                    itemID: "command-1",
                    kind: .localContext,
                    message: "Checking local context"
                )
            )
        )
    }

    func testCommentaryStreamsAsActivityUntilFinalAnswerStarts() throws {
        var tracker = AssistantActivityTracker()
        let started = tracker.consume(
            .assistantMessageStarted(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "commentary-1",
                phase: .commentary
            )
        )
        let commentary = tracker.consume(
            .assistantDelta(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "commentary-1",
                delta: "Checking the sources"
            )
        )

        XCTAssertEqual(started?.kind, .commentary)
        XCTAssertEqual(commentary?.message, "Checking the sources")

        XCTAssertNil(
            tracker.consume(
                .assistantMessageStarted(
                    threadID: "thread-1",
                    turnID: "turn-1",
                    itemID: "answer-1",
                    phase: .finalAnswer
                )
            )
        )

        let lateToolActivity = CodexActivitySignal.replace(
            AssistantActivity(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "tool-1",
                kind: .webSearch,
                message: "Searching the web"
            )
        )
        XCTAssertNil(tracker.consume(lateToolActivity))
    }

    func testMcpProgressUsesGenericConnectedInformationLabel() throws {
        let line = Data(
            #"{"method":"item/mcpToolCall/progress","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"tool-1","message":"technical internal progress"}}"#.utf8
        )

        let signal = try CodexJSONRPCActivityParser.parseSignal(from: line)

        XCTAssertEqual(
            signal,
            .replace(
                AssistantActivity(
                    threadID: "thread-1",
                    turnID: "turn-1",
                    itemID: "tool-1",
                    kind: .connectedSource,
                    message: "Checking connected information"
                )
            )
        )
    }
}
