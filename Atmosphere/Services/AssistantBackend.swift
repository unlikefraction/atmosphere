import Foundation

/// What `ChatViewModel` needs from an answer engine.
///
/// The vocabulary — `AssistantEvent`, `AssistantActivity`, `AssistantTurnStatus`
/// — grew out of the Codex app server, but nothing in it is Codex-specific: a
/// turn starts, text streams in, the turn ends or fails. The Claude Code
/// backend synthesises the same events from a different wire format, so the
/// view model never learns which engine it is talking to.
protocol AssistantBackend: Actor {
    nonisolated var events: AsyncStream<AssistantEvent> { get }
    nonisolated var activityEvents: AsyncStream<AssistantActivity> { get }

    func setWorkingDirectory(_ directory: URL?)

    @discardableResult
    func start() async throws -> AssistantAccountStatus

    /// Sign-in, where the engine has one to offer. An engine that inherits the
    /// user's existing CLI session throws `signInNotSupported` instead.
    func startManagedChatGPTLogin() async throws -> CodexLoginChallenge
    func cancelLogin() async throws

    /// Returns the turn identifier the caller should expect events under.
    func send(_ text: String, localImages: [URL]) async throws -> String

    /// Returns true when a turn was actually interrupted.
    @discardableResult
    func cancelCurrentTurn() async throws -> Bool

    /// Returns the new thread identifier.
    @discardableResult
    func resetConversation() async throws -> String?

    func stop()
}

enum AssistantBackendError: Error, Equatable, LocalizedError {
    case signInNotSupported(provider: String)

    var errorDescription: String? {
        switch self {
        case .signInNotSupported(let provider):
            return "\(provider) uses the sign-in already held by its command-line tool. Sign in there, then try again."
        }
    }
}

extension CodexAppServerClient: AssistantBackend {}
