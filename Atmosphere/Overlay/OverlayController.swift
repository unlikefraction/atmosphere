import AppKit
import CoreGraphics
import SwiftUI

extension Notification.Name {
    static let atmosphereOverlayDidShow = Notification.Name("atmosphere.overlayDidShow")
    static let atmosphereOverlayDidHide = Notification.Name("atmosphere.overlayDidHide")
    static let atmosphereToggleVoiceInput = Notification.Name("atmosphere.toggleVoiceInput")
}

@MainActor
final class OverlayController {
    private let panel: OverlayPanel
    private let viewModel: ChatViewModel
    private let screenshotService = OverlayScreenshotService()
    private let permissionController = SystemPermissionController()
    private let opacityPreference: OverlayOpacityPreference
    private let chrome: OverlayChrome
    private var overlayOpacity: Double
    private var localShortcutController: OverlayLocalShortcutController?
    private var workingDirectoryPanel: NSOpenPanel?
    private var screenshotCaptureTasks: [UUID: Task<Void, Never>] = [:]
    private var didPreparePanelFrame = false
    private var preferredContentHeight: CGFloat = OverlayController.initialHeight
    private var presentationGeneration: UInt = 0

    static let panelWidth: CGFloat = 720
    static let initialHeight: CGFloat = 88

    init(
        viewModel: ChatViewModel,
        opacityPreference: OverlayOpacityPreference = OverlayOpacityPreference()
    ) {
        self.viewModel = viewModel
        self.opacityPreference = opacityPreference
        overlayOpacity = opacityPreference.value()
        chrome = OverlayChrome(opacity: overlayOpacity)
        panel = OverlayPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: OverlayController.panelWidth,
                height: OverlayController.initialHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        configurePanel()

        let rootView = ChatView(
            viewModel: viewModel,
            permissionController: permissionController,
            chrome: chrome,
            onDismiss: { [weak self] in self?.hide() },
            onCaptureScreenshot: { [weak self] in self?.captureScreenshot() },
            onChooseWorkingDirectory: { [weak self] in self?.chooseWorkingDirectory() },
            onRemoveWorkingDirectory: { [weak self] in
                Task { @MainActor in
                    _ = await self?.viewModel.removeWorkingDirectory()
                }
            },
            onOverlayOpacityChange: { [weak self] opacity in
                self?.setOverlayOpacity(opacity)
            },
            onPreferredHeightChange: { [weak self] height in
                self?.setPreferredContentHeight(height)
            },
            onRestart: { ApplicationRelauncher.relaunch() },
            onQuit: { NSApp.terminate(nil) }
        )
        let hostingView = NSHostingView(rootView: rootView)
        // The panel is borderless and transparent, so nothing below SwiftUI may
        // paint its own rectangle: an unclipped backing layer shows up as a
        // squared-off slab peeking out from under the rounded corners.
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        hostingView.layer?.cornerRadius = Atmo.Radius.panel
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        panel.contentView = hostingView
        panel.onEscape = { [weak self] in
            guard let self else { return }
            if chrome.consumeEscape() { return }
            hide()
        }

        localShortcutController = OverlayLocalShortcutController(
            onToggleAudio: {
                NotificationCenter.default.post(
                    name: .atmosphereToggleVoiceInput,
                    object: nil
                )
            },
            onCaptureScreenshot: { [weak self] in
                self?.captureScreenshot()
            },
            onCommand: { [weak self] command in
                self?.perform(command)
            }
        )
    }

    /// Commands the panel owns. Everything else belongs to the SwiftUI tree,
    /// which holds the draft, the transcript, and the pasteboard actions.
    private func perform(_ command: AtmosphereCommand) {
        switch command {
        case .chooseFolder:
            chooseWorkingDirectory()
        case .toggleShortcuts:
            chrome.isShortcutsVisible.toggle()
        case .opacityQuarter:
            setOverlayOpacity(0.25)
        case .opacityHalf:
            setOverlayOpacity(0.5)
        case .opacityFull:
            setOverlayOpacity(1.0)
        default:
            chrome.dispatch(command)
        }
    }

    var isVisible: Bool {
        panel.isVisible
    }

    var captureSharingType: NSWindow.SharingType {
        panel.sharingType
    }

