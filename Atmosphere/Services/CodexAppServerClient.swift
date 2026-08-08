import Foundation

// MARK: - View-model-facing values

struct AssistantAccountStatus: Equatable, Sendable {
    struct Account: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case chatGPT
            case apiKey
            case amazonBedrock
            case unknown(String)
        }

        let kind: Kind
        let email: String?
        let planType: String?
    }

    let account: Account?
    let requiresOpenAIAuth: Bool

    /// A non-OpenAI provider may be usable without an OpenAI account.
    var canStartConversation: Bool {
        account != nil || !requiresOpenAIAuth
    }
}

struct CodexLoginChallenge: Equatable, Sendable {
    let loginID: String
    let authenticationURL: URL
}

struct AssistantTurnFailure: Equatable, Sendable {
    let message: String
    let additionalDetails: String?
    let willRetry: Bool
}

enum AssistantTurnStatus: String, Equatable, Sendable {
    case completed
    case interrupted
    case failed
    case inProgress
    case unknown
}

enum AssistantMessagePhase: String, Equatable, Sendable {
    case commentary
    case finalAnswer = "final_answer"
}

enum AssistantConnectionState: Equatable, Sendable {
    case stopped
    case starting
    case ready
    case failed(String)
}

enum AssistantEvent: Equatable, Sendable {
    case connectionStateChanged(AssistantConnectionState)
    case accountChanged(AssistantAccountStatus)
    case accountUpdated(authMode: String?, planType: String?)
    case loginCompleted(loginID: String?, success: Bool, error: String?)
    case threadStarted(threadID: String)
    /// Emitted only after thread/start has returned and the thread is usable.
    case threadReady(threadID: String)
    case turnStarted(threadID: String, turnID: String)
    case assistantMessageStarted(
        threadID: String,
        turnID: String,
        itemID: String,
        phase: AssistantMessagePhase?
    )
    case assistantDelta(threadID: String, turnID: String, itemID: String, delta: String)
    case assistantMessageCompleted(
        threadID: String,
        turnID: String,
        itemID: String,
        text: String,
        phase: AssistantMessagePhase?
    )
    case turnCompleted(
        threadID: String,
        turnID: String,
        status: AssistantTurnStatus,
        failure: AssistantTurnFailure?
    )
    case turnError(threadID: String, turnID: String, failure: AssistantTurnFailure)
}

enum AssistantActivityKind: String, Equatable, Sendable {
    case commentary
    case reasoningSummary
    case planning
    case webSearch
    case connectedSource
    case localContext
    case imageReview
    case contextManagement
    case coordination
    case preparingAnswer
}

/// A concise, user-displayable progress update derived only from documented
/// app-server commentary, reasoning-summary, plan, and tool lifecycle events.
/// Raw reasoning text, commands, arguments, and tool output are never exposed.
struct AssistantActivity: Equatable, Sendable {
    let threadID: String
    let turnID: String
    let itemID: String?
    let kind: AssistantActivityKind
    let message: String
}

enum CodexAppServerError: Error, Equatable, LocalizedError {
    case executableNotFound(searchedPaths: [String])
    case connectionStarting
    case notConnected
    case authenticationRequired
    case turnAlreadyInProgress
    case conversationReplaced
    case emptyMessage
    case invalidResponse(String)
    case requestTimedOut(method: String)
    case requestFailed(code: Int, message: String)
    case processLaunchFailed(String)
    case connectionClosed(exitCode: Int32?, details: String?)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let searchedPaths):
            return "Could not find the official Codex executable. Checked: \(searchedPaths.joined(separator: ", "))."
        case .connectionStarting:
            return "The ChatGPT connection is still starting."
        case .notConnected:
            return "The ChatGPT app server is not connected."
        case .authenticationRequired:
            return "Sign in with ChatGPT before sending a message."
        case .turnAlreadyInProgress:
            return "Wait for the current answer to finish, or cancel it first."
        case .conversationReplaced:
            return "The conversation changed before that request could start."
        case .emptyMessage:
            return "Enter a question before sending."
        case .invalidResponse(let details):
            return "The ChatGPT app server returned an unexpected response: \(details)"
        case .requestTimedOut(let method):
            return "The ChatGPT app server did not answer \(method) in time."
        case .requestFailed(_, let message):
            return message
        case .processLaunchFailed(let details):
            return "Could not start the ChatGPT app server: \(details)"
        case .connectionClosed(let exitCode, let details):
            let status = exitCode.map { " (exit code \($0))" } ?? ""
            let suffix = details.flatMap { $0.isEmpty ? nil : ": \($0)" } ?? ""
            return "The ChatGPT app server closed\(status)\(suffix)."
        }
    }
}

// MARK: - JSON-RPC decoding

typealias JSONObject = [String: Any]

enum JSONRPCID: Equatable {
    case integer(Int)
    case string(String)

    var jsonObject: Any {
        switch self {
        case .integer(let value): return value
        case .string(let value): return value
        }
    }
}

struct JSONRPCErrorPayload: Equatable {
    let code: Int
    let message: String
}

struct JSONRPCEnvelope {
    let id: JSONRPCID?
    let method: String?
    let params: JSONObject?
    let result: Any?
    let error: JSONRPCErrorPayload?

    init(line: Data) throws {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: line)
        } catch {
            throw CodexAppServerError.invalidResponse("invalid JSON (\(error.localizedDescription))")
        }

        guard let object = value as? JSONObject else {
            throw CodexAppServerError.invalidResponse("the top-level value was not an object")
        }

        if let integer = object["id"] as? Int {
            id = .integer(integer)
        } else if let string = object["id"] as? String {
            id = .string(string)
        } else {
            id = nil
        }

        method = object["method"] as? String
        params = object["params"] as? JSONObject
        result = object["result"]

        if let errorObject = object["error"] as? JSONObject,
           let code = errorObject["code"] as? Int,
           let message = errorObject["message"] as? String {
            error = JSONRPCErrorPayload(code: code, message: message)
        } else {
            error = nil
        }
    }

    var resultObject: JSONObject? {
        if result == nil || result is NSNull { return [:] }
        return result as? JSONObject
    }
}

enum CodexJSONRPCEventParser {
    static func parseEvent(from line: Data) throws -> AssistantEvent? {
        event(from: try JSONRPCEnvelope(line: line))
    }

