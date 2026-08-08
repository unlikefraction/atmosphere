import AppKit
import SwiftUI

/// The overlay's whole surface: one prompt line that grows into a conversation.
///
/// The panel is deliberately two-state. Idle, it is a single Spotlight-height
/// bar with a quiet footer. The moment there is something to show it expands to
/// a fixed conversation height and stays there, so streaming text never makes
/// the window breathe in and out under the pointer.
struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var permissionController: SystemPermissionController
    @ObservedObject var chrome: OverlayChrome
    let onDismiss: () -> Void
    let onCaptureScreenshot: () -> Void
    let onChooseWorkingDirectory: () -> Void
    let onRemoveWorkingDirectory: () -> Void
    let onOverlayOpacityChange: (Double) -> Void
    let onPreferredHeightChange: (CGFloat) -> Void
    let onRestart: () -> Bool
    let onQuit: () -> Void

    @State private var draft = ""
    @State private var shouldSubmitAfterCapture = false
    @State private var isOverlayVisible = false
    @State private var inputInteractionGeneration: UInt = 0
    @State private var focusRequestGeneration: UInt = 0
    @State private var composerFocused = false
    @State private var composerHeight = ComposerTextScrollView.minimumHeight
    @State private var selectAllGeneration: UInt = 0
    @State private var skyPhase = SkyPhase.now()
    @State private var history: [String] = []
    @State private var historyCursor = PromptHistoryCursor()
    @State private var didCopyLastAnswer = false

    private let historyStore = PromptHistoryStore()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            panelBackground

            VStack(spacing: 0) {
                // Answers above, prompt below: the reading order of a
                // conversation, and the prompt stays put as the panel grows.
                if isExpanded {
                    expandedBody
                        .frame(height: bodyHeight)
                        // The sky belongs above the conversation, never behind
                        // the prompt — a moon next to the caret is a mistake.
                        .background(alignment: .top) {
                            SkyBackdrop(phase: skyPhase)
                        }
                        .clipped()
                    Hairline()
                }

                if !viewModel.pendingAttachments.isEmpty {
                    attachmentStrip
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                if statusLineVisible {
                    statusLine
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                commandBar

                Hairline()
                FooterBar(
                    viewModel: viewModel,
                    permissionController: permissionController,
                    chrome: chrome,
                    isCompact: !isExpanded,
                    skyPhase: skyPhase,
                    showsCopyConfirmation: didCopyLastAnswer,
                    onChooseWorkingDirectory: onChooseWorkingDirectory,
                    onRemoveWorkingDirectory: onRemoveWorkingDirectory,
                    onOverlayOpacityChange: onOverlayOpacityChange,
                    onResolvePermission: resolvePermission,
                    onNewConversation: beginNewConversation,
                    onSwitchModel: {
                        resetComposer()
                        Task { await viewModel.switchModel() }
                    },
                    onClearAndHide: clearAndHide,
                    onDismiss: onDismiss,
                    onQuit: onQuit
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: Atmo.Radius.panel, style: .continuous))

            if chrome.isShortcutsVisible {
                ShortcutsSheet(phase: skyPhase) { chrome.isShortcutsVisible = false }
                    .transition(
                        .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
                    )
                    .zIndex(2)
            }
        }
        .rimStroke(RoundedRectangle(cornerRadius: Atmo.Radius.panel, style: .continuous))
        .animation(motion(Atmo.Motion.content), value: isExpanded)
        .animation(motion(Atmo.Motion.content), value: statusLineVisible)
        .animation(motion(Atmo.Motion.content), value: viewModel.pendingAttachments.map(\.id))
        .animation(motion(Atmo.Motion.quick), value: chrome.isShortcutsVisible)
        .onAppear {
            history = historyStore.load()
            reportPreferredHeight()
        }
        .onChange(of: preferredHeight) { _, _ in reportPreferredHeight() }
        .onReceive(NotificationCenter.default.publisher(for: .atmosphereOverlayDidShow)) { _ in
            isOverlayVisible = true
            skyPhase = SkyPhase.now()
            focusRequestGeneration &+= 1
            let requestGeneration = focusRequestGeneration
            composerFocused = false
            DispatchQueue.main.async {
                guard isOverlayVisible,
                      focusRequestGeneration == requestGeneration else { return }
                composerFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .atmosphereOverlayDidHide)) { _ in
            isOverlayVisible = false
            focusRequestGeneration &+= 1
            composerFocused = false
            shouldSubmitAfterCapture = false
            inputInteractionGeneration &+= 1
            chrome.isShortcutsVisible = false
            didCopyLastAnswer = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .atmosphereToggleVoiceInput)) { _ in
            toggleVoiceInput()
        }
        .onChange(of: chrome.pendingCommand) { _, envelope in
            guard let envelope else { return }
            perform(envelope.command)
        }
        .onChange(of: viewModel.isCapturingScreenshot) { _, isCapturing in
            guard !isCapturing, shouldSubmitAfterCapture, isOverlayVisible else { return }
            shouldSubmitAfterCapture = false
            if canSubmit {
                send()
            }
        }
        .onChange(of: viewModel.canSend) { _, canSend in
            if canSend {
                composerFocused = true
            }
        }
        .onExitCommand(perform: handleEscape)
    }

    // MARK: - Surface

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Atmo.Radius.panel, style: .continuous)
    }

    @ViewBuilder
    private var panelBackground: some View {
        if #available(macOS 26.0, *) {
            panelShape
                .fill(Color.clear)
                .glassEffect(.regular, in: panelShape)
        } else {
            panelShape.fill(.regularMaterial)
        }
    }

    // MARK: - Command bar

    private var commandBar: some View {
        HStack(alignment: .center, spacing: 10) {
            leadingMark

            ComposerTextView(
                text: $draft,
                isFocused: $composerFocused,
                measuredHeight: $composerHeight,
                selectAllGeneration: selectAllGeneration,
                isEnabled: viewModel.canSend,
                font: Atmo.Font.prompt,
                placeholder: placeholder,
                onSubmit: send,
                onEdit: { historyCursor.reset() }
            )
            .frame(height: composerHeight)
            .disabled(!viewModel.canSend)

            trailingControls
        }
        .padding(.horizontal, Atmo.Metric.gutter)
        .padding(.vertical, Atmo.Metric.barVerticalPadding)
        .frame(minHeight: Atmo.Metric.barMinimumHeight)
        .contentShape(Rectangle())
        .onTapGesture { composerFocused = true }
    }

    /// The mark doubles as the state light: it drifts while the model works and
    /// gives way to a recording indicator while the microphone is open.
    private var leadingMark: some View {
        ZStack {
            if viewModel.isRecordingVoice {
                VoicePulse()
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            } else {
                AtmosphereMark(size: 21, phase: skyPhase, isWorking: viewModel.isGenerating)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .frame(width: 24, height: 24)
        .animation(motion(Atmo.Motion.quick), value: viewModel.isRecordingVoice)
        .accessibilityHidden(true)
    }

    private var trailingControls: some View {
        HStack(spacing: 2) {
            Button(action: toggleVoiceInput) {
                Group {
                    if viewModel.isPreparingVoice || viewModel.isTranscribingVoice {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: viewModel.isRecordingVoice ? "stop.fill" : "mic.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
            }
            .buttonStyle(
                AtmoIconButtonStyle(tint: viewModel.isRecordingVoice ? Atmo.Palette.danger : nil)
            )
            .disabled(!viewModel.isRecordingVoice && !viewModel.canStartVoiceInput)
            .help(viewModel.isRecordingVoice ? "Stop, transcribe, and send  \\" : "Voice input  \\")
            .accessibilityLabel(viewModel.isRecordingVoice ? "Stop voice input" : "Start voice input")

            Button(action: onCaptureScreenshot) {
                Group {
                    if viewModel.isCapturingScreenshot {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 13, weight: .medium))
                    }
                }
            }
            .buttonStyle(AtmoIconButtonStyle())
            .disabled(viewModel.isCapturingScreenshot)
            .help("Attach a silent screenshot  `")
            .accessibilityLabel("Attach screen screenshot")

            if viewModel.isGenerating {
                Button {
                    Task { await viewModel.cancelGeneration() }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(AtmoIconButtonStyle(side: 26, tint: Atmo.Palette.danger))
                .help("Stop generating  ⌘.")
                .accessibilityLabel("Stop generating")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11.5, weight: .bold))
                }
                .buttonStyle(AtmoIconButtonStyle(side: 26, prominent: true))
                .disabled(!canSubmit)
                .help("Send  ⏎")
                .accessibilityLabel("Send")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(motion(Atmo.Motion.quick), value: viewModel.isGenerating)
    }

    private var placeholder: String {
        if viewModel.requiresAuthentication { return "Connect ChatGPT to begin" }
        if viewModel.isGenerating { return "Ask a follow-up…" }
        return "Ask anything"
    }

    // MARK: - Expanded body

    @ViewBuilder
    private var expandedBody: some View {
        if viewModel.requiresAuthentication {
            AuthenticationPane(viewModel: viewModel, phase: skyPhase)
        } else if viewModel.messages.isEmpty {
            IdleErrorPane(message: viewModel.errorMessage) {
                Task { await viewModel.connect() }
            }
        } else {
            messageList
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    ForEach(viewModel.messages) { message in
                        MessageRow(
                            message: message,
                            activityText: message.isStreaming ? viewModel.modelActivityText : nil,
                            phase: skyPhase
                        )
                        .id(message.id)
                    }

                    if let error = viewModel.errorMessage {
                        ErrorStrip(message: error) {
                            Task { await viewModel.connect() }
                        }
                    }

                    Color.clear.frame(height: 1).id(Self.scrollAnchorID)
                }
                .padding(.horizontal, 18)
                // A band of clear sky above the first message, so the hour has
                // somewhere to live that is not behind a line of text.
                .padding(.top, 30)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.automatic)
            .mask(scrollFade)
            .onChange(of: viewModel.messages.last?.text) { _, _ in
                scroll(proxy, animated: viewModel.messages.last?.isStreaming != true)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                scroll(proxy, animated: true)
            }
        }
    }

    private static let scrollAnchorID = "atmosphere.conversation.bottom"

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard animated, !reduceMotion else {
            proxy.scrollTo(Self.scrollAnchorID, anchor: .bottom)
            return
        }
        withAnimation(.easeOut(duration: 0.16)) {
            proxy.scrollTo(Self.scrollAnchorID, anchor: .bottom)
        }
    }

    /// Content should dissolve into the chrome at both edges rather than being
    /// guillotined by a hard clip.
    private var scrollFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.028),
                .init(color: .black, location: 0.972),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Accessory rows

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.pendingAttachments) { attachment in
                    ScreenshotThumbnail(attachment: attachment, height: 54) {
                        viewModel.removePendingAttachment(attachment)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
            }
            .padding(.leading, Atmo.Metric.promptColumn - 5)
            .padding(.trailing, Atmo.Metric.gutter)
            .padding(.bottom, 6)
        }
        .frame(height: Atmo.Metric.attachmentStripHeight)
    }

    private var statusLineVisible: Bool {
        viewModel.isPreparingVoice ||
            viewModel.isRecordingVoice ||
            viewModel.isTranscribingVoice ||
            viewModel.inputErrorMessage != nil
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 7) {
            if viewModel.isRecordingVoice {
                Text("Listening")
                    .foregroundStyle(Atmo.Palette.danger)
                Text("press \\ again to transcribe and send")
                    .foregroundStyle(Atmo.Palette.tertiary)
            } else if viewModel.isPreparingVoice {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
                Text("Starting microphone…").foregroundStyle(Atmo.Palette.secondary)
            } else if viewModel.isTranscribingVoice {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
                Text("Transcribing  English → Hindi → Hinglish → Urdu")
                    .foregroundStyle(Atmo.Palette.secondary)
            } else if let error = viewModel.inputErrorMessage {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Atmo.Palette.caution)
                Text(error)
                    .foregroundStyle(Atmo.Palette.secondary)
                    .lineLimit(1)
                if let action = viewModel.inputPermissionAction {
                    Button(action.buttonTitle) { resolvePermission(action) }
                        .buttonStyle(AtmoFooterButtonStyle())
                        .disabled(isResolving(action))
                }
            }
            Spacer(minLength: 0)
        }
        .font(Atmo.Font.footnote)
        .padding(.leading, Atmo.Metric.promptColumn)
        .padding(.trailing, Atmo.Metric.gutter)
        .padding(.bottom, 9)
        .frame(height: Atmo.Metric.statusLineHeight, alignment: .top)
    }

    // MARK: - Sizing

    /// How tall the area under the prompt should be for what it currently
    /// holds. The conversation tracks its own content so a two-line answer
    /// does not open a half-empty window.
    private var bodyHeight: CGFloat {
        guard !chrome.isShortcutsVisible else {
            return max(naturalBodyHeight, Atmo.Metric.shortcutsHeight)
        }
        return naturalBodyHeight
    }

    private var naturalBodyHeight: CGFloat {
        if viewModel.requiresAuthentication { return Atmo.Metric.authenticationHeight }
        if viewModel.messages.isEmpty { return Atmo.Metric.noticeHeight }
        // A conversation opens the panel to its full height once and keeps it
        // there. Tracking the transcript made the window resize on every token.
        return Atmo.Metric.conversationHeight
    }

    private var isExpanded: Bool {
        !viewModel.messages.isEmpty ||
            viewModel.requiresAuthentication ||
            viewModel.errorMessage != nil ||
            chrome.isShortcutsVisible
    }

    private var preferredHeight: CGFloat {
        var height = max(
            Atmo.Metric.barMinimumHeight,
            composerHeight + (Atmo.Metric.barVerticalPadding * 2)
        )
        if !viewModel.pendingAttachments.isEmpty {
            height += Atmo.Metric.attachmentStripHeight
        }
        if statusLineVisible {
            height += Atmo.Metric.statusLineHeight
        }
        if isExpanded {
            height += Atmo.Metric.hairline + bodyHeight
        }
        return height + Atmo.Metric.hairline + Atmo.Metric.footerHeight
    }

    private func reportPreferredHeight() {
        onPreferredHeightChange(preferredHeight.rounded())
    }

    private func motion(_ animation: Animation) -> Animation? {
        Atmo.Motion.maybe(animation, reduceMotion: reduceMotion)
    }

    // MARK: - Commands

    private func perform(_ command: AtmosphereCommand) {
        switch command {
        case .newConversation:
            beginNewConversation()
        case .switchModel:
            resetComposer()
            Task { await viewModel.switchModel() }
        case .clearAndHide:
            clearAndHide()
        case .focusPrompt:
            composerFocused = true
            selectAllGeneration &+= 1
        case .stopGenerating:
            guard viewModel.isGenerating else { return }
            Task { await viewModel.cancelGeneration() }
        case .copyLastAnswer:
            copyLastAnswer()
        case .historyOlder:
            guard let recalled = historyCursor.older(in: history, currentDraft: draft) else { return }
            draft = recalled
            composerFocused = true
        case .historyNewer:
            guard let recalled = historyCursor.newer(in: history) else { return }
            draft = recalled
            composerFocused = true
        case .toggleShortcuts, .chooseFolder, .opacityQuarter, .opacityHalf, .opacityFull:
            // Owned by the overlay controller, which holds the panel and the
            // system picker.
            break
        }
    }

    private func handleEscape() {
        if chrome.consumeEscape() { return }
        onDismiss()
    }

    private func copyLastAnswer() {
        guard let answer = viewModel.messages.last(where: {
            $0.role == .assistant && !$0.text.isEmpty
        }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer.text, forType: .string)
        withAnimation(motion(Atmo.Motion.quick)) { didCopyLastAnswer = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation(motion(Atmo.Motion.quick)) { didCopyLastAnswer = false }
        }
    }

    // MARK: - Sending

    private var canSubmit: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !viewModel.pendingAttachments.isEmpty) &&
            viewModel.canSend &&
            !viewModel.isPreparingVoice &&
            !viewModel.isRecordingVoice &&
            !viewModel.isTranscribingVoice &&
            !viewModel.isCapturingScreenshot
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !viewModel.pendingAttachments.isEmpty), canSubmit else { return }
        draft = ""
        historyCursor.reset()
        history = historyStore.record(text, in: history)
        viewModel.send(text)
    }

    private func toggleVoiceInput() {
        guard !viewModel.isPreparingVoice, !viewModel.isTranscribingVoice else { return }

        if viewModel.isRecordingVoice {
            let interactionGeneration = inputInteractionGeneration
            Task {
                guard let transcript = await viewModel.stopVoiceRecordingAndTranscribe() else {
                    return
                }
                guard isOverlayVisible,
                      inputInteractionGeneration == interactionGeneration else { return }
                let existing = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                draft = existing.isEmpty ? transcript : "\(existing) \(transcript)"
                if viewModel.isCapturingScreenshot {
                    shouldSubmitAfterCapture = true
                } else if canSubmit {
                    send()
                }
            }
        } else {
            Task {
                _ = await viewModel.startVoiceRecording()
            }
        }
    }

    private func beginNewConversation() {
        resetComposer()
        viewModel.newConversation()
        composerFocused = true
    }

    private func clearAndHide() {
        resetComposer()
        viewModel.clearConversation()
        onDismiss()
    }

    private func resetComposer() {
        draft = ""
        shouldSubmitAfterCapture = false
        inputInteractionGeneration &+= 1
        historyCursor.reset()
    }

    // MARK: - Permissions

    private func resolvePermission(_ action: InputPermissionAction) {
        switch action {
        case .microphone:
            Task {
                let outcome = await permissionController.resolveMicrophonePermission()
                finishPermissionResolution(outcome, action: action)
            }

        case .screenCapture:
            let outcome = permissionController.resolveScreenCapturePermission()
            finishPermissionResolution(outcome, action: action)

        case .restartAtmosphere:
            if !onRestart() {
                viewModel.reportApplicationRestartFailure()
            }
        }
    }

    private func finishPermissionResolution(
        _ outcome: PermissionResolutionOutcome,
        action: InputPermissionAction
    ) {
        permissionController.refresh()
        viewModel.clearResolvedPermissionError(
            microphoneGranted: permissionController.microphoneStatus.isGranted,
            screenCaptureGranted: permissionController.isScreenCaptureReady
        )
        switch outcome {
        case .restartRequired:
            viewModel.reportScreenCaptureRestartRequired()
        case .openedSettings:
            onDismiss()
        case .unavailable:
            viewModel.reportPermissionSettingsUnavailable(for: action)
        case .granted:
            break
        }
    }

    private func isResolving(_ action: InputPermissionAction) -> Bool {
        switch action {
        case .microphone: return permissionController.isResolvingMicrophone
        case .screenCapture: return permissionController.isResolvingScreenCapture
        case .restartAtmosphere: return false
        }
    }
}

