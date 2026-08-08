import AppKit
import Foundation

enum ChatConnectionStatus: Equatable {
    case connected
    case connecting
    case authenticationRequired
    case disconnected
    case failed

    var label: String {
        switch self {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .authenticationRequired: return "Sign in"
        case .disconnected: return "Offline"
        case .failed: return "Connection issue"
        }
    }
}

enum InputPermissionAction: Equatable, Sendable {
    case microphone
    case screenCapture
    case restartAtmosphere
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var connectionStatus: ChatConnectionStatus = .disconnected
    @Published private(set) var requiresAuthentication = false
    @Published private(set) var isConnecting = false
    @Published private(set) var isGenerating = false
    @Published private(set) var isResettingConversation = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var pendingAttachments: [ChatAttachment] = []
    @Published private(set) var isPreparingVoice = false
    @Published private(set) var isRecordingVoice = false
    @Published private(set) var isTranscribingVoice = false
    @Published private(set) var isCapturingScreenshot = false
    @Published private(set) var inputErrorMessage: String?
    @Published private(set) var inputPermissionAction: InputPermissionAction?
    @Published private(set) var selectedWorkingDirectory: URL?
    @Published private(set) var isChangingWorkingDirectory = false
    @Published private(set) var modelActivityText: String?

    @Published private(set) var activeModel: AssistantModel
    @Published private(set) var isSwitchingModel = false

    private let backends: [AssistantModel: any AssistantBackend]
    private let modelPreference: AssistantModelPreference
    private let microphoneRecorder: MicrophoneRecorder
    private let transcriptionClient: DeepgramTranscriptionClient
    private let workingDirectoryPreference: WorkingDirectoryPreference
    private var eventTasks: [Task<Void, Never>] = []
    private var activityTasks: [Task<Void, Never>] = []
    private var loginTimeoutTask: Task<Void, Never>?
    private var shortcutRegistrationMessage: String?
    private var workingDirectoryPreferenceError: String?
    private var isStartingClient = false
    @Published private var activeThreadID: String?
    private var activeTurnID: String?
    private var activeSubmissionToken: UUID?
    private var conversationResetToken: UUID?
    private var pendingAssistantMessageID: UUID?
    private var assistantMessageIDsByItemID: [String: UUID] = [:]
    private var ignoredAssistantItemIDs = Set<String>()
    private var voiceOperationID: UUID?
    private var screenshotOperationID: UUID?
    private var voiceCancellationGeneration: UInt = 0
    private var isVoiceCancellationPending = false
    private var voiceStartOperation: (id: UUID, task: Task<URL, Error>)?
    private var voiceStopOperation: (
        id: UUID,
        task: Task<MicrophoneRecording, Error>
    )?
    private var voiceTranscriptionOperation: (
        id: UUID,
        task: Task<DeepgramTranscript, Error>
    )?

    /// The engine currently answering. Every call site goes through this rather
    /// than holding a backend, so switching models cannot leave a stale
    /// reference behind mid-turn.
    private var client: any AssistantBackend {
        backends[activeModel] ?? backends[.gptLuna]!
    }

    init(
        client: CodexAppServerClient = CodexAppServerClient(),
        claudeClient: ClaudeCodeClient = ClaudeCodeClient(),
        modelPreference: AssistantModelPreference = AssistantModelPreference(),
        microphoneRecorder: MicrophoneRecorder = MicrophoneRecorder(),
        transcriptionClient: DeepgramTranscriptionClient = DeepgramTranscriptionClient(),
        workingDirectoryPreference: WorkingDirectoryPreference = WorkingDirectoryPreference()
    ) {
        backends = [.gptLuna: client, .claudeOpus: claudeClient]
        self.modelPreference = modelPreference
        activeModel = modelPreference.value()
        self.microphoneRecorder = microphoneRecorder
        self.transcriptionClient = transcriptionClient
        self.workingDirectoryPreference = workingDirectoryPreference
        do {
            selectedWorkingDirectory = try workingDirectoryPreference.selectedDirectory()
        } catch {
            selectedWorkingDirectory = nil
            workingDirectoryPreferenceError = error.localizedDescription
            errorMessage = error.localizedDescription
        }
        listenForClientEvents()
        listenForClientActivity()
    }