    static func event(from envelope: JSONRPCEnvelope) -> AssistantEvent? {
        guard let method = envelope.method else { return nil }
        let params = envelope.params ?? [:]

        switch method {
        case "account/updated":
            return .accountUpdated(
                authMode: optionalString(params["authMode"]),
                planType: optionalString(params["planType"])
            )

        case "account/login/completed":
            guard let success = params["success"] as? Bool else { return nil }
            return .loginCompleted(
                loginID: optionalString(params["loginId"]),
                success: success,
                error: optionalString(params["error"])
            )

        case "thread/started":
            guard let thread = params["thread"] as? JSONObject,
                  let threadID = thread["id"] as? String else { return nil }
            return .threadStarted(threadID: threadID)

        case "turn/started":
            guard let threadID = params["threadId"] as? String,
                  let turn = params["turn"] as? JSONObject,
                  let turnID = turn["id"] as? String else { return nil }
            return .turnStarted(threadID: threadID, turnID: turnID)

        case "item/started":
            guard let threadID = params["threadId"] as? String,
                  let turnID = params["turnId"] as? String,
                  let item = params["item"] as? JSONObject,
                  item["type"] as? String == "agentMessage",
                  let itemID = item["id"] as? String else { return nil }
            return .assistantMessageStarted(
                threadID: threadID,
                turnID: turnID,
                itemID: itemID,
                phase: messagePhase(item["phase"])
            )

        case "item/agentMessage/delta":
            guard let threadID = params["threadId"] as? String,
                  let turnID = params["turnId"] as? String,
                  let itemID = params["itemId"] as? String,
                  let delta = params["delta"] as? String else { return nil }
            return .assistantDelta(
                threadID: threadID,
                turnID: turnID,
                itemID: itemID,
                delta: delta
            )

        case "item/completed":
            guard let threadID = params["threadId"] as? String,
                  let turnID = params["turnId"] as? String,
                  let item = params["item"] as? JSONObject,
                  item["type"] as? String == "agentMessage",
                  let itemID = item["id"] as? String,
                  let text = item["text"] as? String else { return nil }
            return .assistantMessageCompleted(
                threadID: threadID,
                turnID: turnID,
                itemID: itemID,
                text: text,
                phase: messagePhase(item["phase"])
            )

        case "turn/completed":
            guard let threadID = params["threadId"] as? String,
                  let turn = params["turn"] as? JSONObject,
                  let turnID = turn["id"] as? String else { return nil }

            let status = turnStatus(turn["status"] as? String)
            let failure = failure(from: turn["error"] as? JSONObject, willRetry: false)
            return .turnCompleted(
                threadID: threadID,
                turnID: turnID,
                status: status,
                failure: failure
            )

        case "error":
            guard let threadID = params["threadId"] as? String,
                  let turnID = params["turnId"] as? String,
                  let error = params["error"] as? JSONObject,
                  let failure = failure(
                    from: error,
                    willRetry: params["willRetry"] as? Bool ?? false
                  ) else { return nil }
            return .turnError(threadID: threadID, turnID: turnID, failure: failure)

        default:
            return nil
        }
    }

    private static func optionalString(_ value: Any?) -> String? {
        value is NSNull ? nil : value as? String
    }

    private static func turnStatus(_ rawValue: String?) -> AssistantTurnStatus {
        rawValue.flatMap(AssistantTurnStatus.init(rawValue:)) ?? .unknown
    }

    private static func messagePhase(_ value: Any?) -> AssistantMessagePhase? {
        guard !(value is NSNull), let rawValue = value as? String else { return nil }
        return AssistantMessagePhase(rawValue: rawValue)
    }

    private static func failure(from object: JSONObject?, willRetry: Bool) -> AssistantTurnFailure? {
        guard let object,
              let message = object["message"] as? String else { return nil }
        return AssistantTurnFailure(
            message: message,
            additionalDetails: optionalString(object["additionalDetails"]),
            willRetry: willRetry
        )
    }
}

// MARK: - User-readable activity decoding

enum CodexActivitySignal: Equatable, Sendable {
    case replace(AssistantActivity)
    case reasoningSummaryDelta(
        threadID: String,
        turnID: String,
        itemID: String,
        summaryIndex: Int,
        delta: String
    )
}

enum CodexJSONRPCActivityParser {
    static func parseSignal(from line: Data) throws -> CodexActivitySignal? {
        signal(from: try JSONRPCEnvelope(line: line))
    }

    static func signal(from envelope: JSONRPCEnvelope) -> CodexActivitySignal? {
        guard let method = envelope.method else { return nil }
        let params = envelope.params ?? [:]

        switch method {
        case "turn/plan/updated":
            guard let threadID = params["threadId"] as? String,
                  let turnID = params["turnId"] as? String else { return nil }
            let plan = (params["plan"] as? [Any])?.compactMap { $0 as? JSONObject } ?? []
            let activeStep = plan.first { $0["status"] as? String == "inProgress" }
                ?? plan.first { $0["status"] as? String == "pending" }
            let rawMessage = activeStep?["step"] as? String
                ?? params["explanation"] as? String
                ?? "Planning the response"
            return replacement(
                threadID: threadID,
                turnID: turnID,
                itemID: nil,
                kind: .planning,
                message: rawMessage
            )

        case "item/started":
            guard let threadID = params["threadId"] as? String,
                  let turnID = params["turnId"] as? String,
                  let item = params["item"] as? JSONObject,
                  let itemID = item["id"] as? String,
                  let itemType = item["type"] as? String else { return nil }
            return startedItemSignal(
                threadID: threadID,
                turnID: turnID,
                itemID: itemID,
                itemType: itemType
            )

        case "item/completed":
            guard let threadID = params["threadId"] as? String,
                  let turnID = params["turnId"] as? String,
                  let item = params["item"] as? JSONObject,
                  let itemID = item["id"] as? String,
                  let itemType = item["type"] as? String,
                  isActivityItemType(itemType) else { return nil }
            return replacement(
                threadID: threadID,
                turnID: turnID,
                itemID: itemID,
                kind: .preparingAnswer,
                message: "Preparing the answer"
            )

        case "item/mcpToolCall/progress":
            guard let threadID = params["threadId"] as? String,
                  let turnID = params["turnId"] as? String,
                  let itemID = params["itemId"] as? String else { return nil }
            return replacement(
                threadID: threadID,
                turnID: turnID,
                itemID: itemID,
                kind: .connectedSource,
                message: "Checking connected information"
            )

        case "item/reasoning/summaryTextDelta":
            guard let threadID = params["threadId"] as? String,
                  let turnID = params["turnId"] as? String,
                  let itemID = params["itemId"] as? String,
                  let summaryIndex = params["summaryIndex"] as? Int,
                  let delta = params["delta"] as? String,
                  !delta.isEmpty else { return nil }
            return .reasoningSummaryDelta(
                threadID: threadID,
                turnID: turnID,
                itemID: itemID,
                summaryIndex: summaryIndex,
                delta: delta
            )

        case "model/safetyBuffering/updated":
            guard params["showBufferingUi"] as? Bool == true,
                  let threadID = params["threadId"] as? String,
                  let turnID = params["turnId"] as? String else { return nil }
            return replacement(
                threadID: threadID,
                turnID: turnID,
                itemID: nil,
                kind: .preparingAnswer,
                message: "Preparing the response"
            )

        default:
            // In particular, never surface item/reasoning/textDelta.
            return nil
        }
    }

