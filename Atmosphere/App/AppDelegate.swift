import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlayController: OverlayController?
    private var globalHotKey: GlobalHotKey?
    private var viewModel: ChatViewModel?
    private var terminationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        #if DEBUG
        if let prompt = AssistantBackendProbe.promptFromArguments() {
            AssistantBackendProbe.run(prompt: prompt)
            return
        }

        if let previewDirectory = OverlayPreviewRenderer.outputDirectoryFromArguments() {
            OverlayPreviewRenderer.run(outputDirectory: previewDirectory)
            return
        }
        #endif

        OverlayScreenshotService.removeOrphanedCaptures()

        let viewModel = ChatViewModel()
        let overlayController = OverlayController(viewModel: viewModel)

        self.viewModel = viewModel
        self.overlayController = overlayController

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(OverlayController.allowCaptureArgument) {
            overlayController.allowCaptureForDebugging()
        }
        #endif

        globalHotKey = GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_Backslash),
            modifiers: UInt32(cmdKey)
        ) { [weak overlayController] in
            overlayController?.toggle()
        }

        if globalHotKey == nil {
            viewModel.reportShortcutRegistrationFailure()
            overlayController.show()
        }

        Task {
            await viewModel.connect()
        }

        // An agent app has no Dock or menu-bar item. Show once on first launch so
        // the user can see the shortcut and connection state.
        if globalHotKey != nil,
           !UserDefaults.standard.bool(forKey: "hasShownFirstLaunch") {
            UserDefaults.standard.set(true, forKey: "hasShownFirstLaunch")
            overlayController.show()
        }
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        guard let viewModel else { return .terminateNow }

        terminationTask = Task { [weak self] in
            if let overlayController = self?.overlayController {
                await overlayController.shutdown()
            }
            await viewModel.shutdown()
            self?.terminationTask = nil
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        overlayController?.show()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        overlayController?.refreshSystemPermissions()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.overlayController?.refreshSystemPermissions()
        }
    }
}