// MARK: - Footer

/// The quiet band along the bottom: state you glance at, never read.
private struct FooterBar: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var permissionController: SystemPermissionController
    @ObservedObject var chrome: OverlayChrome
    let isCompact: Bool
    let skyPhase: SkyPhase
    let showsCopyConfirmation: Bool
    let onChooseWorkingDirectory: () -> Void
    let onRemoveWorkingDirectory: () -> Void
    let onOverlayOpacityChange: (Double) -> Void
    let onResolvePermission: (InputPermissionAction) -> Void
    let onNewConversation: () -> Void
    let onSwitchModel: () -> Void
    let onClearAndHide: () -> Void
    let onDismiss: () -> Void
    let onQuit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: skyPhase.glyph)
                .font(.system(size: 10))
                .foregroundStyle(Atmo.Palette.tertiary)
                .help(skyPhase.greeting)
                .accessibilityLabel(skyPhase.greeting)

            ConnectionDot(status: viewModel.connectionStatus)
                .help("\(viewModel.activeModel.providerName): \(viewModel.connectionStatus.label)")

            if showsCopyConfirmation {
                Label("Copied", systemImage: "checkmark")
                    .font(Atmo.Font.micro)
                    .foregroundStyle(Atmo.Palette.ready)
                    .fixedSize()
                    .transition(.opacity)
            } else {
                Button {
                    onSwitchModel()
                } label: {
                    HStack(spacing: 4) {
                        if viewModel.isSwitchingModel {
                            ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 10, height: 10)
                        }
                        Text(viewModel.activeModel.shortTitle)
                            .fixedSize()
                    }
                }
                .buttonStyle(AtmoFooterButtonStyle())
                .disabled(viewModel.isSwitchingModel)
                .help(viewModel.activeModel.helpText)
                .accessibilityLabel("Answer model, \(viewModel.activeModel.shortTitle). Switch with Command M")
            }

            FolderChip(
                directory: viewModel.selectedWorkingDirectory,
                isWorking: viewModel.isChangingWorkingDirectory,
                isEnabled: viewModel.canChangeWorkingDirectory,
                onChoose: onChooseWorkingDirectory,
                onRemove: onRemoveWorkingDirectory
            )

            if !permissionController.microphoneStatus.isGranted {
                PermissionChip(title: "Mic", systemImage: "mic.slash.fill", status: .permissionRequired, isWorking: permissionController.isResolvingMicrophone) {
                    onResolvePermission(.microphone)
                }
            }

            if permissionController.screenCaptureStatus != .granted {
                PermissionChip(
                    title: "Screen",
                    systemImage: permissionController.screenCaptureStatus == .restartRequired
                        ? "arrow.clockwise" : "display",
                    status: permissionController.screenCaptureStatus,
                    isWorking: permissionController.isResolvingScreenCapture
                ) {
                    onResolvePermission(
                        permissionController.screenCaptureRequiresRestart
                            ? .restartAtmosphere : .screenCapture
                    )
                }
            }

            Spacer(minLength: 8)

            if isCompact {
                HStack(spacing: 10) {
                    ShortcutHint(keys: ["\\"], caption: "voice")
                    ShortcutHint(keys: ["`"], caption: "screen")
                }
                .transition(.opacity)
                .layoutPriority(-1)
            }

            Button {
                chrome.isShortcutsVisible.toggle()
            } label: {
                HStack(spacing: 3) {
                    KeyCap("⌘")
                    KeyCap("/")
                }
            }
            .buttonStyle(AtmoFooterButtonStyle())
            .help("Keyboard shortcuts  ⌘/")
            .accessibilityLabel("Keyboard shortcuts")

            OpacityMenu(opacity: chrome.opacity, onChange: onOverlayOpacityChange)

            Menu {
                Button("New Conversation", systemImage: "square.and.pencil", action: onNewConversation)
                    .keyboardShortcut("n")
                Button("Clear and Hide", systemImage: "eraser", action: onClearAndHide)
                Divider()
                Button(
                    "Switch to \(viewModel.activeModel.next.menuTitle)",
                    systemImage: "arrow.triangle.2.circlepath",
                    action: onSwitchModel
                )
                Divider()
                Button("Keyboard Shortcuts", systemImage: "keyboard") {
                    chrome.isShortcutsVisible = true
                }
                Divider()
                Button("Hide Atmosphere", systemImage: "eye.slash", action: onDismiss)
                Button("Quit Atmosphere", systemImage: "power", action: onQuit)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Atmo.Palette.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 20)
            .help("More")
            .accessibilityLabel("More options")
        }
        .padding(.horizontal, Atmo.Metric.gutter)
        .frame(height: Atmo.Metric.footerHeight)
        .background(Color.primary.opacity(0.035))
    }
}