    /// Moves the conversation to the other engine.
    ///
    /// A thread belongs to one engine — there is no way to hand a half-finished
    /// Codex conversation to Claude — so this ends the current one, starts the
    /// other engine, and opens a fresh thread. The transcript is cleared for
    /// the same reason: leaving it on screen would imply the new model can see
    /// it, and it cannot.
    func switchModel(to model: AssistantModel? = nil) async {
        let target = model ?? activeModel.next
        guard target != activeModel, !isSwitchingModel, !isStartingClient else { return }

        isSwitchingModel = true
        defer { isSwitchingModel = false }

        invalidateVoiceInput()
        await cancelVoiceRecording()
        cancelScreenshotCapture()

        if isGenerating {
            _ = try? await client.cancelCurrentTurn()
        }
        await client.stop()

        clearLocalConversation()
        activeThreadID = nil
        connectionStatus = .connecting
        errorMessage = nil
        requiresAuthentication = false

        activeModel = modelPreference.save(target)
        await connect()
    }

    var canSend: Bool {
        !isSwitchingModel
            && connectionStatus == .connected
            && !requiresAuthentication
            && !isStartingClient
            && !isGenerating
            && !isResettingConversation
            && !isChangingWorkingDirectory
            && activeThreadID != nil
    }

    var canStartVoiceInput: Bool {
        canSend
            && !isPreparingVoice
            && !isRecordingVoice
            && !isTranscribingVoice
            && !isVoiceCancellationPending
    }

    var canChangeWorkingDirectory: Bool {
        !isSwitchingModel
            && !isStartingClient
            && !isConnecting
            && !isGenerating
            && !isResettingConversation
            && !isChangingWorkingDirectory
            && !isPreparingVoice
            && !isRecordingVoice
            && !isTranscribingVoice
            && !isVoiceCancellationPending
            && !isCapturingScreenshot
    }

    func connect() async {
        guard !isConnecting else { return }

        isStartingClient = true
        isConnecting = true
        connectionStatus = .connecting
        errorMessage = workingDirectoryPreferenceError ?? shortcutRegistrationMessage

        defer {
            isStartingClient = false
            isConnecting = false
        }

        do {
            await client.setWorkingDirectory(selectedWorkingDirectory)
            let account = try await client.start()
            apply(account)
        } catch {
            applyConnectionFailure(error)
        }
    }

    func startChatGPTLogin() async {
        guard !isConnecting else { return }

        isConnecting = true
        connectionStatus = .connecting
        errorMessage = nil

        do {
            let challenge = try await client.startManagedChatGPTLogin()
            guard NSWorkspace.shared.open(challenge.authenticationURL) else {
                try? await client.cancelLogin()
                throw ChatViewModelError.couldNotOpenLoginPage
            }
            // Remain in the connecting state. The app-server owns the callback
            // and publishes account/login/completed when the browser finishes.
            beginLoginTimeout()
        } catch {
            isConnecting = false
            requiresAuthentication = true
            connectionStatus = .authenticationRequired
            errorMessage = error.localizedDescription
        }
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard (!trimmed.isEmpty || !attachments.isEmpty),
              canSend,
              !isPreparingVoice,
              !isRecordingVoice,
              !isTranscribingVoice else { return }

        let assistantID = UUID()
        pendingAttachments.removeAll()
        messages.append(
            ChatMessage(
                role: .user,
                text: trimmed,
                attachments: attachments
            )
        )
        messages.append(
            ChatMessage(
                id: assistantID,
                role: .assistant,
                text: "",
                isStreaming: true
            )
        )
        pendingAssistantMessageID = assistantID
        assistantMessageIDsByItemID.removeAll(keepingCapacity: true)
        let submissionToken = UUID()
        activeSubmissionToken = submissionToken
        isGenerating = true
        modelActivityText = "Thinking…"
        errorMessage = nil
        clearInputError()

        Task {
            do {
                let turnID = try await client.send(
                    trimmed,
                    localImages: attachments.map(\.fileURL)
                )
                // A very short answer can complete before send() resumes. Do
                // not resurrect an already-finished turn in that case.
                if activeSubmissionToken == submissionToken, isGenerating {
                    activeTurnID = turnID
                }
            } catch {
                if activeSubmissionToken == submissionToken {
                    finishGenerationWithError(error.localizedDescription)
                }
            }
        }
    }

