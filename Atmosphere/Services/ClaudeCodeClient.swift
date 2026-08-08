import Foundation

enum ClaudeCodeError: Error, Equatable, LocalizedError {
    case executableNotFound(searchedPaths: [String])
    case notRunning
    case processLaunchFailed(String)
    case turnAlreadyInProgress
    case emptyMessage
    case connectionClosed(exitCode: Int32?, details: String?)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Could not find the Claude Code command-line tool. Install it, or set AtmosphereClaudeExecutablePath."
        case .notRunning:
            return "Claude Code is not running yet."
        case .processLaunchFailed(let details):
            return "Could not start Claude Code: \(details)"
        case .turnAlreadyInProgress:
            return "Claude is still answering."
        case .emptyMessage:
            return "Nothing to send."
        case .connectionClosed(let exitCode, let details):
            let suffix = details.map { ": \($0)" } ?? ""
            if let exitCode {
                return "Claude Code stopped (exit \(exitCode))\(suffix)"
            }
            return "Claude Code stopped\(suffix)"
        }
    }
}

/// Atmosphere's second answer engine: one long-lived `claude --print` process
/// in streaming-input mode.
///
/// Streaming input is what makes this feel native rather than shelled-out. One
/// process per *conversation*, not per turn: a cold `claude -p` start costs
/// well over a second, and paying that on every question would undo the point
/// of a keyboard-first overlay. Messages go in as JSON lines, events come back
/// as JSON lines, and the session keeps its own context between turns.
///
/// Nothing here holds a credential. The CLI uses whatever sign-in the user
/// already has, exactly as the Codex path reuses theirs.
actor ClaudeCodeClient {
    static let executableOverrideDefaultsKey = "AtmosphereClaudeExecutablePath"

    nonisolated let events: AsyncStream<AssistantEvent>
    nonisolated let activityEvents: AsyncStream<AssistantActivity>

    private static let systemPrompt = """
    You are Atmosphere, a concise general-purpose assistant in a small macOS overlay. Answer the user's question directly in plain language, formatted as Markdown. Prefer short, self-contained answers unless the user asks for more detail. When it is relevant to the question, you may read files inside the operating folder with your read-only tools. Never create, edit, delete, move, or rename files, and never take actions outside answering. Say when current information cannot be verified.
    """

    /// Read-only tools only. The launch also passes
    /// `--dangerously-skip-permissions`, so this list — not a prompt — is what
    /// keeps an answer from touching the user's machine.
    private static let allowedTools = "Read,Grep,Glob"

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

    private var sessionID = UUID().uuidString.lowercased()
    private var preferredWorkingDirectory: URL?
    private var isRunning = false
    private var activeTurnID: String?
    private var activeItemID: String?
    private var didStreamText = false
    private var streamedText = ""
    private var didStartMessage = false
    private var cancelledTurnIDs = Set<String>()

    init() {
        var continuation: AsyncStream<AssistantEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(1_024)) { continuation = $0 }
        eventContinuation = continuation

        var activity: AsyncStream<AssistantActivity>.Continuation!
        activityEvents = AsyncStream(bufferingPolicy: .bufferingNewest(1_024)) { activity = $0 }
        activityContinuation = activity
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

    // MARK: - AssistantBackend

    func setWorkingDirectory(_ directory: URL?) {
        preferredWorkingDirectory = directory?.standardizedFileURL
    }

    @discardableResult
    func start() async throws -> AssistantAccountStatus {
        if isRunning, process?.isRunning == true {
            return Self.readyAccount
        }

        eventContinuation.yield(.connectionStateChanged(.starting))
        do {
            try spawnProcess()
        } catch {
            eventContinuation.yield(
                .connectionStateChanged(.failed(error.localizedDescription))
            )
            throw error
        }

        isRunning = true
        eventContinuation.yield(.connectionStateChanged(.ready))
        eventContinuation.yield(.accountChanged(Self.readyAccount))
        // The CLI creates the session lazily, on the first message. Publishing
        // the thread now is what lets the composer accept input immediately.
        eventContinuation.yield(.threadStarted(threadID: sessionID))
        eventContinuation.yield(.threadReady(threadID: sessionID))
        return Self.readyAccount
    }

    /// Claude Code has no in-app sign-in to offer: it uses the session the CLI
    /// already holds.
    func startManagedChatGPTLogin() async throws -> CodexLoginChallenge {
        throw AssistantBackendError.signInNotSupported(provider: "Claude")
    }

    func cancelLogin() async throws {}

    @discardableResult
    func send(_ text: String, localImages: [URL] = []) async throws -> String {
        guard isRunning, let inputHandle, process?.isRunning == true else {
            throw ClaudeCodeError.notRunning
        }
        guard activeTurnID == nil else { throw ClaudeCodeError.turnAlreadyInProgress }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !localImages.isEmpty else {
            throw ClaudeCodeError.emptyMessage
        }

        var content: [[String: Any]] = []
        for imageURL in localImages {
            guard let data = try? Data(contentsOf: imageURL) else { continue }
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": Self.mediaType(for: imageURL),
                    "data": data.base64EncodedString()
                ]
            ])
        }
        if !trimmed.isEmpty {
            content.append(["type": "text", "text": trimmed])
        }
        guard !content.isEmpty else { throw ClaudeCodeError.emptyMessage }

        let payload: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": content],
            "parent_tool_use_id": NSNull(),
            "session_id": sessionID
        ]
        let line = try Self.encodeLine(payload)

        let turnID = UUID().uuidString
        activeTurnID = turnID
        activeItemID = UUID().uuidString
        didStreamText = false
        didStartMessage = false
        streamedText = ""

        do {
            try inputHandle.write(contentsOf: line)
        } catch {
            activeTurnID = nil
            throw ClaudeCodeError.connectionClosed(
                exitCode: process?.terminationStatus,
                details: error.localizedDescription
            )
        }

        eventContinuation.yield(.turnStarted(threadID: sessionID, turnID: turnID))
        return turnID
    }

    @discardableResult
    func cancelCurrentTurn() async throws -> Bool {
        guard let turnID = activeTurnID else { return false }

        cancelledTurnIDs.insert(turnID)
        finishTurn(turnID: turnID, status: .interrupted, failure: nil)

        // The CLI has no way to abandon an in-flight turn without abandoning
        // the process, so the session is restarted and resumed instead. The
        // transcript on disk keeps everything up to the interrupted turn.
        restartProcess(resumingSession: true)
        return true
    }

    @discardableResult
    func resetConversation() async throws -> String? {
        activeTurnID = nil
        activeItemID = nil
        sessionID = UUID().uuidString.lowercased()
        restartProcess(resumingSession: false)
        eventContinuation.yield(.threadStarted(threadID: sessionID))
        eventContinuation.yield(.threadReady(threadID: sessionID))
        return sessionID
    }

    func stop() {
        teardownProcess()
        isRunning = false
        eventContinuation.yield(.connectionStateChanged(.stopped))
    }

    // MARK: - Launching

    private static var readyAccount: AssistantAccountStatus {
        AssistantAccountStatus(
            account: AssistantAccountStatus.Account(
                kind: .unknown("claude_code"),
                email: nil,
                planType: nil
            ),
            requiresOpenAIAuth: false
        )
    }

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

        if let path = environment["PATH"] {
            paths.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("claude").path
            })
        }

        // A launched-from-Finder app inherits a minimal PATH, so the usual
        // install locations are checked explicitly.
        paths.append(contentsOf: [
            ("~/.local/bin/claude" as NSString).expandingTildeInPath,
            ("~/.claude/local/claude" as NSString).expandingTildeInPath,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude"
        ])

        var seen = Set<String>()
        let uniquePaths = paths.filter { seen.insert($0).inserted }

        for path in uniquePaths where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path).standardizedFileURL
        }

        throw ClaudeCodeError.executableNotFound(searchedPaths: uniquePaths)
    }

    /// The launch arguments, as a pure function so the contract is testable.
    ///
    /// `--strict-mcp-config` with no config keeps the user's MCP servers,
    /// plugins, and their tools out of a session that only has to answer a
    /// question.
    static func arguments(sessionID: String, resuming: Bool) -> [String] {
        var arguments = [
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model", "claude-opus-5",
            "--effort", "low",
            "--dangerously-skip-permissions",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--tools", allowedTools,
            "--append-system-prompt", systemPrompt
        ]
        arguments.append(contentsOf: resuming ? ["--resume", sessionID] : ["--session-id", sessionID])
        return arguments
    }

    private func spawnProcess(resuming: Bool = false) throws {
        let executableURL = try Self.discoverExecutableURL()
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let generation = UUID()

        process.executableURL = executableURL
        process.arguments = Self.arguments(sessionID: sessionID, resuming: resuming)
        process.currentDirectoryURL = preferredWorkingDirectory ?? Self.neutralWorkingDirectory()

        var environment = ProcessInfo.processInfo.environment
        // An app bundle's PATH does not include the usual CLI locations, and
        // the CLI shells out to its own helpers.
        let extraPaths = [
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin"),
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ]
        let existing = environment["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []
        var seen = Set(existing)
        environment["PATH"] = (existing + extraPaths.filter { seen.insert($0).inserted })
            .joined(separator: ":")
        process.environment = environment

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
            throw ClaudeCodeError.processLaunchFailed(error.localizedDescription)
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

        // One reader task per pipe preserves byte order; spawning a task per
        // readability callback can reorder chunks and corrupt line framing.
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

    /// Where a session runs when the user has not chosen an operating folder:
    /// a private, empty directory rather than the home folder.
    private static func neutralWorkingDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let directory = base
            .appendingPathComponent("Atmosphere", isDirectory: true)
            .appendingPathComponent("ClaudeWorkspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func restartProcess(resumingSession: Bool) {
        teardownProcess()
        guard isRunning else { return }
        do {
            try spawnProcess(resuming: resumingSession)
        } catch {
            isRunning = false
            eventContinuation.yield(
                .connectionStateChanged(.failed(error.localizedDescription))
            )
        }
    }

    private func teardownProcess() {
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        outputChunkContinuation?.finish()
        errorChunkContinuation?.finish()
        outputReadTask?.cancel()
        errorReadTask?.cancel()
        outputReadTask = nil
        errorReadTask = nil
        connectionGeneration = nil
        try? inputHandle?.close()
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        let process = self.process
        self.process = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
    }

    // MARK: - Reading

    private func receiveStandardOutput(_ data: Data, generation: UUID) {
        guard generation == connectionGeneration, !data.isEmpty else { return }
        do {
            for line in try stdoutDecoder.append(data) {
                handle(line: line)
            }
        } catch {
            // Framing is broken; the stream cannot be trusted from here on.
            if let turnID = activeTurnID {
                finishTurn(
                    turnID: turnID,
                    status: .failed,
                    failure: AssistantTurnFailure(
                        message: error.localizedDescription,
                        additionalDetails: nil,
                        willRetry: false
                    )
                )
            }
            restartProcess(resumingSession: true)
        }
    }

    private func receiveStandardError(_ data: Data, generation: UUID) {
        guard generation == connectionGeneration, !data.isEmpty else { return }
        recentStandardError.append(data)
        // Enough for a diagnostic, never enough to grow without bound.
        if recentStandardError.count > 8_192 {
            recentStandardError.removeFirst(recentStandardError.count - 8_192)
        }
    }

    private func handle(line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return
        }
        guard let turnID = activeTurnID, let itemID = activeItemID else {
            // Between turns only the session identifier matters.
            if let object = object as [String: Any]?,
               object["type"] as? String == "system",
               object["subtype"] as? String == "init",
               let session = object["session_id"] as? String {
                sessionID = session
            }
            return
        }

        let outcome = ClaudeStreamEventParser.outcome(
            for: object,
            threadID: sessionID,
            turnID: turnID,
            itemID: itemID
        )

        if let session = outcome.sessionID { sessionID = session }
        guard !cancelledTurnIDs.contains(turnID) else { return }

        for event in outcome.events {
            if case .assistantMessageStarted = event {
                guard !didStartMessage else { continue }
                didStartMessage = true
            }
            if case .assistantDelta(_, _, _, let delta) = event {
                didStreamText = true
                streamedText += delta
            }
            eventContinuation.yield(event)
        }
        outcome.activities.forEach { activityContinuation.yield($0) }

        guard outcome.turnDidEnd else {
            if !didStreamText, let text = outcome.completedText {
                // No partial messages arrived; keep the last full message so
                // the answer still lands when the turn ends.
                streamedText = text
            }
            return
        }

        if let failure = outcome.failure {
            finishTurn(turnID: turnID, status: .failed, failure: failure)
            return
        }

        let finalText = didStreamText ? streamedText : (outcome.completedText ?? streamedText)
        if !finalText.isEmpty {
            if !didStartMessage {
                eventContinuation.yield(
                    .assistantMessageStarted(
                        threadID: sessionID,
                        turnID: turnID,
                        itemID: itemID,
                        phase: .finalAnswer
                    )
                )
            }
            eventContinuation.yield(
                .assistantMessageCompleted(
                    threadID: sessionID,
                    turnID: turnID,
                    itemID: itemID,
                    text: finalText,
                    phase: .finalAnswer
                )
            )
        }
        finishTurn(turnID: turnID, status: .completed, failure: nil)
    }

    private func finishTurn(
        turnID: String,
        status: AssistantTurnStatus,
        failure: AssistantTurnFailure?
    ) {
        guard activeTurnID == turnID else { return }
        activeTurnID = nil
        activeItemID = nil
        didStreamText = false
        didStartMessage = false
        streamedText = ""
        eventContinuation.yield(
            .turnCompleted(
                threadID: sessionID,
                turnID: turnID,
                status: status,
                failure: failure
            )
        )
    }

    private func processDidTerminate(generation: UUID, exitCode: Int32) {
        guard generation == connectionGeneration else { return }

        let details = String(data: recentStandardError, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let turnID = activeTurnID {
            finishTurn(
                turnID: turnID,
                status: .failed,
                failure: AssistantTurnFailure(
                    message: ClaudeCodeError.connectionClosed(
                        exitCode: exitCode,
                        details: details?.isEmpty == false ? details : nil
                    ).localizedDescription,
                    additionalDetails: nil,
                    willRetry: false
                )
            )
        }

        teardownProcess()
        guard isRunning else { return }
        isRunning = false
        eventContinuation.yield(
            .connectionStateChanged(
                .failed(
                    ClaudeCodeError.connectionClosed(
                        exitCode: exitCode,
                        details: details?.isEmpty == false ? details : nil
                    ).localizedDescription
                )
            )
        )
    }

    // MARK: - Helpers

    /// One JSON object, one line — the framing the CLI's streaming input uses.
    static func encodeLine(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [])
        data.append(0x0A)
        return data
    }

    static func mediaType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }
}

extension ClaudeCodeClient: AssistantBackend {}