private struct ConnectionDot: View {
    let status: ChatConnectionStatus
    @State private var isPulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 6, height: 6)
            .overlay {
                Circle()
                    .stroke(status.color.opacity(0.5), lineWidth: 1)
                    .scaleEffect(isPulsing ? 2.1 : 1)
                    .opacity(isPulsing ? 0 : 0.9)
            }
            .onAppear { startPulseIfNeeded() }
            .onChange(of: status) { _, _ in startPulseIfNeeded() }
            .accessibilityLabel("Connection \(status.label)")
    }

    private func startPulseIfNeeded() {
        guard status == .connecting, !reduceMotion else {
            isPulsing = false
            return
        }
        isPulsing = false
        withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
            isPulsing = true
        }
    }
}

private struct FolderChip: View {
    let directory: URL?
    let isWorking: Bool
    let isEnabled: Bool
    let onChoose: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 1) {
            Button(action: onChoose) {
                HStack(spacing: 4) {
                    if isWorking {
                        ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 10, height: 10)
                    } else {
                        Image(systemName: directory == nil ? "folder.badge.plus" : "folder.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(directory == nil ? Atmo.Palette.tertiary : Atmo.Palette.accent)
                    }
                    Text(directory?.lastPathComponent ?? "Folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 150, alignment: .leading)
                        .fixedSize()
                }
            }
            .buttonStyle(AtmoFooterButtonStyle())
            .disabled(!isEnabled || isWorking)
            .help(directory?.path ?? "Choose a folder Atmosphere can inspect read-only  ⌘O")
            .accessibilityLabel(
                directory.map { "Change operating folder, \($0.lastPathComponent)" }
                    ?? "Choose operating folder"
            )
            .contextMenu {
                if let directory {
                    Button("Show in Finder", systemImage: "finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([directory])
                    }
                    Button("Remove Folder", systemImage: "minus.circle", role: .destructive, action: onRemove)
                }
            }

            if directory != nil {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(AtmoIconButtonStyle(side: 16))
                .disabled(!isEnabled || isWorking)
                .help("Remove operating folder")
                .accessibilityLabel("Remove operating folder")
            }
        }
    }
}