    @discardableResult
    func startVoiceRecording() async -> Bool {
        guard canStartVoiceInput else { return false }

        let operationID = UUID()
        voiceOperationID = operationID
        isPreparingVoice = true
        clearInputError()

        let startTask = Task {
            try await microphoneRecorder.start()
        }
        voiceStartOperation = (operationID, startTask)

        do {
            _ = try await startTask.value
            guard voiceOperationID == operationID else {
                await microphoneRecorder.cancel()
                return false
            }
            if voiceStartOperation?.id == operationID {
                voiceStartOperation = nil
            }
            isPreparingVoice = false
            isRecordingVoice = true
            return true
        } catch {
            guard voiceOperationID == operationID else { return false }
            voiceOperationID = nil
            if voiceStartOperation?.id == operationID {
                voiceStartOperation = nil
            }
            isPreparingVoice = false
            isRecordingVoice = false
            setInputError(error)
            return false
        }
    }

    /// Stops the microphone, uploads the private temporary WAV to Deepgram,
    /// and returns only a non-empty transcript. The caller decides how that
    /// transcript combines with the current draft and pending screenshots.
    func stopVoiceRecordingAndTranscribe() async -> String? {
        guard isRecordingVoice else { return nil }

        let operationID = UUID()
        voiceOperationID = operationID
        isRecordingVoice = false
        isTranscribingVoice = true
        clearInputError()

        do {
            let stopTask = Task {
                try Task.checkCancellation()
                let recording = try await microphoneRecorder.stop()
                do {
                    try Task.checkCancellation()
                    return recording
                } catch {
                    recording.discard()
                    throw error
                }
            }
            voiceStopOperation = (operationID, stopTask)
            let recording = try await stopTask.value
            guard voiceOperationID == operationID else {
                recording.discard()
                return nil
            }
            if voiceStopOperation?.id == operationID {
                voiceStopOperation = nil
            }
            guard recording.containsAudio else {
                recording.discard()
                throw DeepgramTranscriptionError.noRecordedAudio
            }

            let transcriptionTask = Task {
                defer { recording.discard() }
                return try await transcriptionClient.transcribe(recording)
            }
            voiceTranscriptionOperation = (operationID, transcriptionTask)
            let transcript = try await transcriptionTask.value
            guard voiceOperationID == operationID else { return nil }
            voiceOperationID = nil
            if voiceTranscriptionOperation?.id == operationID {
                voiceTranscriptionOperation = nil
            }
            isTranscribingVoice = false
            return transcript.text
        } catch {
            guard voiceOperationID == operationID else { return nil }
            voiceOperationID = nil
            if voiceStopOperation?.id == operationID {
                voiceStopOperation = nil
            }
            if voiceTranscriptionOperation?.id == operationID {
                voiceTranscriptionOperation = nil
            }
            isRecordingVoice = false
            isTranscribingVoice = false
            setInputError(error)
            return nil
        }
    }

    /// Invalidates UI-visible voice work synchronously. Overlay hiding calls
    /// this before ordering the panel out so a just-finished transcript cannot
    /// auto-submit from a hidden window.
    func invalidateVoiceInput() {
        voiceCancellationGeneration &+= 1
        isVoiceCancellationPending = true
        voiceOperationID = nil
        voiceStartOperation?.task.cancel()
        voiceStopOperation?.task.cancel()
        voiceTranscriptionOperation?.task.cancel()
        isPreparingVoice = false
        isRecordingVoice = false
        isTranscribingVoice = false
    }

