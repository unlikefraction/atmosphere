import XCTest
@testable import Atmosphere

final class ProjectSmokeTests: XCTestCase {
    func testTestTargetLoads() {
        XCTAssertTrue(true)
    }

    func testAppDeclaresAgentMetadata() {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool,
            true
        )
        XCTAssertNotNil(
            Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
        )
        XCTAssertNotNil(
            Bundle.main.object(forInfoDictionaryKey: "NSScreenCaptureUsageDescription") as? String
        )
    }

    @MainActor
    func testOverlayConfiguresBestEffortCaptureExclusion() {
        let controller = OverlayController(viewModel: ChatViewModel())

        XCTAssertEqual(controller.captureSharingType, .none)
    }

    @MainActor
    func testOverlayRestoresPersistedOpacityWithoutChangingCaptureExclusion() {
        let suiteName = "OverlayControllerOpacityTests-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let preference = OverlayOpacityPreference(userDefaults: userDefaults)
        preference.save(0.5)

        let controller = OverlayController(
            viewModel: ChatViewModel(),
            opacityPreference: preference
        )

        XCTAssertEqual(controller.panelOpacity, 0.5, accuracy: 0.001)
        XCTAssertEqual(controller.captureSharingType, .none)
    }

    @MainActor
    func testCanceledScreenshotCompletionDeletesPrivateFile() throws {
        let viewModel = ChatViewModel()
        let operationID = try XCTUnwrap(viewModel.beginScreenshotCapture())
        viewModel.cancelScreenshotCapture()

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("atmosphere-stale-\(UUID().uuidString).png")
        try Data("private pixels".utf8).write(to: fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        viewModel.finishScreenshotCapture(fileURL, operationID: operationID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(viewModel.pendingAttachments.isEmpty)
    }

    func testLaunchCleanupRemovesOrphanedCaptureFilesIncludingHiddenTemporaryFiles() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("Atmosphere-Capture-Cleanup-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let screenshot = directory.appendingPathComponent("capture-orphan.png")
        let temporary = directory.appendingPathComponent(".capture-orphan.tmp")
        try Data("pixels".utf8).write(to: screenshot)
        try Data("partial pixels".utf8).write(to: temporary)

        OverlayScreenshotService.removeOrphanedCaptures(in: directory)

        XCTAssertFalse(fileManager.fileExists(atPath: screenshot.path))
        XCTAssertFalse(fileManager.fileExists(atPath: temporary.path))
    }

    func testLaunchCleanupRemovesOnlyOrphanedWAVRecordings() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("Atmosphere-Audio-Cleanup-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let recording = directory.appendingPathComponent("orphan.wav")
        let unrelated = directory.appendingPathComponent("keep.txt")
        try Data("wave".utf8).write(to: recording)
        try Data("keep".utf8).write(to: unrelated)

        MicrophoneRecorder.removeOrphanedRecordings(in: directory)

        XCTAssertFalse(fileManager.fileExists(atPath: recording.path))
        XCTAssertTrue(fileManager.fileExists(atPath: unrelated.path))
    }

    @MainActor
    func testMicrophoneAuthorizationStatusMapping() {
        XCTAssertEqual(
            SystemPermissionController.microphoneStatus(for: .authorized),
            .granted
        )
        XCTAssertEqual(
            SystemPermissionController.microphoneStatus(for: .notDetermined),
            .notDetermined
        )
        XCTAssertEqual(
            SystemPermissionController.microphoneStatus(for: .denied),
            .denied
        )
        XCTAssertEqual(
            SystemPermissionController.microphoneStatus(for: .restricted),
            .restricted
        )
    }

    func testPrivacySettingsPaneURLsUseCurrentAndLegacyRoutes() {
        XCTAssertEqual(
            PrivacySettingsPane.microphone.modernURL?.absoluteString,
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
        )
        XCTAssertEqual(
            PrivacySettingsPane.screenCapture.modernURL?.absoluteString,
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        )
        XCTAssertEqual(
            PrivacySettingsPane.screenCapture.legacyURL?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
    }

    @MainActor
    func testScreenCaptureStatusKeepsFirstGrantInRestartState() {
        XCTAssertEqual(
            SystemPermissionController.screenCaptureStatus(
                isGranted: false,
                requiresRestart: false
            ),
            .permissionRequired
        )
        XCTAssertEqual(
            SystemPermissionController.screenCaptureStatus(
                isGranted: true,
                requiresRestart: false
            ),
            .granted
        )
        XCTAssertEqual(
            SystemPermissionController.screenCaptureStatus(
                isGranted: true,
                requiresRestart: true
            ),
            .restartRequired
        )
    }

    @MainActor
    func testScreenshotPermissionErrorExposesSettingsActionAndClearsOnGrant() throws {
        let viewModel = ChatViewModel()
        let operationID = try XCTUnwrap(viewModel.beginScreenshotCapture())

        viewModel.failScreenshotCapture(
            OverlayScreenshotServiceError.screenRecordingPermissionRequired,
            operationID: operationID
        )

        XCTAssertEqual(viewModel.inputPermissionAction, .screenCapture)
        XCTAssertNotNil(viewModel.inputErrorMessage)

        viewModel.clearResolvedPermissionError(
            microphoneGranted: false,
            screenCaptureGranted: true
        )

        XCTAssertNil(viewModel.inputPermissionAction)
        XCTAssertNil(viewModel.inputErrorMessage)
    }

    @MainActor
    func testScreenshotFirstGrantExposesPersistentRestartAction() throws {
        let viewModel = ChatViewModel()
        let operationID = try XCTUnwrap(viewModel.beginScreenshotCapture())

        viewModel.failScreenshotCapture(
            OverlayScreenshotServiceError.restartRequiredAfterPermissionGrant,
            operationID: operationID
        )

        XCTAssertEqual(viewModel.inputPermissionAction, .restartAtmosphere)
        XCTAssertNotNil(viewModel.inputErrorMessage)

        viewModel.clearResolvedPermissionError(
            microphoneGranted: false,
            screenCaptureGranted: true
        )

        XCTAssertEqual(viewModel.inputPermissionAction, .restartAtmosphere)
        XCTAssertNotNil(viewModel.inputErrorMessage)
    }
}