    var panelOpacity: Double {
        Double(panel.alphaValue)
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        presentationGeneration &+= 1
        refreshSystemPermissions()
        preparePanelFrameForDisplay()

        let destination = panel.frame
        let shouldAnimate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && !panel.isVisible

        if shouldAnimate {
            // Rise and resolve, rather than blink into existence. Origin-only
            // animation keeps the SwiftUI content off the animation's critical
            // path, so the first frame is already the final layout.
            panel.setFrame(destination.offsetBy(dx: 0, dy: -9), display: false)
            panel.alphaValue = 0
        } else {
            panel.alphaValue = CGFloat(overlayOpacity)
        }

        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        localShortcutController?.setEnabled(true)
        NotificationCenter.default.post(name: .atmosphereOverlayDidShow, object: nil)

        guard shouldAnimate else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Atmo.Motion.panelPresentDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(destination, display: true)
            panel.animator().alphaValue = CGFloat(overlayOpacity)
        }
    }

    func hide() {
        presentationGeneration &+= 1
        cancelWorkingDirectoryPanel()
        localShortcutController?.setEnabled(false)
        viewModel.invalidateVoiceInput()
        chrome.isShortcutsVisible = false
        savePanelFrame()
        orderOutPanel(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        NotificationCenter.default.post(name: .atmosphereOverlayDidHide, object: nil)
        viewModel.cancelScreenshotCapture()
        screenshotCaptureTasks.values.forEach { $0.cancel() }
        Task { await viewModel.cancelVoiceRecording() }
    }

    /// Fades out, then orders out on the next turn. The generation guard makes
    /// a show during the fade win outright instead of racing it.
    private func orderOutPanel(animated: Bool) {
        guard animated, panel.isVisible else {
            panel.orderOut(nil)
            panel.alphaValue = CGFloat(overlayOpacity)
            return
        }

        let generation = presentationGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Atmo.Motion.panelDismissDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, presentationGeneration == generation else { return }
            panel.orderOut(nil)
            panel.alphaValue = CGFloat(overlayOpacity)
        }
    }

    func shutdown() async {
        cancelWorkingDirectoryPanel()
        localShortcutController?.setEnabled(false)
        savePanelFrame()
        presentationGeneration &+= 1
        panel.orderOut(nil)
        NotificationCenter.default.post(name: .atmosphereOverlayDidHide, object: nil)
        viewModel.invalidateVoiceInput()
        let voiceCleanupTask = Task { await viewModel.cancelVoiceRecording() }
        viewModel.cancelScreenshotCapture()
        let tasks = Array(screenshotCaptureTasks.values)
        tasks.forEach { $0.cancel() }
        for task in tasks {
            await task.value
        }
        screenshotCaptureTasks.removeAll()
        await voiceCleanupTask.value
    }

    #if DEBUG
    /// Lets a Debug build be screenshotted while its design is being worked on.
    /// Release builds keep the best-effort capture exclusion unconditionally.
    static let allowCaptureArgument = "--allow-capture"

    func allowCaptureForDebugging() {
        panel.sharingType = .readOnly
    }

    func showShortcutsForDebugging() {
        chrome.isShortcutsVisible = true
    }
    #endif

    func refreshSystemPermissions() {
        permissionController.refresh()
        viewModel.clearResolvedPermissionError(
            microphoneGranted: permissionController.microphoneStatus.isGranted,
            screenCaptureGranted: permissionController.isScreenCaptureReady
        )
    }

    private func captureScreenshot() {
        guard let operationID = viewModel.beginScreenshotCapture() else { return }
        guard !permissionController.screenCaptureRequiresRestart else {
            viewModel.failScreenshotCapture(
                OverlayScreenshotServiceError.restartRequiredAfterPermissionGrant,
                operationID: operationID
            )
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { screenshotCaptureTasks[operationID] = nil }
            do {
                let fileURL: URL
                do {
                    fileURL = try await screenshotService.captureDisplay(containing: panel)
                } catch OverlayScreenshotServiceError.screenRecordingPermissionRequired {
                    // The grave-key press is an explicit user capture action,
                    // so this is the appropriate moment for macOS to ask.
                    guard CGRequestScreenCaptureAccess() else {
                        refreshSystemPermissions()
                        throw OverlayScreenshotServiceError.screenRecordingPermissionRequired
                    }
                    permissionController.markScreenCaptureRestartRequired()
                    refreshSystemPermissions()
                    // Apple documents that ScreenCaptureKit clients need a
                    // restart after the first permission grant.
                    throw OverlayScreenshotServiceError.restartRequiredAfterPermissionGrant
                }
                viewModel.finishScreenshotCapture(fileURL, operationID: operationID)
            } catch {
                viewModel.failScreenshotCapture(error, operationID: operationID)
            }
        }
        screenshotCaptureTasks[operationID] = task
    }

    private func chooseWorkingDirectory() {
        guard workingDirectoryPanel == nil,
              viewModel.canChangeWorkingDirectory else { return }

        // Bare ` and \ are reserved while the overlay is active. Suspend that
        // monitor while the system picker owns keyboard focus so typing a path
        // cannot accidentally start recording or capture the screen.
        localShortcutController?.setEnabled(false)

        let openPanel = NSOpenPanel()
        openPanel.title = "Choose Operating Folder"
        openPanel.message = "Atmosphere can inspect this folder read-only when a question needs more context."
        openPanel.prompt = "Use Folder"
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.canCreateDirectories = false
        openPanel.resolvesAliases = true
        openPanel.directoryURL = viewModel.selectedWorkingDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
        workingDirectoryPanel = openPanel

        // Atmosphere is an accessory app whose overlay intentionally does not
        // activate other apps. A modeless open panel can therefore be ordered
        // behind the floating overlay. This explicit user action is the one
        // place where activation is appropriate; attaching a sheet also keeps
        // the picker visually and spatially owned by Atmosphere.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)

        openPanel.beginSheetModal(for: panel) { [weak self, weak openPanel] response in
            Task { @MainActor in
                guard let self,
                      let openPanel,
                      self.workingDirectoryPanel === openPanel else { return }
                self.workingDirectoryPanel = nil

                if response == .OK, let directory = openPanel.url {
                    _ = await self.viewModel.selectWorkingDirectory(directory)
                }

                guard self.panel.isVisible else { return }
                self.panel.makeKeyAndOrderFront(nil)
                self.localShortcutController?.setEnabled(true)
                NotificationCenter.default.post(
                    name: .atmosphereOverlayDidShow,
                    object: nil
                )
            }
        }
    }

    private func cancelWorkingDirectoryPanel() {
        let openPanel = workingDirectoryPanel
        workingDirectoryPanel = nil
        openPanel?.cancel(nil)
    }

    private func configurePanel() {
        panel.title = "Atmosphere"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = CGFloat(overlayOpacity)
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        // Atmosphere animates its own presentation; AppKit's stock behavior
        // would fight the rise-and-settle above.
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .transient,
            .ignoresCycle
        ]

        // Compatibility hint used by Pluely/Tauri and older WindowServer
        // capture paths. Apple now calls this legacy and explicitly does not
        // guarantee that it prevents modern screen capture.
        panel.sharingType = .none

        panel.setAccessibilityTitle("Atmosphere assistant")
    }

    private func setOverlayOpacity(_ opacity: Double) {
        let normalizedOpacity = opacityPreference.save(opacity)
        overlayOpacity = normalizedOpacity
        chrome.setOpacity(normalizedOpacity)
        panel.alphaValue = CGFloat(normalizedOpacity)
    }

    /// Grow and collapse from the top edge, the way a search field's results
    /// unfurl beneath it. The prompt line must never move under the cursor.
    private func setPreferredContentHeight(_ height: CGFloat) {
        let clamped = max(OverlayController.initialHeight, height)
        guard abs(preferredContentHeight - clamped) > 0.5 else { return }
        preferredContentHeight = clamped
        guard panel.isVisible else {
            applyHeight(clamped, animated: false)
            return
        }
        applyHeight(clamped, animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func applyHeight(_ height: CGFloat, animated: Bool) {
        let current = panel.frame
        let frame = OverlayFramePersistence.frame(
            growing: current,
            to: height,
            within: (panelScreen() ?? NSScreen.main)?.visibleFrame
        )

        guard frame != current else { return }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(
                    controlPoints: 0.22, 0.86, 0.25, 1
                )
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        panel.invalidateShadow()
    }

    private func positionOnActiveScreen() {
        let screen = screenUnderPointer() ?? NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }

        let horizontalInset: CGFloat = 32
        let width = min(OverlayController.panelWidth, visibleFrame.width - (horizontalInset * 2))
        let height = min(preferredContentHeight, visibleFrame.height - 96)
        // The prompt sits at the bottom of the panel and answers grow upward,
        // so the anchor is chosen to leave a full conversation's worth of room
        // above it. That way expanding never has to move the prompt.
        let origin = NSPoint(
            x: (visibleFrame.midX - (width / 2)).rounded(),
            y: (visibleFrame.minY + (visibleFrame.height * 0.34)).rounded()
        )

        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }

    private func panelScreen() -> NSScreen? {
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        return NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
    }

    private func preparePanelFrameForDisplay() {
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)

        if !didPreparePanelFrame {
            didPreparePanelFrame = true
            let restored = panel.setFrameUsingName(OverlayFramePersistence.autosaveName)
            _ = panel.setFrameAutosaveName(OverlayFramePersistence.autosaveName)

            if restored,
               OverlayFramePersistence.isReachable(panel.frame, in: visibleFrames) {
                // Only the placement is restored. Height belongs to whatever
                // the panel currently has to show.
                applyHeight(preferredContentHeight, animated: false)
                return
            }
        } else if OverlayFramePersistence.isReachable(panel.frame, in: visibleFrames) {
            applyHeight(preferredContentHeight, animated: false)
            return
        }

        positionOnActiveScreen()
        savePanelFrame()
    }

    private func savePanelFrame() {
        guard didPreparePanelFrame else { return }
        panel.saveFrame(usingName: OverlayFramePersistence.autosaveName)
    }

    private func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }
}