    func cancelVoiceRecording() async {
        if !isVoiceCancellationPending {
            invalidateVoiceInput()
        }
        let cancellationGeneration = voiceCancellationGeneration
        let startOperation = voiceStartOperation
        let stopOperation = voiceStopOperation
        let transcriptionOperation = voiceTranscriptionOperation
        await microphoneRecorder.cancel()
        if let startOperation {
            _ = await startOperation.task.result
            if voiceStartOperation?.id == startOperation.id {
                voiceStartOperation = nil
            }
        }
        if let stopOperation {
            let result = await stopOperation.task.result
            if case .success(let recording) = result {
                recording.discard()
            }
            if voiceStopOperation?.id == stopOperation.id {
                voiceStopOperation = nil
            }
        }
        if let transcriptionOperation {
            _ = await transcriptionOperation.task.result
            if voiceTranscriptionOperation?.id == transcriptionOperation.id {
                voiceTranscriptionOperation = nil
            }
        }
        if voiceCancellationGeneration == cancellationGeneration {
            isVoiceCancellationPending = false
        }
    }

    /// Called before ScreenCaptureKit starts so repeated grave-key presses do
    /// not create overlapping full-display captures.
    func beginScreenshotCapture() -> UUID? {
        guard !isCapturingScreenshot,
              !isChangingWorkingDirectory,
              !isResettingConversation else { return nil }
        guard pendingAttachments.count < 4 else {
            inputErrorMessage = "You can attach up to four screenshots to one message."
            inputPermissionAction = nil
            return nil
        }
        let operationID = UUID()
        screenshotOperationID = operationID
        isCapturingScreenshot = true
        clearInputError()
        return operationID
    }

    func finishScreenshotCapture(_ fileURL: URL, operationID: UUID) {
        guard screenshotOperationID == operationID else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        screenshotOperationID = nil
        pendingAttachments.append(ChatAttachment(fileURL: fileURL))
        isCapturingScreenshot = false
        clearInputError()
    }

    func failScreenshotCapture(_ error: Error, operationID: UUID) {
        guard screenshotOperationID == operationID else { return }
        screenshotOperationID = nil
        isCapturingScreenshot = false
        setInputError(error)
    }

    func cancelScreenshotCapture() {
        screenshotOperationID = nil
        isCapturingScreenshot = false
    }

