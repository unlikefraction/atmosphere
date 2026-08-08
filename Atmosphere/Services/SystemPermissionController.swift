import AppKit
import AVFoundation
import Combine
import CoreGraphics
import Foundation

enum MicrophonePermissionStatus: Equatable, Sendable {
    case granted
    case notDetermined
    case denied
    case restricted

    var isGranted: Bool { self == .granted }
}

enum PermissionResolutionOutcome: Equatable, Sendable {
    case granted
    case restartRequired
    case openedSettings
    case unavailable
}

enum ScreenCapturePermissionStatus: Equatable, Sendable {
    case granted
    case permissionRequired
    case restartRequired
}

enum PrivacySettingsPane: String, CaseIterable, Sendable {
    case microphone = "Privacy_Microphone"
    case screenCapture = "Privacy_ScreenCapture"

    var modernURL: URL? {
        URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(rawValue)"
        )
    }

    var legacyURL: URL? {
        URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)"
        )
    }
}

/// Reads permission state without prompting. Request APIs are called only from
/// explicit permission-button actions in the overlay.
@MainActor
final class SystemPermissionController: ObservableObject {
    @Published private(set) var microphoneStatus: MicrophonePermissionStatus = .notDetermined
    @Published private(set) var isScreenCaptureGranted = false
    @Published private(set) var screenCaptureRequiresRestart = false
    @Published private(set) var isResolvingMicrophone = false
    @Published private(set) var isResolvingScreenCapture = false
    private var hasObservedScreenCaptureStatus = false

    init() {
        refresh()
    }

    func refresh() {
        microphoneStatus = Self.microphoneStatus(
            for: AVCaptureDevice.authorizationStatus(for: .audio)
        )
        let latestScreenCaptureStatus = CGPreflightScreenCaptureAccess()
        if hasObservedScreenCaptureStatus,
           !isScreenCaptureGranted,
           latestScreenCaptureStatus {
            // ScreenCaptureKit permission changes are not fully applied to an
            // already-running process. Keep this process-local state until a
            // fresh Atmosphere process starts.
            screenCaptureRequiresRestart = true
        }
        isScreenCaptureGranted = latestScreenCaptureStatus
        hasObservedScreenCaptureStatus = true
    }

    var screenCaptureStatus: ScreenCapturePermissionStatus {
        Self.screenCaptureStatus(
            isGranted: isScreenCaptureGranted,
            requiresRestart: screenCaptureRequiresRestart
        )
    }

    var isScreenCaptureReady: Bool {
        screenCaptureStatus == .granted
    }

    func resolveMicrophonePermission() async -> PermissionResolutionOutcome {
        guard !isResolvingMicrophone else { return .unavailable }
        isResolvingMicrophone = true
        defer { isResolvingMicrophone = false }

        refresh()
        switch microphoneStatus {
        case .granted:
            return .granted

        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            refresh()
            if granted, microphoneStatus.isGranted {
                return .granted
            }
            return openSettings(.microphone)

        case .denied, .restricted:
            return openSettings(.microphone)
        }
    }

    func resolveScreenCapturePermission() -> PermissionResolutionOutcome {
        guard !isResolvingScreenCapture else { return .unavailable }
        isResolvingScreenCapture = true
        defer { isResolvingScreenCapture = false }

        refresh()
        if screenCaptureRequiresRestart {
            return .restartRequired
        }
        guard !isScreenCaptureGranted else { return .granted }

        // A false preflight cannot distinguish first use from a prior denial.
        // The explicit click is the appropriate time to request/register once.
        let permissionWasGranted = CGRequestScreenCaptureAccess()
        refresh()
        if permissionWasGranted || isScreenCaptureGranted {
            markScreenCaptureRestartRequired()
            return .restartRequired
        }
        return openSettings(.screenCapture)
    }

    func markScreenCaptureRestartRequired() {
        screenCaptureRequiresRestart = true
    }

    static func microphoneStatus(
        for authorizationStatus: AVAuthorizationStatus
    ) -> MicrophonePermissionStatus {
        switch authorizationStatus {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .restricted
        }
    }

    static func screenCaptureStatus(
        isGranted: Bool,
        requiresRestart: Bool
    ) -> ScreenCapturePermissionStatus {
        if requiresRestart {
            return .restartRequired
        }
        return isGranted ? .granted : .permissionRequired
    }

    private func openSettings(_ pane: PrivacySettingsPane) -> PermissionResolutionOutcome {
        for url in [pane.modernURL, pane.legacyURL].compactMap({ $0 }) {
            if NSWorkspace.shared.open(url) {
                return .openedSettings
            }
        }

        guard let settingsURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.systempreferences"
        ) else {
            return .unavailable
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: settingsURL,
            configuration: configuration
        )
        return .openedSettings
    }
}