    private static func startedItemSignal(
        threadID: String,
        turnID: String,
        itemID: String,
        itemType: String
    ) -> CodexActivitySignal? {
        let kind: AssistantActivityKind
        let message: String

        switch itemType {
        case "reasoning":
            kind = .reasoningSummary
            message = "Thinking through the question"
        case "commandExecution":
            kind = .localContext
            message = "Checking local context"
        case "mcpToolCall", "dynamicToolCall":
            kind = .connectedSource
            message = "Checking connected information"
        case "webSearch":
            kind = .webSearch
            message = "Searching the web"
        case "imageView":
            kind = .imageReview
            message = "Reviewing the screenshot"
        case "contextCompaction":
            kind = .contextManagement
            message = "Organizing the conversation"
        case "collabAgentToolCall", "subAgentActivity":
            kind = .coordination
            message = "Coordinating work"
        default:
            return nil
        }

        return replacement(
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            kind: kind,
            message: message
        )
    }

    private static func isActivityItemType(_ itemType: String) -> Bool {
        switch itemType {
        case "reasoning", "commandExecution", "mcpToolCall", "dynamicToolCall",
             "webSearch", "imageView", "contextCompaction", "collabAgentToolCall",
             "subAgentActivity":
            return true
        default:
            return false
        }
    }

    private static func replacement(
        threadID: String,
        turnID: String,
        itemID: String?,
        kind: AssistantActivityKind,
        message: String
    ) -> CodexActivitySignal? {
        guard let message = CodexActivityText.displayable(message) else { return nil }
        return .replace(
            AssistantActivity(
                threadID: threadID,
                turnID: turnID,
                itemID: itemID,
                kind: kind,
                message: message
            )
        )
    }
}

private enum CodexActivityText {
    static func displayable(_ text: String, limit: Int = 180) -> String? {
        let normalized = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit - 1)) + "…"
    }
}

struct AssistantActivityTracker {
    private struct ItemKey: Hashable {
        let turnID: String
        let itemID: String
    }

    private struct SummaryKey: Hashable {
        let turnID: String
        let itemID: String
        let summaryIndex: Int
    }

    private var finalAnswerTurnIDs = Set<String>()
    private var commentaryItemIDs = Set<ItemKey>()
    private var commentaryText: [ItemKey: String] = [:]
    private var reasoningSummaryText: [SummaryKey: String] = [:]

    mutating func consume(_ event: AssistantEvent) -> AssistantActivity? {
        switch event {
        case .assistantMessageStarted(let threadID, let turnID, let itemID, let phase):
            let key = ItemKey(turnID: turnID, itemID: itemID)
            if phase == .commentary {
                commentaryItemIDs.insert(key)
                guard !finalAnswerTurnIDs.contains(turnID) else { return nil }
                return AssistantActivity(
                    threadID: threadID,
                    turnID: turnID,
                    itemID: itemID,
                    kind: .commentary,
                    message: "Working through the question"
                )
            }
            finalAnswerTurnIDs.insert(turnID)
            clearIntermediateText(for: turnID)
            return nil

        case .assistantDelta(let threadID, let turnID, let itemID, let delta):
            let key = ItemKey(turnID: turnID, itemID: itemID)
            guard commentaryItemIDs.contains(key),
                  !finalAnswerTurnIDs.contains(turnID) else { return nil }
            commentaryText[key, default: ""] += delta
            guard let message = CodexActivityText.displayable(commentaryText[key] ?? "") else {
                return nil
            }
            return AssistantActivity(
                threadID: threadID,
                turnID: turnID,
                itemID: itemID,
                kind: .commentary,
                message: message
            )

        case .assistantMessageCompleted(
            let threadID,
            let turnID,
            let itemID,
            let text,
            let phase
        ):
            let key = ItemKey(turnID: turnID, itemID: itemID)
            let isCommentary = phase == .commentary || commentaryItemIDs.contains(key)
            commentaryItemIDs.remove(key)
            commentaryText.removeValue(forKey: key)
            if isCommentary, !finalAnswerTurnIDs.contains(turnID),
               let message = CodexActivityText.displayable(text) {
                return AssistantActivity(
                    threadID: threadID,
                    turnID: turnID,
                    itemID: itemID,
                    kind: .commentary,
                    message: message
                )
            }
            if !isCommentary {
                finalAnswerTurnIDs.insert(turnID)
                clearIntermediateText(for: turnID)
            }
            return nil

        case .turnCompleted(_, let turnID, _, _):
            clearIntermediateText(for: turnID)
            finalAnswerTurnIDs.remove(turnID)
            return nil

        default:
            return nil
        }
    }

