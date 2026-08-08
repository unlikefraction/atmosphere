import Foundation

/// Translates one line of `claude --output-format stream-json` into the events
/// Atmosphere already speaks.
///
/// The wire format is documented by the CLI itself (`claude --help`) and is the
/// same one the Agent SDK consumes:
///
/// - `system` / `init` — session established, carries the session id
/// - `system` / `status` — the CLI is waiting on the API
/// - `stream_event` — raw Anthropic streaming events, one content-block delta
///   at a time, present only with `--include-partial-messages`
/// - `assistant` — the complete message for a step
/// - `result` — the turn is over, with `is_error` and `result` text
///
/// Kept free of process and actor state so every branch is unit-testable.
enum ClaudeStreamEventParser {
    /// What one line means, in Atmosphere's terms.
    struct Outcome: Equatable {
        var sessionID: String?
        var events: [AssistantEvent] = []
        var activities: [AssistantActivity] = []
        /// Text seen in this line, for backends that never received deltas.
        var completedText: String?
        var turnDidEnd = false
        var failure: AssistantTurnFailure?
    }

    /// - Parameters:
    ///   - object: one decoded JSON line.
    ///   - threadID: the current session identifier, for event addressing.
    ///   - turnID: the turn the caller opened for the pending message.
    ///   - itemID: identifier for the assistant message being streamed.
    static func outcome(
        for object: [String: Any],
        threadID: String,
        turnID: String,
        itemID: String
    ) -> Outcome {
        var outcome = Outcome()
        guard let type = object["type"] as? String else { return outcome }

        switch type {
        case "system":
            let subtype = object["subtype"] as? String
            if subtype == "init" {
                outcome.sessionID = object["session_id"] as? String
            }
            if subtype == "status", object["status"] as? String == "requesting" {
                outcome.activities.append(
                    AssistantActivity(
                        threadID: threadID,
                        turnID: turnID,
                        itemID: itemID,
                        kind: .preparingAnswer,
                        message: "Thinking"
                    )
                )
            }

        case "stream_event":
            guard let event = object["event"] as? [String: Any],
                  let eventType = event["type"] as? String else { break }

            switch eventType {
            case "content_block_start":
                guard let block = event["content_block"] as? [String: Any] else { break }
                switch block["type"] as? String {
                case "text":
                    outcome.events.append(
                        .assistantMessageStarted(
                            threadID: threadID,
                            turnID: turnID,
                            itemID: itemID,
                            phase: .finalAnswer
                        )
                    )
                case "thinking":
                    outcome.activities.append(
                        AssistantActivity(
                            threadID: threadID,
                            turnID: turnID,
                            itemID: itemID,
                            kind: .reasoningSummary,
                            message: "Thinking it through"
                        )
                    )
                case "tool_use":
                    // Generic only. Tool names, arguments, and output are never
                    // surfaced, exactly as on the Codex path.
                    outcome.activities.append(
                        AssistantActivity(
                            threadID: threadID,
                            turnID: turnID,
                            itemID: itemID,
                            kind: .localContext,
                            message: "Looking at the operating folder"
                        )
                    )
                default:
                    break
                }

            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any] else { break }
                if delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String,
                   !text.isEmpty {
                    outcome.events.append(
                        .assistantDelta(
                            threadID: threadID,
                            turnID: turnID,
                            itemID: itemID,
                            delta: text
                        )
                    )
                }

            default:
                break
            }

        case "assistant":
            // The complete message for this step. Used only as the fallback
            // when partial messages are unavailable; the caller decides.
            guard let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { break }
            let text = content
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
            if !text.isEmpty {
                outcome.completedText = text
            }

        case "result":
            outcome.turnDidEnd = true
            let isError = object["is_error"] as? Bool ?? false
            let subtype = object["subtype"] as? String
            if let text = object["result"] as? String, !text.isEmpty, !isError {
                outcome.completedText = text
            }
            if isError || (subtype != nil && subtype != "success") {
                outcome.failure = AssistantTurnFailure(
                    message: failureMessage(for: object),
                    additionalDetails: nil,
                    willRetry: false
                )
            }

        default:
            break
        }

        return outcome
    }

    static func failureMessage(for object: [String: Any]) -> String {
        if let text = object["result"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        if let status = object["api_error_status"] as? String, !status.isEmpty {
            return "Claude Code reported an API error (\(status))."
        }
        switch object["subtype"] as? String {
        case "error_max_turns":
            return "Claude Code stopped after reaching its turn limit."
        case "error_during_execution":
            return "Claude Code stopped before finishing the answer."
        default:
            return "Claude Code could not complete the answer."
        }
    }
}