private struct PermissionChip: View {
    let title: String
    let systemImage: String
    let status: ScreenCapturePermissionStatus
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isWorking {
                    ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 10, height: 10)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(status == .restartRequired ? "Restart for \(title)" : "\(title) off")
                    .fixedSize()
            }
            .foregroundStyle(Atmo.Palette.caution)
        }
        .buttonStyle(AtmoFooterButtonStyle())
        .disabled(isWorking)
        .help(helpText)
        .accessibilityLabel(accessibilityText)
    }

    private var helpText: String {
        switch status {
        case .granted: return "\(title) permission is granted"
        case .permissionRequired: return "\(title) permission is off — open Privacy & Security"
        case .restartRequired: return "Restart Atmosphere to finish enabling \(title.lowercased()) capture"
        }
    }

    private var accessibilityText: String {
        switch status {
        case .granted: return "\(title) permission granted"
        case .permissionRequired: return "\(title) permission off. Open Privacy and Security settings"
        case .restartRequired: return "\(title) permission granted. Restart Atmosphere to finish enabling it"
        }
    }
}

private struct OpacityMenu: View {
    let opacity: Double
    let onChange: (Double) -> Void

    var body: some View {
        Menu {
            ForEach(OverlayOpacityPreference.options, id: \.self) { option in
                Button {
                    onChange(option)
                } label: {
                    HStack {
                        Text("\(Int(option * 100))%")
                        if abs(option - opacity) < 0.001 {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .keyboardShortcut(shortcutKey(for: option))
            }
        } label: {
            Image(systemName: symbolName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Atmo.Palette.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 20)
        .foregroundStyle(Atmo.Palette.secondary)
        .help("Panel opacity: \(Int((opacity * 100).rounded()))%  ⌘1 ⌘2 ⌘3")
        .accessibilityLabel("Panel opacity")
        .accessibilityValue("\(Int((opacity * 100).rounded())) percent")
    }

    private var symbolName: String { "circle.lefthalf.filled" }

    private func shortcutKey(for option: Double) -> KeyEquivalent {
        if option <= 0.3 { return "1" }
        if option <= 0.6 { return "2" }
        return "3"
    }
}

// MARK: - Panes

private struct AuthenticationPane: View {
    @ObservedObject var viewModel: ChatViewModel
    let phase: SkyPhase

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            AtmosphereMark(size: 56, phase: phase)

            VStack(spacing: 5) {
                Text("Connect ChatGPT")
                    .font(Atmo.Font.display(size: 22))
                Text("Atmosphere answers through the Codex service included with the ChatGPT app. Credentials stay with that service.")
                    .font(.system(size: 12))
                    .foregroundStyle(Atmo.Palette.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            Button {
                Task { await viewModel.startChatGPTLogin() }
            } label: {
                HStack(spacing: 7) {
                    if viewModel.isConnecting {
                        ProgressView().controlSize(.small)
                    }
                    Text(viewModel.isConnecting ? "Connecting…" : "Continue with ChatGPT")
                        .font(.system(size: 13, weight: .medium))
                }
                .frame(minWidth: 180)
                .padding(.vertical, 7)
                .padding(.horizontal, 14)
                .background(Atmo.Palette.accent, in: Capsule())
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isConnecting)

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Atmo.Palette.danger)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct IdleErrorPane: View {
    let message: String?
    let retry: () -> Void

    var body: some View {
        VStack {
            Spacer()
            if let message {
                ErrorStrip(message: message, retry: retry)
                    .frame(maxWidth: 460)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - Messages

private struct MessageRow: View {
    let message: ChatMessage
    let activityText: String?
    let phase: SkyPhase

    @State private var isHovering = false
    @State private var didCopy = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            if isUser { Spacer(minLength: 60) }

            if !isUser {
                AtmosphereMark(size: 15, phase: phase)
                    .padding(.top, 2)
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 7) {
                if !message.attachments.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(message.attachments) { attachment in
                            ScreenshotThumbnail(attachment: attachment, height: 104)
                        }
                    }
                    .frame(maxWidth: contentWidth, alignment: isUser ? .trailing : .leading)
                }

                if !message.text.isEmpty {
                    Group {
                        if isUser {
                            Text(message.text)
                                .font(Atmo.Font.message)
                                .lineSpacing(2.5)
                                .textSelection(.enabled)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: Atmo.Radius.bubble, style: .continuous)
                                        .fill(Atmo.Palette.accent.opacity(0.20))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: Atmo.Radius.bubble, style: .continuous)
                                        .strokeBorder(Atmo.Palette.accent.opacity(0.18), lineWidth: 0.5)
                                )
                        } else {
                            MarkdownMessageView(
                                messageID: message.id,
                                source: message.text,
                                isStreaming: message.isStreaming
                            )
                        }
                    }
                    .frame(maxWidth: contentWidth, alignment: isUser ? .trailing : .leading)
                }

                if message.role == .assistant, message.isStreaming, message.text.isEmpty {
                    ActivityLine(text: activityText)
                }
            }
            .overlay(alignment: isUser ? .topLeading : .topTrailing) {
                if message.role == .assistant, !message.text.isEmpty, !message.isStreaming, isHovering {
                    copyButton
                        .offset(x: isUser ? -6 : 6)
                        .transition(.opacity)
                }
            }
            .onHover { hovering in
                withAnimation(Atmo.Motion.maybe(Atmo.Motion.hover, reduceMotion: reduceMotion)) {
                    isHovering = hovering
                }
                if !hovering { didCopy = false }
            }

            if !isUser { Spacer(minLength: 20) }
        }
    }

    private var contentWidth: CGFloat { isUser ? 440 : 600 }

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.text, forType: .string)
            withAnimation(Atmo.Motion.maybe(Atmo.Motion.quick, reduceMotion: reduceMotion)) {
                didCopy = true
            }
        } label: {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(AtmoIconButtonStyle(side: 22))
        .help("Copy answer  ⌘⇧C")
        .accessibilityLabel("Copy answer")
    }
}

/// The pre-text state of an answer. A travelling shimmer says "working" more
/// calmly than a spinner and matches how the system treats indeterminate text.
private struct ActivityLine: View {
    let text: String?
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text ?? "Thinking…")
            .font(.system(size: 12))
            .foregroundStyle(Atmo.Palette.secondary)
            .lineLimit(2)
            .overlay {
                if !reduceMotion {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white.opacity(0.75), location: 0.5),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 90)
                    .offset(x: phase * 260)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
                }
            }
            .mask(
                Text(text ?? "Thinking…")
                    .font(.system(size: 12))
                    .lineLimit(2)
            )
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1.6
                }
            }
            .accessibilityLabel(text ?? "Thinking")
    }
}