    mutating func consume(_ signal: CodexActivitySignal) -> AssistantActivity? {
        switch signal {
        case .replace(let activity):
            guard !finalAnswerTurnIDs.contains(activity.turnID) else { return nil }
            return activity

        case .reasoningSummaryDelta(
            let threadID,
            let turnID,
            let itemID,
            let summaryIndex,
            let delta
        ):
            guard !finalAnswerTurnIDs.contains(turnID) else { return nil }
            let key = SummaryKey(
                turnID: turnID,
                itemID: itemID,
                summaryIndex: summaryIndex
            )
            let combined = (reasoningSummaryText[key] ?? "") + delta
            reasoningSummaryText[key] = String(combined.prefix(2_048))
            guard let message = CodexActivityText.displayable(
                reasoningSummaryText[key] ?? ""
            ) else { return nil }
            return AssistantActivity(
                threadID: threadID,
                turnID: turnID,
                itemID: itemID,
                kind: .reasoningSummary,
                message: message
            )
        }
    }

    mutating func reset() {
        finalAnswerTurnIDs.removeAll()
        commentaryItemIDs.removeAll()
        commentaryText.removeAll()
        reasoningSummaryText.removeAll()
    }

    private mutating func clearIntermediateText(for turnID: String) {
        commentaryItemIDs = commentaryItemIDs.filter { $0.turnID != turnID }
        commentaryText = commentaryText.filter { $0.key.turnID != turnID }
        reasoningSummaryText = reasoningSummaryText.filter { $0.key.turnID != turnID }
    }
}

enum CodexAppServerRequestBuilder {
    static let model = "gpt-5.6-luna"
    static let effort = "medium"
    static let reasoningSummary = "concise"

    static func threadStartParameters(
        workingDirectory: URL,
        developerInstructions: String
    ) -> JSONObject {
        [
            "ephemeral": true,
            "cwd": workingDirectory.path,
            "sandbox": "read-only",
            "approvalPolicy": "never",
            "developerInstructions": developerInstructions,
            "model": model,
            "config": [
                "model_reasoning_effort": effort,
                "model_reasoning_summary": reasoningSummary,
                "allow_login_shell": false,
                "web_search": "disabled",
                "agents": ["enabled": false],
                "apps": ["_default": ["enabled": false]],
                "features": [
                    "apps": false,
                    "plugins": false,
                "plugin_sharing": false,
                "multi_agent": false,
                "remote_plugin": false,
                "code_mode": false,
                "code_mode_host": false,
                "code_mode_only": false,
                "goals": false,
                    "hooks": false,
                    "skill_search": false,
                    "tool_suggest": false,
                    "browser_use": false,
                    "browser_use_external": false,
                    "browser_use_full_cdp_access": false,
                    "in_app_browser": false,
                    "computer_use": false
                ]
            ]
        ]
    }

    static func turnStartParameters(
        threadID: String,
        userInput: [JSONObject],
        workingDirectory: URL
    ) -> JSONObject {
        [
            "threadId": threadID,
            "input": userInput,
            "cwd": workingDirectory.path,
            "approvalPolicy": "never",
            "sandboxPolicy": [
                "type": "readOnly",
                "networkAccess": false
            ],
            "model": model,
            "effort": effort,
            "summary": reasoningSummary
        ]
    }
}

enum CodexAppServerLaunchConfiguration {
    /// Defense-in-depth process overrides for Atmosphere's isolated Codex home.
    /// The isolated home is what prevents inherited MCP/plugin configuration;
    /// these flags also keep optional first-party tool surfaces unavailable.
    static let overrides = [
        "allow_login_shell=false",
        "web_search=\"disabled\"",
        "agents.enabled=false",
        "apps._default.enabled=false",
        "features.apps=false",
        "features.plugins=false",
        "features.plugin_sharing=false",
        "features.multi_agent=false",
        "features.remote_plugin=false",
        "features.code_mode=false",
        "features.code_mode_host=false",
        "features.code_mode_only=false",
        "features.goals=false",
        "features.hooks=false",
        "features.skill_search=false",
        "features.tool_suggest=false",
        "features.browser_use=false",
        "features.browser_use_external=false",
        "features.browser_use_full_cdp_access=false",
        "features.in_app_browser=false",
        "features.computer_use=false",
        "mcp_servers={}"
    ]

    static var arguments: [String] {
        overrides.flatMap { ["-c", $0] } + ["app-server", "--stdio"]
    }
}

// MARK: - App-server process client

