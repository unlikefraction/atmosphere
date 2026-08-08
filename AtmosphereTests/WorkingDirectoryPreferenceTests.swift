import Foundation
import XCTest
@testable import Atmosphere

final class WorkingDirectoryPreferenceTests: XCTestCase {
    private var suiteName: String!
    private var userDefaults: UserDefaults!
    private var testRoot: URL!

    override func setUpWithError() throws {
        suiteName = "WorkingDirectoryPreferenceTests-\(UUID().uuidString)"
        userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)

        testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AtmosphereWorkingDirectoryTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: testRoot,
            withIntermediateDirectories: false
        )
    }

    override func tearDownWithError() throws {
        if let testRoot {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: testRoot.path
            )
            try? FileManager.default.removeItem(at: testRoot)
        }
        if let suiteName {
            userDefaults?.removePersistentDomain(forName: suiteName)
        }
        testRoot = nil
        userDefaults = nil
        suiteName = nil
    }

    func testStartsWithoutASelection() throws {
        let preference = makePreference()

        XCTAssertNil(try preference.selectedDirectory())
    }

    func testSelectionPersistsAcrossPreferenceInstances() throws {
        let preference = makePreference()

        let selectedURL = try preference.selectDirectory(testRoot)
        let reloadedPreference = makePreference()

        XCTAssertEqual(selectedURL, testRoot.standardizedFileURL)
        XCTAssertEqual(
            try reloadedPreference.selectedDirectory(),
            testRoot.standardizedFileURL
        )
        XCTAssertEqual(
            userDefaults.string(forKey: WorkingDirectoryPreference.defaultStorageKey),
            testRoot.standardizedFileURL.path
        )
    }

    func testSelectingAnotherDirectoryReplacesThePreviousSelection() throws {
        let replacement = testRoot.appendingPathComponent("Replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
        let preference = makePreference()
        try preference.selectDirectory(testRoot)

        try preference.selectDirectory(replacement)

        XCTAssertEqual(
            try preference.selectedDirectory(),
            replacement.standardizedFileURL
        )
    }

    func testRemovingSelectionPersists() throws {
        let preference = makePreference()
        try preference.selectDirectory(testRoot)

        preference.removeDirectory()

        XCTAssertNil(try makePreference().selectedDirectory())
        XCTAssertNil(userDefaults.object(forKey: WorkingDirectoryPreference.defaultStorageKey))
    }

    func testRejectsMissingDirectoryWithoutChangingSelection() throws {
        let preference = makePreference()
        try preference.selectDirectory(testRoot)
        let missingURL = testRoot.appendingPathComponent("Missing", isDirectory: true)

        XCTAssertThrowsError(try preference.selectDirectory(missingURL)) { error in
            XCTAssertEqual(
                error as? WorkingDirectoryPreferenceError,
                .doesNotExist(missingURL.standardizedFileURL.path)
            )
        }
        XCTAssertEqual(try preference.selectedDirectory(), testRoot.standardizedFileURL)
    }

    func testRejectsAFile() throws {
        let fileURL = testRoot.appendingPathComponent("note.txt", isDirectory: false)
        try Data("hello".utf8).write(to: fileURL)

        XCTAssertThrowsError(try makePreference().selectDirectory(fileURL)) { error in
            XCTAssertEqual(
                error as? WorkingDirectoryPreferenceError,
                .notDirectory(fileURL.standardizedFileURL.path)
            )
        }
    }

    func testRejectsUnreadableDirectory() throws {
        let unreadableURL = testRoot.appendingPathComponent("Unreadable", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadableURL, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: unreadableURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: unreadableURL.path
            )
        }

        XCTAssertThrowsError(try makePreference().selectDirectory(unreadableURL)) { error in
            XCTAssertEqual(
                error as? WorkingDirectoryPreferenceError,
                .notReadable(unreadableURL.standardizedFileURL.path)
            )
        }
    }

    func testRejectsNonFileURL() {
        let remoteURL = URL(string: "https://example.com/folder")!

        XCTAssertThrowsError(try makePreference().selectDirectory(remoteURL)) { error in
            XCTAssertEqual(error as? WorkingDirectoryPreferenceError, .notFileURL)
        }
    }

    func testReloadRevalidatesADeletedSelection() throws {
        let preference = makePreference()
        try preference.selectDirectory(testRoot)
        try FileManager.default.removeItem(at: testRoot)

        XCTAssertThrowsError(try makePreference().selectedDirectory()) { error in
            XCTAssertEqual(
                error as? WorkingDirectoryPreferenceError,
                .doesNotExist(testRoot.standardizedFileURL.path)
            )
        }
    }

    func testRejectsMalformedStoredPath() {
        userDefaults.set(
            "relative/folder",
            forKey: WorkingDirectoryPreference.defaultStorageKey
        )

        XCTAssertThrowsError(try makePreference().selectedDirectory()) { error in
            XCTAssertEqual(
                error as? WorkingDirectoryPreferenceError,
                .invalidStoredPath
            )
        }
    }

    private func makePreference() -> WorkingDirectoryPreference {
        WorkingDirectoryPreference(userDefaults: userDefaults)
    }
}
