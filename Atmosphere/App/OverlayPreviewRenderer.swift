#if DEBUG
import AppKit
import SwiftUI

/// Renders the overlay's states to PNG files so the design can be reviewed
/// without driving the live app. Debug-only: launch with
/// `--render-overlay-previews <directory>`.
///
/// Vibrancy needs a real window backdrop, so each state is captured in an
/// off-screen window placed over a synthetic desktop rather than through a
/// bitmap of a detached view.
@MainActor
enum OverlayPreviewRenderer {
    static let argument = "--render-overlay-previews"

    static func outputDirectoryFromArguments() -> URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: argument),
              index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    static func run(outputDirectory: URL) {
        try? FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        for (appearanceName, phase) in [
            (NSAppearance.Name.darkAqua, SkyPhase.night),
            (.aqua, .day)
        ] {
            let appearance = NSAppearance(named: appearanceName)
            let suffix = appearanceName == .darkAqua ? "dark" : "light"
            SkyPhase.forcedForPreviews = phase

            capture("compact", appearance: appearance, in: outputDirectory, suffix: suffix) { _, _ in }
            capture("conversation", appearance: appearance, in: outputDirectory, suffix: suffix) { model, _ in
                model.applyPreviewFixture(streaming: false)
            }
            capture("thinking", appearance: appearance, in: outputDirectory, suffix: suffix) { model, _ in
                model.applyPreviewFixture(streaming: true)
            }
            capture("listening", appearance: appearance, in: outputDirectory, suffix: suffix) { model, _ in
                model.applyPreviewRecordingState()
            }
            capture("connect", appearance: appearance, in: outputDirectory, suffix: suffix) { model, _ in
                model.applyPreviewAuthenticationState()
            }
            capture("shortcuts", appearance: appearance, in: outputDirectory, suffix: suffix) { model, chrome in
                model.applyPreviewFixture(streaming: false)
                chrome.isShortcutsVisible = true
            }
        }

        SkyPhase.forcedForPreviews = nil
        NSApp.terminate(nil)
    }

    private static func capture(
        _ name: String,
        appearance: NSAppearance?,
        in directory: URL,
        suffix: String,
        configure: (ChatViewModel, OverlayChrome) -> Void
    ) {
        let viewModel = ChatViewModel()
        let chrome = OverlayChrome(opacity: 1)
        configure(viewModel, chrome)

        var measuredHeight = OverlayController.initialHeight
        let root = ChatView(
            viewModel: viewModel,
            permissionController: SystemPermissionController(),
            chrome: chrome,
            onDismiss: {},
            onCaptureScreenshot: {},
            onChooseWorkingDirectory: {},
            onRemoveWorkingDirectory: {},
            onOverlayOpacityChange: { _ in },
            onPreferredHeightChange: { measuredHeight = $0 },
            onRestart: { true },
            onQuit: {}
        )

        let width = OverlayController.panelWidth
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let padding: CGFloat = 40
        let height = max(measuredHeight, OverlayController.initialHeight)
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: width + (padding * 2),
                height: height + (padding * 2)
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        window.isOpaque = true
        window.backgroundColor = appearance?.name == .darkAqua
            ? NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.15, alpha: 1)
            : NSColor(calibratedRed: 0.76, green: 0.78, blue: 0.83, alpha: 1)

        let container = NSView(frame: window.contentLayoutRect)
        hosting.frame = NSRect(x: padding, y: padding, width: width, height: height)
        container.addSubview(hosting)
        window.contentView = container
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))

        container.wantsLayer = true
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        guard let representation = container.bitmapImageRepForCachingDisplay(in: container.bounds),
              let context = NSGraphicsContext(bitmapImageRep: representation) else {
            window.orderOut(nil)
            return
        }
        // SwiftUI draws into layers; a plain `cacheDisplay` misses most of it.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.setFillColor(window.backgroundColor.cgColor)
        context.cgContext.fill(container.bounds)
        container.layer?.render(in: context.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        window.orderOut(nil)

        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
    }
}
#endif
