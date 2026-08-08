import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

enum OverlayScreenshotServiceError: LocalizedError {
    case screenRecordingPermissionRequired
    case restartRequiredAfterPermissionGrant
    case panelIsNotOnADisplay
    case displayIsNotShareable(CGDirectDisplayID)
    case screenshotDidNotProduceAnImage
    case couldNotCreateImageDestination
    case couldNotEncodePNG

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionRequired:
            return "Screen Recording access is off. Use Screen off above or Open Screen Recording below to enable Atmosphere."
        case .restartRequiredAfterPermissionGrant:
            return "Screen Recording access was granted. Quit and reopen Atmosphere, then press ` again."
        case .panelIsNotOnADisplay:
            return "The Atmosphere panel is not on an available display."
        case .displayIsNotShareable:
            return "The display containing Atmosphere is not available for capture."
        case .screenshotDidNotProduceAnImage:
            return "ScreenCaptureKit did not return a screenshot image."
        case .couldNotCreateImageDestination:
            return "Could not prepare the private screenshot file."
        case .couldNotEncodePNG:
            return "Could not encode the screenshot as PNG."
        }
    }
}

/// Captures a display through ScreenCaptureKit without including Atmosphere's
/// own windows. It does not show capture UI, play a sound, or request permission.
/// Callers can use `CGRequestScreenCaptureAccess()` from an explicit onboarding
/// flow if `screenRecordingPermissionRequired` is returned.
@available(macOS 14.0, *)
struct OverlayScreenshotService: Sendable {
    init() {}

    /// Resolves the panel's display on the main actor, then performs capture and
    /// PNG encoding away from AppKit's UI isolation.
    @MainActor
    func captureDisplay(containing window: NSWindow) async throws -> URL {
        let displayID = try Self.displayID(containing: window)
        return try await captureDisplay(displayID: displayID)
    }

    /// Captures a known display while excluding every visible instance of the
    /// current app bundle (falling back to explicit window exclusion).
    nonisolated func captureDisplay(displayID: CGDirectDisplayID) async throws -> URL {
        try Task.checkCancellation()
        guard CGPreflightScreenCaptureAccess() else {
            throw OverlayScreenshotServiceError.screenRecordingPermissionRequired
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw OverlayScreenshotServiceError.displayIsNotShareable(displayID)
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let currentBundleID = Bundle.main.bundleIdentifier
        let ownApplications = content.applications.filter { application in
            application.processID == currentPID ||
                (currentBundleID != nil && application.bundleIdentifier == currentBundleID)
        }
        let ownWindows = content.windows.filter { window in
            guard let application = window.owningApplication else { return false }
            return application.processID == currentPID ||
                (currentBundleID != nil && application.bundleIdentifier == currentBundleID)
        }

        let filter: SCContentFilter
        if ownApplications.isEmpty {
            filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        } else {
            filter = SCContentFilter(
                display: display,
                excludingApplications: ownApplications,
                exceptingWindows: []
            )
        }

        let configuration = SCStreamConfiguration()
        let pixelScale = CGFloat(filter.pointPixelScale)
        configuration.width = max(1, Int(filter.contentRect.width * pixelScale))
        configuration.height = max(1, Int(filter.contentRect.height * pixelScale))
        configuration.showsCursor = false
        configuration.capturesAudio = false

        try Task.checkCancellation()
        let image = try await Self.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        try Task.checkCancellation()
        let fileURL = try Self.writePrivatePNG(image)
        do {
            try Task.checkCancellation()
            return fileURL
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
    }

    /// No conversation is restored across launches, so every file left in the
    /// private capture directory belongs to an interrupted prior run.
    nonisolated static func removeOrphanedCaptures(
        in directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let captureDirectory: URL
        if let directory {
            captureDirectory = directory
        } else {
            guard let resolvedDirectory = try? privateCaptureDirectory(fileManager: fileManager) else {
                return
            }
            captureDirectory = resolvedDirectory
        }

        guard let files = try? fileManager.contentsOfDirectory(
            at: captureDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return }

        for file in files {
            let isRegularFile = (try? file.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile == true
            if isRegularFile {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    @MainActor
    private static func displayID(containing window: NSWindow) throws -> CGDirectDisplayID {
        let screen = window.screen ?? screenWithLargestIntersection(for: window.frame) ?? NSScreen.main
        guard let screen,
              let number = screen.deviceDescription[
                  NSDeviceDescriptionKey("NSScreenNumber")
              ] as? NSNumber else {
            throw OverlayScreenshotServiceError.panelIsNotOnADisplay
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    @MainActor
    private static func screenWithLargestIntersection(for frame: NSRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            intersectionArea(lhs.frame, frame) < intersectionArea(rhs.frame, frame)
        }
    }

    private static func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    nonisolated private static func captureImage(
        contentFilter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(
                contentFilter: contentFilter,
                configuration: configuration
            ) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(
                        throwing: OverlayScreenshotServiceError.screenshotDidNotProduceAnImage
                    )
                }
            }
        }
    }

    nonisolated private static func writePrivatePNG(_ image: CGImage) throws -> URL {
        let fileManager = FileManager.default
        let directory = try privateCaptureDirectory(fileManager: fileManager)

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )

        var resourceURL = directory
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? resourceURL.setResourceValues(resourceValues)

        let identifier = UUID().uuidString.lowercased()
        let finalURL = directory.appendingPathComponent("capture-\(identifier).png")
        let temporaryURL = directory.appendingPathComponent(".capture-\(identifier).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }

        guard let destination = CGImageDestinationCreateWithURL(
            temporaryURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw OverlayScreenshotServiceError.couldNotCreateImageDestination
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw OverlayScreenshotServiceError.couldNotEncodePNG
        }

        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporaryURL.path
        )
        try fileManager.moveItem(at: temporaryURL, to: finalURL)
        return finalURL
    }

    nonisolated private static func privateCaptureDirectory(
        fileManager: FileManager
    ) throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appendingPathComponent("Atmosphere", isDirectory: true)
            .appendingPathComponent("Private Captures", isDirectory: true)
    }
}