actor CodexAppServerClient {
    struct Configuration: Sendable {
        var clientName = "atmosphere_macos"
        var clientTitle = "Atmosphere"
        var clientVersion: String
        var requestTimeout: TimeInterval = 30

        init(
            clientVersion: String = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "0.1.0"
        ) {
            self.clientVersion = clientVersion
        }
    }

    static let executableOverrideDefaultsKey = "AtmosphereCodexExecutablePath"

    nonisolated let events: AsyncStream<AssistantEvent>
    nonisolated let activityEvents: AsyncStream<AssistantActivity>

    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<JSONObject, Error>
        let timeoutTask: Task<Void, Never>
    }

    private static let generalAssistantInstructions = """
    You are Atmosphere, a concise general-purpose assistant in a small macOS overlay. Answer the user's question directly in plain language. Prefer short, self-contained answers unless the user asks for more detail. When it is relevant to the question, you may inspect files and directories inside the operating folder with safe read-only tools or commands. Never create, edit, delete, move, or rename files; never change systems or take external actions. Do not use GUI automation, Computer Use, browser-control tools, connected apps, plugins, or subagents. Say when current information cannot be verified.
    """

    private let configuration: Configuration
    private let eventContinuation: AsyncStream<AssistantEvent>.Continuation
    private let activityContinuation: AsyncStream<AssistantActivity>.Continuation

    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var outputChunkContinuation: AsyncStream<Data>.Continuation?
    private var errorChunkContinuation: AsyncStream<Data>.Continuation?
    private var outputReadTask: Task<Void, Never>?
    private var errorReadTask: Task<Void, Never>?
    private var connectionGeneration: UUID?
    private var stdoutDecoder = JSONLineDecoder()
    private var recentStandardError = Data()

    private var pendingRequests: [Int: PendingRequest] = [:]
    private var nextRequestID = 1

    private var isInitialized = false
    private var isStarting = false
    private var isStartingThread = false
    private var isStartingTurn = false
    private var isResettingConversation = false
    private var isRefreshingAccount = false
    private var conversationGeneration: UInt64 = 0
    private var accountStatus: AssistantAccountStatus?
    private var threadID: String?
    private var activeTurnID: String?
    private var completedTurnIDs = Set<String>()
    private var activeLoginID: String?
    private var activityTracker = AssistantActivityTracker()
    private var preferredWorkingDirectory: URL?

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration

        var continuation: AsyncStream<AssistantEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(1_024)) {
            continuation = $0
        }
        eventContinuation = continuation

        var activityContinuation: AsyncStream<AssistantActivity>.Continuation!
        activityEvents = AsyncStream(bufferingPolicy: .bufferingNewest(1_024)) {
            activityContinuation = $0
        }
        self.activityContinuation = activityContinuation
    }

    deinit {
        eventContinuation.finish()
        activityContinuation.finish()
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        outputChunkContinuation?.finish()
        errorChunkContinuation?.finish()
        outputReadTask?.cancel()
        errorReadTask?.cancel()
        process?.terminate()
    }

    /// Sets the directory used by subsequent thread and turn requests. The
    /// caller resets the conversation immediately after changing this value so
    /// a single app-server thread never spans two working directories.
    func setWorkingDirectory(_ directory: URL?) {
        preferredWorkingDirectory = directory?.standardizedFileURL
    }

    /// Starts a private official `codex app-server` using the user's existing
    /// Codex/ChatGPT credentials, performs the required handshake, reads the
    /// account, and creates an in-memory read-only conversation when possible.
    @discardableResult
    func start() async throws -> AssistantAccountStatus {
        if isInitialized {
            let status: AssistantAccountStatus
            if let accountStatus {
                status = accountStatus
            } else {
                status = try await readAccount()
            }

            // A recoverable account refresh failure leaves the private app
            // server running. Re-announce its usable thread on Retry so the UI
            // cannot remain connected while still lacking a send target.
            if status.canStartConversation {
                let readyThreadID = try await ensureThread()
                eventContinuation.yield(.threadReady(threadID: readyThreadID))
            }
            eventContinuation.yield(.connectionStateChanged(.ready))
            return status
        }
        guard !isStarting else { throw CodexAppServerError.connectionStarting }

        isStarting = true
        eventContinuation.yield(.connectionStateChanged(.starting))

        var startupGeneration: UUID?
        do {
            try spawnProcess()
            startupGeneration = connectionGeneration
            guard let startupGeneration else {
                throw CodexAppServerError.processLaunchFailed("missing connection generation")
            }

            _ = try await request(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": configuration.clientName,
                        "title": configuration.clientTitle,
                        "version": configuration.clientVersion
                    ],
                    "capabilities": [
                        "experimentalApi": false,
                        "mcpServerOpenaiFormElicitation": false
                    ]
                ]
            )
            guard connectionGeneration == startupGeneration else {
                throw CodexAppServerError.connectionClosed(exitCode: nil, details: nil)
            }
            try sendNotification(method: "initialized")
            isInitialized = true

            let status = try await readAccount()
            if status.canStartConversation {
                _ = try await ensureThread()
            }
            guard connectionGeneration == startupGeneration else {
                throw CodexAppServerError.connectionClosed(exitCode: nil, details: nil)
            }

            isStarting = false
            eventContinuation.yield(.connectionStateChanged(.ready))
            return status
        } catch {
            // A stopped startup may resume after a newer connection has begun.
            // Only the generation that failed is allowed to tear itself down.
            if startupGeneration == nil || connectionGeneration == startupGeneration {
                isStarting = false
                failConnection(error)
            }
            throw error
        }
    }

    @discardableResult
    func readAccount(refreshToken: Bool = false) async throws -> AssistantAccountStatus {
        guard isInitialized else { throw CodexAppServerError.notConnected }
        let result = try await request(
            method: "account/read",
            params: ["refreshToken": refreshToken]
        )
        let status = try Self.parseAccountStatus(result)
        accountStatus = status
        if !status.canStartConversation {
            conversationGeneration &+= 1
            threadID = nil
            activeTurnID = nil
            completedTurnIDs.removeAll()
        }
        eventContinuation.yield(.accountChanged(status))
        return status
    }

    /// Starts Codex-managed ChatGPT OAuth. The caller should open the returned
    /// URL with `NSWorkspace`; the app server owns the localhost callback and
    /// emits `loginCompleted` when the browser flow finishes.
    func startManagedChatGPTLogin() async throws -> CodexLoginChallenge {
        if !isInitialized {
            _ = try await start()
        }

        let result = try await request(
            method: "account/login/start",
            params: [
                "type": "chatgpt",
                "useHostedLoginSuccessPage": true,
                "appBrand": "chatgpt"
            ]
        )

        guard let loginID = result["loginId"] as? String,
              let rawURL = result["authUrl"] as? String,
              let url = URL(string: rawURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw CodexAppServerError.invalidResponse("login/start omitted loginId or authUrl")
        }

        activeLoginID = loginID
        return CodexLoginChallenge(loginID: loginID, authenticationURL: url)
    }

    func cancelLogin() async throws {
        guard let loginID = activeLoginID else { return }
        _ = try await request(
            method: "account/login/cancel",
            params: ["loginId": loginID]
        )
        if activeLoginID == loginID {
            activeLoginID = nil
        }
    }

    /// Sends text and/or local image context and returns the server-assigned
    /// turn id. Answer text arrives incrementally on `events` as
    /// `assistantDelta` values.
    @discardableResult
    func send(_ text: String, localImages: [URL] = []) async throws -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty || !localImages.isEmpty else {
            throw CodexAppServerError.emptyMessage
        }

        var userInput: [JSONObject] = []
        if !trimmedText.isEmpty {
            userInput.append(["type": "text", "text": trimmedText])
        }
        for imageURL in localImages {
            guard imageURL.isFileURL else {
                throw CodexAppServerError.invalidResponse(
                    "a screenshot attachment was not a local file"
                )
            }
            let standardizedURL = imageURL.standardizedFileURL
            guard FileManager.default.fileExists(atPath: standardizedURL.path) else {
                throw CodexAppServerError.invalidResponse(
                    "a screenshot attachment no longer exists"
                )
            }
            userInput.append([
                "type": "localImage",
                "path": standardizedURL.path
            ])
        }

        if !isInitialized {
            _ = try await start()
        }
        guard accountStatus?.canStartConversation == true else {
            throw CodexAppServerError.authenticationRequired
        }
        guard !isResettingConversation else {
            throw CodexAppServerError.connectionStarting
        }
        guard activeTurnID == nil, !isStartingTurn else {
            throw CodexAppServerError.turnAlreadyInProgress
        }

        let threadID = try await ensureThread()
        guard !isResettingConversation else {
            throw CodexAppServerError.conversationReplaced
        }
        let turnGeneration = conversationGeneration
        let workingDirectory = try conversationWorkingDirectory()
        isStartingTurn = true
        defer { isStartingTurn = false }

        let result = try await request(
            method: "turn/start",
            params: CodexAppServerRequestBuilder.turnStartParameters(
                threadID: threadID,
                userInput: userInput,
                workingDirectory: workingDirectory
            )
        )

        guard let turn = result["turn"] as? JSONObject,
              let turnID = turn["id"] as? String else {
            throw CodexAppServerError.invalidResponse("turn/start omitted turn.id")
        }

        guard conversationGeneration == turnGeneration,
              self.threadID == threadID,
              !isResettingConversation else {
            completedTurnIDs.remove(turnID)
            _ = try? await request(
                method: "turn/interrupt",
                params: ["threadId": threadID, "turnId": turnID]
            )
            throw CodexAppServerError.conversationReplaced
        }

        // The response and a very short completed turn can arrive in one pipe
        // read. The actor handles all of those lines before this await resumes.
        if completedTurnIDs.remove(turnID) == nil {
            activeTurnID = turnID
        }
        return turnID
    }

    /// Requests cancellation without killing the shared conversation context.
    @discardableResult
    func cancelCurrentTurn() async throws -> Bool {
        while isStartingTurn, activeTurnID == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let threadID, let turnID = activeTurnID else { return false }
        _ = try await request(
            method: "turn/interrupt",
            params: ["threadId": threadID, "turnId": turnID]
        )
        return true
    }

    /// Drops the current ephemeral context and starts another isolated thread.
    @discardableResult
    func resetConversation() async throws -> String? {
        guard !isStarting, !isStartingThread, !isResettingConversation else {
            throw CodexAppServerError.connectionStarting
        }

        isResettingConversation = true
        defer { isResettingConversation = false }

        let oldThreadID = threadID
        let oldTurnID = activeTurnID
        conversationGeneration &+= 1
        threadID = nil
        activeTurnID = nil
        completedTurnIDs.removeAll()

        // If turn/start is currently suspended, changing the generation makes
        // it interrupt its newly-created stale turn before returning.
        while isStartingTurn {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        if let oldThreadID, let oldTurnID {
            _ = try? await request(
                method: "turn/interrupt",
                params: ["threadId": oldThreadID, "turnId": oldTurnID]
            )
        }

        guard isInitialized, accountStatus?.canStartConversation == true else {
            return nil
        }

        return try await ensureThread()
    }

    /// Stops the child process and fails any outstanding requests. A later
    /// `start()` call creates a fresh connection and event stream continues.
    func stop() {
        let oldProcess = process
        let oldOutputHandle = outputHandle
        let oldErrorHandle = errorHandle
        let oldOutputReadTask = outputReadTask
        let oldErrorReadTask = errorReadTask
        connectionGeneration = nil

        oldOutputHandle?.readabilityHandler = nil
        oldErrorHandle?.readabilityHandler = nil
        outputChunkContinuation?.finish()
        errorChunkContinuation?.finish()
        oldOutputReadTask?.cancel()
        oldErrorReadTask?.cancel()
        try? inputHandle?.close()
        try? oldOutputHandle?.close()
        try? oldErrorHandle?.close()

        process = nil
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        outputChunkContinuation = nil
        errorChunkContinuation = nil
        outputReadTask = nil
        errorReadTask = nil
        isInitialized = false
        isStarting = false
        isStartingThread = false
        isStartingTurn = false
        isResettingConversation = false
        isRefreshingAccount = false
        conversationGeneration &+= 1
        accountStatus = nil
        threadID = nil
        activeTurnID = nil
        completedTurnIDs.removeAll()
        activeLoginID = nil
        activityTracker.reset()
        stdoutDecoder = JSONLineDecoder()

        failPendingRequests(with: CodexAppServerError.connectionClosed(exitCode: nil, details: nil))
        if oldProcess?.isRunning == true {
            oldProcess?.terminate()
        }
        eventContinuation.yield(.connectionStateChanged(.stopped))
    }

    // MARK: Executable discovery

    static func discoverExecutableURL(
        userDefaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> URL {
        var paths: [String] = []

        if let override = userDefaults.string(forKey: executableOverrideDefaultsKey),
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            paths.append((override as NSString).expandingTildeInPath)
        }

        paths.append("/Applications/ChatGPT.app/Contents/Resources/codex")

        if let path = environment["PATH"] {
            paths.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("codex").path
            })
        }

        paths.append(contentsOf: [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex",
            ("~/.local/bin/codex" as NSString).expandingTildeInPath,
            ("~/.codex/bin/codex" as NSString).expandingTildeInPath
        ])

        var seen = Set<String>()
        let uniquePaths = paths.filter { seen.insert($0).inserted }

        for path in uniquePaths where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path).standardizedFileURL
        }

        throw CodexAppServerError.executableNotFound(searchedPaths: uniquePaths)
    }

    // MARK: Process and request plumbing

    private func spawnProcess() throws {
        let executableURL = try Self.discoverExecutableURL()
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let generation = UUID()

        process.executableURL = executableURL
        process.arguments = CodexAppServerLaunchConfiguration.arguments
        do {
            process.environment = try CodexHomeIsolation().processEnvironment()
        } catch {
            throw CodexAppServerError.processLaunchFailed(error.localizedDescription)
        }
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading

        let (outputChunks, outputContinuation) = AsyncStream<Data>.makeStream()
        let (errorChunks, errorContinuation) = AsyncStream<Data>.makeStream()

        outputHandle.readabilityHandler = { handle in
            let data = handle.availableData
            outputContinuation.yield(data)
            if data.isEmpty { outputContinuation.finish() }
        }
        errorHandle.readabilityHandler = { handle in
            let data = handle.availableData
            errorContinuation.yield(data)
            if data.isEmpty { errorContinuation.finish() }
        }

        process.terminationHandler = { [weak self] process in
            Task {
                await self?.processDidTerminate(
                    generation: generation,
                    exitCode: process.terminationStatus
                )
            }
        }

        do {
            try process.run()
        } catch {
            outputHandle.readabilityHandler = nil
            errorHandle.readabilityHandler = nil
            outputContinuation.finish()
            errorContinuation.finish()
            throw CodexAppServerError.processLaunchFailed(error.localizedDescription)
        }

        self.process = process
        inputHandle = inputPipe.fileHandleForWriting
        self.outputHandle = outputHandle
        self.errorHandle = errorHandle
        outputChunkContinuation = outputContinuation
        errorChunkContinuation = errorContinuation
        connectionGeneration = generation
        stdoutDecoder = JSONLineDecoder()
        recentStandardError.removeAll(keepingCapacity: false)

        // One reader task per pipe preserves byte order. Spawning a new Task
        // from every readability callback can reorder chunks before the actor
        // sees them and corrupt newline-delimited JSON framing.
        outputReadTask = Task.detached(priority: .userInitiated) { [weak self] in
            for await data in outputChunks {
                guard !Task.isCancelled else { break }
                await self?.receiveStandardOutput(data, generation: generation)
            }
        }
        errorReadTask = Task.detached(priority: .utility) { [weak self] in
            for await data in errorChunks {
                guard !Task.isCancelled else { break }
                await self?.receiveStandardError(data, generation: generation)
            }
        }
    }

    private func request(method: String, params: JSONObject = [:]) async throws -> JSONObject {
        guard process?.isRunning == true, inputHandle != nil else {
            throw CodexAppServerError.notConnected
        }

        let requestID = nextRequestID
        nextRequestID += 1

        return try await withCheckedThrowingContinuation { continuation in
            let timeoutNanoseconds = UInt64(
                max(1, min(configuration.requestTimeout, 3_600)) * 1_000_000_000
            )
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard !Task.isCancelled else { return }
                await self?.requestDidTimeOut(id: requestID)
            }

            pendingRequests[requestID] = PendingRequest(
                method: method,
                continuation: continuation,
                timeoutTask: timeoutTask
            )

            do {
                try writeJSON(["id": requestID, "method": method, "params": params])
            } catch {
                if let pending = pendingRequests.removeValue(forKey: requestID) {
                    pending.timeoutTask.cancel()
                    pending.continuation.resume(throwing: error)
                }
            }
        }
    }

    private func sendNotification(method: String, params: JSONObject? = nil) throws {
        var object: JSONObject = ["method": method]
        if let params { object["params"] = params }
        try writeJSON(object)
    }

    private func writeJSON(_ object: JSONObject) throws {
        guard let inputHandle, process?.isRunning == true else {
            throw CodexAppServerError.notConnected
        }
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CodexAppServerError.invalidResponse("attempted to send invalid JSON")
        }

        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try inputHandle.write(contentsOf: data)
    }

    private func receiveStandardOutput(_ data: Data, generation: UUID) {
        guard connectionGeneration == generation else { return }

        if data.isEmpty {
            if let trailingLine = try? stdoutDecoder.finish() {
                handle(line: trailingLine)
            }
            return
        }

        do {
            let lines = try stdoutDecoder.append(data)
            for line in lines {
                handle(line: line)
            }
        } catch {
            failConnection(error)
        }
    }

    private func receiveStandardError(_ data: Data, generation: UUID) {
        guard connectionGeneration == generation else { return }
        if data.isEmpty {
            return
        }

        recentStandardError.append(data)
        let maximumRetainedBytes = 16 * 1_024
        if recentStandardError.count > maximumRetainedBytes {
            recentStandardError.removeFirst(recentStandardError.count - maximumRetainedBytes)
        }
    }

    private func handle(line: Data) {
        do {
            let envelope = try JSONRPCEnvelope(line: line)

            if envelope.method == nil, case .integer(let id) = envelope.id {
                completeRequest(id: id, envelope: envelope)
                return
            }

            if let method = envelope.method, let id = envelope.id {
                rejectUnsupportedServerRequest(id: id, method: method)
                return
            }

            if let event = CodexJSONRPCEventParser.event(from: envelope) {
                if let activity = activityTracker.consume(event) {
                    activityContinuation.yield(activity)
                }
                apply(event)
                eventContinuation.yield(event)
            }

            if let signal = CodexJSONRPCActivityParser.signal(from: envelope),
               let activity = activityTracker.consume(signal) {
                activityContinuation.yield(activity)
            }
        } catch {
            failConnection(error)
        }
    }

    private func completeRequest(id: Int, envelope: JSONRPCEnvelope) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        pending.timeoutTask.cancel()

        if let error = envelope.error {
            pending.continuation.resume(
                throwing: CodexAppServerError.requestFailed(
                    code: error.code,
                    message: error.message
                )
            )
            return
        }

        guard let result = envelope.resultObject else {
            pending.continuation.resume(
                throwing: CodexAppServerError.invalidResponse(
                    "\(pending.method) returned a non-object result"
                )
            )
            return
        }
        pending.continuation.resume(returning: result)
    }

    private func rejectUnsupportedServerRequest(id: JSONRPCID, method: String) {
        try? writeJSON([
            "id": id.jsonObject,
            "error": [
                "code": -32_601,
                "message": "Atmosphere does not support server request \(method)."
            ]
        ])
    }

    private func requestDidTimeOut(id: Int) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(
            throwing: CodexAppServerError.requestTimedOut(method: pending.method)
        )
    }

    private func processDidTerminate(generation: UUID, exitCode: Int32) {
        guard connectionGeneration == generation else { return }

        let details = String(data: recentStandardError, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let error = CodexAppServerError.connectionClosed(
            exitCode: exitCode,
            details: details
        )

        connectionGeneration = nil
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        outputChunkContinuation?.finish()
        errorChunkContinuation?.finish()
        outputReadTask?.cancel()
        errorReadTask?.cancel()
        try? inputHandle?.close()
        try? outputHandle?.close()
        try? errorHandle?.close()

        process = nil
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        outputChunkContinuation = nil
        errorChunkContinuation = nil
        outputReadTask = nil
        errorReadTask = nil
        isInitialized = false
        isStarting = false
        isStartingThread = false
        isStartingTurn = false
        isResettingConversation = false
        isRefreshingAccount = false
        conversationGeneration &+= 1
        accountStatus = nil
        threadID = nil
        activeTurnID = nil
        completedTurnIDs.removeAll()
        activeLoginID = nil
        activityTracker.reset()
        failPendingRequests(with: error)
        eventContinuation.yield(.connectionStateChanged(.failed(error.localizedDescription)))
    }

    private func failConnection(_ error: Error) {
        let message = error.localizedDescription
        let oldProcess = process

        connectionGeneration = nil
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        outputChunkContinuation?.finish()
        errorChunkContinuation?.finish()
        outputReadTask?.cancel()
        errorReadTask?.cancel()
        try? inputHandle?.close()
        try? outputHandle?.close()
        try? errorHandle?.close()

        process = nil
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        outputChunkContinuation = nil
        errorChunkContinuation = nil
        outputReadTask = nil
        errorReadTask = nil
        isInitialized = false
        isStarting = false
        isStartingThread = false
        isStartingTurn = false
        isResettingConversation = false
        isRefreshingAccount = false
        conversationGeneration &+= 1
        accountStatus = nil
        threadID = nil
        activeTurnID = nil
        completedTurnIDs.removeAll()
        activeLoginID = nil
        activityTracker.reset()

        failPendingRequests(with: error)
        if oldProcess?.isRunning == true {
            oldProcess?.terminate()
        }
        eventContinuation.yield(.connectionStateChanged(.failed(message)))
    }

    private func failPendingRequests(with error: Error) {
        let pending = pendingRequests.values
        pendingRequests.removeAll()
        for request in pending {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func apply(_ event: AssistantEvent) {
        switch event {
        case .threadStarted:
            // thread/start's response is authoritative. A delayed notification
            // from an abandoned generation must never select the active thread.
            break

        case .turnStarted(let eventThreadID, let turnID):
            if !isResettingConversation, threadID == eventThreadID {
                activeTurnID = turnID
            }

        case .turnCompleted(let eventThreadID, let turnID, _, _):
            // Preserve the id only for the narrow case where completion arrives
            // in the same pipe read as the still-suspended turn/start response.
            // Normal completions must not accumulate in this set forever.
            if threadID == eventThreadID {
                if isStartingTurn {
                    completedTurnIDs.insert(turnID)
                } else {
                    completedTurnIDs.remove(turnID)
                }
                if activeTurnID == turnID {
                    activeTurnID = nil
                }
            }

        case .loginCompleted(let loginID, let success, _):
            if loginID == nil || loginID == activeLoginID {
                activeLoginID = nil
            }
            if success {
                Task { [weak self] in
                    await self?.refreshAccountAndThread(refreshToken: true)
                }
            }

        case .accountUpdated:
            Task { [weak self] in
                await self?.refreshAccountAndThread(refreshToken: false)
            }

        default:
            break
        }
    }

    private func refreshAccountAndThread(refreshToken: Bool) async {
        guard !isStarting, !isRefreshingAccount else { return }
        isRefreshingAccount = true
        defer { isRefreshingAccount = false }
        let refreshGeneration = connectionGeneration

        do {
            let status = try await readAccount(refreshToken: refreshToken)
            if status.canStartConversation {
                _ = try await ensureThread()
            }
        } catch {
            if connectionGeneration == refreshGeneration {
                emitFailure(error)
            }
        }
    }

    private func emitFailure(_ error: Error) {
        eventContinuation.yield(
            .connectionStateChanged(.failed(error.localizedDescription))
        )
    }

    private func ensureThread() async throws -> String {
        if let threadID { return threadID }
        guard isInitialized else { throw CodexAppServerError.notConnected }
        guard !isStartingThread else {
            throw CodexAppServerError.connectionStarting
        }

        isStartingThread = true
        defer { isStartingThread = false }
        let threadGeneration = conversationGeneration

        let workingDirectory = try conversationWorkingDirectory()

        let result = try await request(
            method: "thread/start",
            params: CodexAppServerRequestBuilder.threadStartParameters(
                workingDirectory: workingDirectory,
                developerInstructions: Self.generalAssistantInstructions
            )
        )

        guard let thread = result["thread"] as? JSONObject,
              let newThreadID = thread["id"] as? String else {
            throw CodexAppServerError.invalidResponse("thread/start omitted thread.id")
        }
        guard conversationGeneration == threadGeneration else {
            throw CodexAppServerError.conversationReplaced
        }
        threadID = newThreadID
        eventContinuation.yield(.threadReady(threadID: newThreadID))
        return newThreadID
    }

    private func conversationWorkingDirectory() throws -> URL {
        if let preferredWorkingDirectory {
            return preferredWorkingDirectory
        }

        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        let directory = applicationSupport
            .appendingPathComponent("Atmosphere", isDirectory: true)
            .appendingPathComponent("AssistantWorkspace", isDirectory: true)

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            return directory
        } catch {
            throw CodexAppServerError.processLaunchFailed(
                "could not prepare the private assistant workspace (\(error.localizedDescription))"
            )
        }
    }

    private static func parseAccountStatus(_ result: JSONObject) throws -> AssistantAccountStatus {
        guard let requiresOpenAIAuth = result["requiresOpenaiAuth"] as? Bool else {
            throw CodexAppServerError.invalidResponse(
                "account/read omitted requiresOpenaiAuth"
            )
        }

        guard let rawAccount = result["account"], !(rawAccount is NSNull) else {
            return AssistantAccountStatus(
                account: nil,
                requiresOpenAIAuth: requiresOpenAIAuth
            )
        }
        guard let accountObject = rawAccount as? JSONObject,
              let rawKind = accountObject["type"] as? String else {
            throw CodexAppServerError.invalidResponse("account/read returned an invalid account")
        }

        let kind: AssistantAccountStatus.Account.Kind
        switch rawKind {
        case "chatgpt": kind = .chatGPT
        case "apiKey": kind = .apiKey
        case "amazonBedrock": kind = .amazonBedrock
        default: kind = .unknown(rawKind)
        }

        return AssistantAccountStatus(
            account: AssistantAccountStatus.Account(
                kind: kind,
                email: accountObject["email"] as? String,
                planType: accountObject["planType"] as? String
            ),
            requiresOpenAIAuth: requiresOpenAIAuth
        )
    }
}