private struct ScreenshotThumbnail: View {
    let attachment: ChatAttachment
    let height: CGFloat
    var onRemove: (() -> Void)?

    @State private var isHovering = false

    init(attachment: ChatAttachment, height: CGFloat, onRemove: (() -> Void)? = nil) {
        self.attachment = attachment
        self.height = height
        self.onRemove = onRemove
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = NSImage(contentsOf: attachment.fileURL) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Color.primary.opacity(0.06)
                        Image(systemName: "photo")
                            .foregroundStyle(Atmo.Palette.tertiary)
                    }
                }
            }
            .frame(width: height * 1.6, height: height)
            .clipShape(RoundedRectangle(cornerRadius: Atmo.Radius.thumbnail, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Atmo.Radius.thumbnail, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)

            if let onRemove, isHovering || onRemove != nil {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(Color.black.opacity(0.62)))
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
                .help("Remove screenshot")
                .accessibilityLabel("Remove screenshot")
            }
        }
        .padding(onRemove == nil ? 0 : 5)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Screen screenshot attachment")
    }
}

// MARK: - Shared parts

private struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.09))
            .frame(height: Atmo.Metric.hairline)
    }
}

/// Three bars breathing at different rates — legible as "the microphone is
/// live" at a glance, and cheap enough to run for minutes.
private struct VoicePulse: View {
    @State private var isAnimating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let heights: [CGFloat] = [7, 14, 10]
    private let durations: [Double] = [0.42, 0.53, 0.47]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(Atmo.Palette.danger)
                    .frame(width: 2.5, height: isAnimating ? heights[index] : 3)
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: durations[index]).repeatForever(autoreverses: true),
                        value: isAnimating
                    )
            }
        }
        .frame(width: 22, height: 16)
        .onAppear { isAnimating = true }
        .accessibilityLabel("Recording")
    }
}