    /// Selects or changes the folder available to future assistant turns.
    /// The existing thread is replaced so one thread can never span folders.
    @discardableResult
    func selectWorkingDirectory(_ directoryURL: URL) async -> Bool {
        guard canChangeWorkingDirectory else { return false }

        isChangingWorkingDirectory = true
        defer { isChangingWorkingDirectory = false }

        do {
            let selectedDirectory = try workingDirectoryPreference.selectDirectory(directoryURL)
            selectedWorkingDirectory = selectedDirectory
            workingDirectoryPreferenceError = nil
            return await applyWorkingDirectoryChange(selectedDirectory)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Removes folder context and starts a fresh thread in Atmosphere's
    /// private fallback workspace. The removal persists across launches.
    @discardableResult
    func removeWorkingDirectory() async -> Bool {
        guard canChangeWorkingDirectory else { return false }

        isChangingWorkingDirectory = true
        defer { isChangingWorkingDirectory = false }

        workingDirectoryPreference.removeDirectory()
        selectedWorkingDirectory = nil
        workingDirectoryPreferenceError = nil
        return await applyWorkingDirectoryChange(nil)
    }

    func removePendingAttachment(_ attachment: ChatAttachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
        try? FileManager.default.removeItem(at: attachment.fileURL)
    }

    func clearResolvedPermissionError(
        microphoneGranted: Bool,
        screenCaptureGranted: Bool
    ) {
        switch inputPermissionAction {
        case .microphone where microphoneGranted:
            clearInputError()
        case .screenCapture where screenCaptureGranted:
            clearInputError()
        default:
            break
        }
    }

    func reportScreenCaptureRestartRequired() {
        setInputError(OverlayScreenshotServiceError.restartRequiredAfterPermissionGrant)
    }

    func reportPermissionSettingsUnavailable(for action: InputPermissionAction) {
        inputErrorMessage = "Couldn’t open System Settings. Open Privacy & Security manually."
        inputPermissionAction = action
    }

    func reportApplicationRestartFailure() {
        inputErrorMessage = "Couldn’t restart Atmosphere automatically. Quit it, then open it again."
        inputPermissionAction = .restartAtmosphere
    }

    func cancelGeneration() async {
        do {
            _ = try await client.cancelCurrentTurn()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func newConversation() {
        guard !isStartingClient,
              !isResettingConversation,
              !isChangingWorkingDirectory else { return }
        invalidateVoiceInput()
        Task { await cancelVoiceRecording() }
        cancelScreenshotCapture()
        clearLocalConversation()
        let resetToken = UUID()
        conversationResetToken = resetToken
        isResettingConversation = true
        Task {
            defer {
                if conversationResetToken == resetToken {
                    conversationResetToken = nil
                    isResettingConversation = false
                }
            }
            do {
                let threadID = try await client.resetConversation()
                if conversationResetToken == resetToken {
                    activeThreadID = threadID
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func clearConversation() {
        guard !isStartingClient,
              !isResettingConversation,
              !isChangingWorkingDirectory else { return }
        invalidateVoiceInput()
        Task { await cancelVoiceRecording() }
        cancelScreenshotCapture()
        clearLocalConversation()
        let resetToken = UUID()
        conversationResetToken = resetToken
        isResettingConversation = true
        Task {
            defer {
                if conversationResetToken == resetToken {
                    conversationResetToken = nil
                    isResettingConversation = false
                }
            }
            do {
                let threadID = try await client.resetConversation()
                if conversationResetToken == resetToken {
                    activeThreadID = threadID
                }
            } catch {
                if conversationResetToken == resetToken {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func reportShortcutRegistrationFailure() {
        let message = "⌘\\ is already in use by another app. Quit the conflicting app and relaunch Atmosphere."
        shortcutRegistrationMessage = message
        errorMessage = message
    }

    func shutdown() async {
        loginTimeoutTask?.cancel()
        loginTimeoutTask = nil
        eventTasks.forEach { $0.cancel() }
        eventTasks.removeAll()
        activityTasks.forEach { $0.cancel() }
        activityTasks.removeAll()
        cancelScreenshotCapture()
        await cancelVoiceRecording()
        for backend in backends.values {
            await backend.stop()
        }
        discardScreenshotFiles()
    }

    /// Subscribes to every backend once, for the lifetime of the view model.
    ///
    /// `AsyncStream` supports a single iterator, so re-subscribing on each
    /// model switch would iterate a stream twice the moment the user switched
    /// back. Instead both streams are consumed from the start and events from
    /// the inactive engine — a late completion arriving after a switch, say —
    /// are dropped here rather than being applied to the new conversation.
    private func listenForClientEvents() {
        eventTasks.forEach { $0.cancel() }
        eventTasks = backends.map { model, backend in
            let events = backend.events
            return Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled else { break }
                    guard self?.activeModel == model else { continue }
                    self?.handle(event)
                }
            }
        }
    }

    private func listenForClientActivity() {
        activityTasks.forEach { $0.cancel() }
        activityTasks = backends.map { model, backend in
            let activities = backend.activityEvents
            return Task { [weak self] in
                for await activity in activities {
                    guard !Task.isCancelled else { break }
                    guard self?.activeModel == model else { continue }
                    self?.handle(activity)
                }
            }
        }
    }

    private func handle(_ activity: AssistantActivity) {
        guard conversationResetToken == nil,
              isGenerating,
              activeThreadID == activity.threadID,
              activeTurnID == nil || activeTurnID == activity.turnID else { return }
        modelActivityText = activity.message
    }

    private func handle(_ event: AssistantEvent) {
        switch event {
        case .connectionStateChanged(let state):
            handleConnectionState(state)

        case .accountChanged(let account):
            if isStartingClient {
                requiresAuthentication = !account.canStartConversation
            } else {
                apply(account)
                isConnecting = false
            }

        case .loginCompleted(_, let success, let error):
            if success {
                connectionStatus = .connecting
                isConnecting = true
                errorMessage = nil
            } else {
                loginTimeoutTask?.cancel()
                loginTimeoutTask = nil
                requiresAuthentication = true
                connectionStatus = .authenticationRequired
                isConnecting = false
                errorMessage = error ?? "ChatGPT sign-in did not complete."
            }

        case .threadReady(let threadID):
            activeThreadID = threadID

        case .turnStarted(let threadID, let turnID):
            guard conversationResetToken == nil,
                  activeThreadID == threadID,
                  activeSubmissionToken != nil,
                  isGenerating else { return }
            activeTurnID = turnID

        case .assistantMessageStarted(let threadID, let turnID, let itemID, let phase):
            guard conversationResetToken == nil,
                  activeThreadID == threadID,
                  activeTurnID == turnID else { return }
            if phase == .commentary {
                ignoredAssistantItemIDs.insert(itemID)
            }

        case .assistantDelta(let threadID, let turnID, let itemID, let delta):
            guard conversationResetToken == nil,
                  activeThreadID == threadID,
                  activeTurnID == turnID,
                  !ignoredAssistantItemIDs.contains(itemID) else { return }
            append(delta: delta, itemID: itemID)

        case .assistantMessageCompleted(
            let threadID,
            let turnID,
            let itemID,
            let text,
            let phase
        ):
            guard conversationResetToken == nil,
                  activeThreadID == threadID,
                  activeTurnID == turnID else { return }
            if phase == .commentary || ignoredAssistantItemIDs.contains(itemID) {
                discardAssistantMessage(itemID: itemID)
            } else {
                completeAssistantMessage(itemID: itemID, text: text)
            }

        case .turnCompleted(let threadID, let turnID, let status, let failure):
            guard conversationResetToken == nil,
                  activeThreadID == threadID,
                  activeTurnID == turnID else { return }
            finishTurn(status: status, failure: failure)

        case .turnError(let threadID, let turnID, let failure):
            guard conversationResetToken == nil,
                  activeThreadID == threadID,
                  activeTurnID == turnID else { return }
            if !failure.willRetry {
                errorMessage = failure.additionalDetails ?? failure.message
            }

        case .accountUpdated, .threadStarted:
            break
        }
    }

    private func handleConnectionState(_ state: AssistantConnectionState) {
        switch state {
        case .stopped:
            connectionStatus = .disconnected
            activeThreadID = nil
        case .starting:
            connectionStatus = .connecting
        case .ready:
            if !isStartingClient, !requiresAuthentication {
                connectionStatus = .connected
            }
        case .failed(let message):
            connectionStatus = .failed
            isConnecting = false
            activeThreadID = nil
            errorMessage = message
            if isGenerating {
                finishGenerationWithError(message)
            }
        }
    }

    private func apply(_ account: AssistantAccountStatus) {
        if account.canStartConversation {
            loginTimeoutTask?.cancel()
            loginTimeoutTask = nil
            requiresAuthentication = false
            connectionStatus = .connected
            errorMessage = workingDirectoryPreferenceError ?? shortcutRegistrationMessage
        } else {
            // Losing authentication also invalidates the server-side turn.
            // Finish the matching local generation immediately because its
            // later events are intentionally ignored after the thread clears.
            if isGenerating {
                finishGenerationWithError(
                    "ChatGPT sign-in expired. Sign in again to continue."
                )
            }
            activeThreadID = nil
            requiresAuthentication = true
            connectionStatus = .authenticationRequired
        }
    }

    private func applyConnectionFailure(_ error: Error) {
        requiresAuthentication = false
        activeThreadID = nil
        connectionStatus = .failed
        errorMessage = error.localizedDescription
    }

    private func append(delta: String, itemID: String) {
        modelActivityText = nil
        let messageID: UUID
        if let existing = assistantMessageIDsByItemID[itemID] {
            messageID = existing
        } else if let pendingAssistantMessageID {
            messageID = pendingAssistantMessageID
            assistantMessageIDsByItemID[itemID] = messageID
            self.pendingAssistantMessageID = nil
        } else {
            let newMessage = ChatMessage(role: .assistant, text: "", isStreaming: true)
            messageID = newMessage.id
            assistantMessageIDsByItemID[itemID] = messageID
            messages.append(newMessage)
        }

        updateMessage(id: messageID) { message in
            message.text += delta
            message.isStreaming = true
        }
    }

    private func completeAssistantMessage(itemID: String, text: String) {
        modelActivityText = nil
        let messageID: UUID
        if let existing = assistantMessageIDsByItemID[itemID] {
            messageID = existing
        } else if let pendingAssistantMessageID {
            messageID = pendingAssistantMessageID
            assistantMessageIDsByItemID[itemID] = messageID
            self.pendingAssistantMessageID = nil
        } else {
            let message = ChatMessage(role: .assistant, text: text)
            messages.append(message)
            return
        }

        updateMessage(id: messageID) { message in
            message.text = text
            message.isStreaming = false
        }
    }

    private func discardAssistantMessage(itemID: String) {
        ignoredAssistantItemIDs.remove(itemID)
        guard let messageID = assistantMessageIDsByItemID.removeValue(forKey: itemID) else {
            return
        }

        messages.removeAll { $0.id == messageID }
        if pendingAssistantMessageID == nil, isGenerating {
            let replacement = ChatMessage(role: .assistant, text: "", isStreaming: true)
            pendingAssistantMessageID = replacement.id
            messages.append(replacement)
        }
    }

    private func finishTurn(status: AssistantTurnStatus, failure: AssistantTurnFailure?) {
        activeTurnID = nil
        activeSubmissionToken = nil
        isGenerating = false
        modelActivityText = nil

        for index in messages.indices where messages[index].role == .assistant {
            messages[index].isStreaming = false
        }

        if let pendingAssistantMessageID,
           let index = messages.firstIndex(where: { $0.id == pendingAssistantMessageID }),
           messages[index].text.isEmpty {
            messages.remove(at: index)
        }
        pendingAssistantMessageID = nil
        assistantMessageIDsByItemID.removeAll(keepingCapacity: true)
        ignoredAssistantItemIDs.removeAll(keepingCapacity: true)

        if status == .failed {
            errorMessage = failure?.additionalDetails ?? failure?.message ?? "ChatGPT could not finish that answer."
        }
    }

    private func finishGenerationWithError(_ message: String) {
        activeTurnID = nil
        activeSubmissionToken = nil
        isGenerating = false
        modelActivityText = nil
        errorMessage = message

        if let pendingAssistantMessageID,
           let index = messages.firstIndex(where: { $0.id == pendingAssistantMessageID }),
           messages[index].text.isEmpty {
            messages.remove(at: index)
        }
        self.pendingAssistantMessageID = nil
        assistantMessageIDsByItemID.removeAll(keepingCapacity: true)
        ignoredAssistantItemIDs.removeAll(keepingCapacity: true)
    }

    private func applyWorkingDirectoryChange(_ directoryURL: URL?) async -> Bool {
        let resetToken = UUID()
        conversationResetToken = resetToken
        isResettingConversation = true
        clearLocalConversation()

        defer {
            if conversationResetToken == resetToken {
                conversationResetToken = nil
                isResettingConversation = false
            }
        }

        await client.setWorkingDirectory(directoryURL)

        do {
            let threadID = try await client.resetConversation()
            guard conversationResetToken == resetToken else { return false }
            activeThreadID = threadID
            return true
        } catch {
            guard conversationResetToken == resetToken else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func clearLocalConversation() {
        discardScreenshotFiles()
        messages.removeAll()
        pendingAttachments.removeAll()
        activeThreadID = nil
        activeTurnID = nil
        activeSubmissionToken = nil
        pendingAssistantMessageID = nil
        assistantMessageIDsByItemID.removeAll()
        ignoredAssistantItemIDs.removeAll()
        isGenerating = false
        modelActivityText = nil
        errorMessage = workingDirectoryPreferenceError
        clearInputError()
    }

    private func discardScreenshotFiles() {
        let attachments = messages.flatMap(\.attachments) + pendingAttachments
        let uniqueURLs = Set(attachments.map { $0.fileURL.standardizedFileURL })
        for fileURL in uniqueURLs {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func setInputError(_ error: Error) {
        inputErrorMessage = error.localizedDescription

        if let microphoneError = error as? MicrophoneRecorderError,
           microphoneError == .permissionDenied {
            inputPermissionAction = .microphone
            return
        }

        if let screenshotError = error as? OverlayScreenshotServiceError {
            switch screenshotError {
            case .screenRecordingPermissionRequired:
                inputPermissionAction = .screenCapture
                return
            case .restartRequiredAfterPermissionGrant:
                inputPermissionAction = .restartAtmosphere
                return
            default:
                break
            }
        }

        inputPermissionAction = nil
    }

    private func clearInputError() {
        inputErrorMessage = nil
        inputPermissionAction = nil
    }

    private func updateMessage(id: UUID, update: (inout ChatMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        update(&messages[index])
    }

    private func beginLoginTimeout() {
        loginTimeoutTask?.cancel()
        loginTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 120 * 1_000_000_000)
            } catch {
                return
            }

            guard let self, self.isConnecting else { return }
            try? await self.client.cancelLogin()
            guard self.isConnecting else { return }
            self.isConnecting = false
            self.requiresAuthentication = true
            self.connectionStatus = .authenticationRequired
            self.errorMessage = "ChatGPT sign-in timed out. Try again when you're ready."
            self.loginTimeoutTask = nil
        }
    }
}

#if DEBUG
extension ChatViewModel {
    /// Populates the transcript so `--render-overlay-previews` can capture the
    /// real view hierarchy without a live App Server connection.
    func applyPreviewFixture(streaming: Bool) {
        connectionStatus = .connected
        messages = [
            ChatMessage(
                role: .user,
                text: "What changed in the Swift 6 concurrency model, and what should I migrate first?"
            ),
            ChatMessage(
                role: .assistant,
                text: """
                Swift 6 turns data-race safety into a **compile-time** guarantee \
                rather than a convention.

                - `Sendable` checking is now enforced across every isolation boundary
                - Global mutable state must be isolated or immutable
                - `@MainActor` inference follows the declaration, not the call site

                Migrate in this order:

                1. Turn on strict concurrency in Swift 5 mode first
                2. Annotate your model layer
                3. Only then flip the language mode

                ```swift
                @MainActor final class OverlayChrome: ObservableObject {
                    @Published var isShortcutsVisible = false
                }
                ```
                """,
                isStreaming: streaming
            )
        ]
        if streaming {
            isGenerating = true
            modelActivityText = "Reviewing the concurrency proposal"
            messages[1].text = ""
        }
    }

    func applyPreviewAuthenticationState() {
        requiresAuthentication = true
        connectionStatus = .authenticationRequired
    }

    func applyPreviewRecordingState() {
        connectionStatus = .connected
        isRecordingVoice = true
    }
}
#endif

private enum ChatViewModelError: LocalizedError {
    case couldNotOpenLoginPage

    var errorDescription: String? {
        switch self {
        case .couldNotOpenLoginPage:
            return "Could not open the ChatGPT sign-in page."
        }
    }
}