private struct ErrorStrip: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Atmo.Palette.caution)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(Atmo.Palette.secondary)
                .lineLimit(3)
            Spacer(minLength: 6)
            Button("Retry", action: retry)
                .buttonStyle(AtmoFooterButtonStyle())
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Atmo.Palette.caution.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Atmo.Palette.caution.opacity(0.22), lineWidth: 0.5)
        )
    }
}

// MARK: - Shortcut sheet

private struct ShortcutsSheet: View {
    let phase: SkyPhase
    let onClose: () -> Void

    private let bareKeys: [(keys: [String], title: String)] = [
        (["⌘", "\\"], "Show or hide Atmosphere"),
        (["\\"], "Voice input, then send"),
        (["`"], "Attach a silent screenshot"),
        (["⏎"], "Send"),
        (["⇧", "⏎"], "New line"),
        (["esc"], "Hide")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                AtmosphereMark(size: 17, phase: phase)
                Text("Keyboard")
                    .font(Atmo.Font.display(size: 16))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(AtmoIconButtonStyle(side: 22))
                .accessibilityLabel("Close shortcuts")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Hairline().opacity(0.6)

            ScrollView {
                HStack(alignment: .top, spacing: 26) {
                    column(rows: bareKeys, heading: "Essentials")
                    column(
                        rows: AtmosphereCommand.allCases.map { ($0.keys, $0.title) },
                        heading: "Commands"
                    )
                }
                .padding(16)
            }
            .scrollIndicators(.never)

            Spacer(minLength: 0)

            HStack {
                AtmosphereLockup(phase: phase)
                Spacer()
                Text(Bundle.main.shortVersionString)
                    .font(Atmo.Font.micro)
                    .foregroundStyle(Atmo.Palette.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Opaque, not translucent: a cheat sheet you can actually read
            // beats one that lets the transcript bleed through it.
            RoundedRectangle(cornerRadius: Atmo.Radius.panel, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: Atmo.Radius.panel, style: .continuous)
                        .fill(.regularMaterial)
                )
        }
    }

    private func column(rows: [(keys: [String], title: String)], heading: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(heading.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Atmo.Palette.tertiary)
                .padding(.bottom, 1)

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    Text(row.title)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Atmo.Palette.label)
                    Spacer(minLength: 12)
                    HStack(spacing: 3) {
                        ForEach(Array(row.keys.enumerated()), id: \.offset) { _, key in
                            KeyCap(key, emphasized: true)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Small extensions

private extension InputPermissionAction {
    var buttonTitle: String {
        switch self {
        case .microphone: return "Open Microphone"
        case .screenCapture: return "Open Screen Recording"
        case .restartAtmosphere: return "Restart Atmosphere"
        }
    }
}

extension ChatConnectionStatus {
    fileprivate var color: Color {
        switch self {
        case .connected: return Atmo.Palette.ready
        case .connecting: return Color(nsColor: .systemYellow)
        case .authenticationRequired: return Atmo.Palette.caution
        case .disconnected: return Color(nsColor: .systemGray)
        case .failed: return Atmo.Palette.danger
        }
    }
}
