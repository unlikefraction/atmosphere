import Foundation
import XCTest
@testable import Atmosphere

final class DeepgramCredentialStoreTests: XCTestCase {
    private var testRoot: URL!

    override func setUpWithError() throws {
        testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtmosphereCredentialTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: testRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try setPermissions(0o700, for: testRoot)
    }

    override func tearDownWithError() throws {
        if let testRoot {
            try? FileManager.default.removeItem(at: testRoot)
        }
        testRoot = nil
    }

    func testDefaultURLUsesPrivateAtmosphereDirectory() {
        XCTAssertEqual(
            DeepgramFileCredentialStore.defaultCredentialURL,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".atmosphere", isDirectory: true)
                .appendingPathComponent("deepgram-api-key", isDirectory: false)
                .standardizedFileURL
        )
    }

    func testReadsAndTrimsPrivateCredentialFile() throws {
        let credentialURL = try makeCredentialFile(contents: Data("  test-token\n".utf8))

        let value = try DeepgramFileCredentialStore(credentialURL: credentialURL).apiKey()

        XCTAssertEqual(value, "test-token")
    }

    func testRejectsMissingCredentialFile() {
        let credentialURL = testRoot.appendingPathComponent("deepgram-api-key")

        XCTAssertThrowsError(
            try DeepgramFileCredentialStore(credentialURL: credentialURL).apiKey()
        ) { error in
            XCTAssertEqual(error as? DeepgramCredentialError, .missingCredential)
        }
    }

    func testRejectsEmptyCredentialFile() throws {
        let credentialURL = try makeCredentialFile(contents: Data(" \n\t".utf8))

        XCTAssertThrowsError(
            try DeepgramFileCredentialStore(credentialURL: credentialURL).apiKey()
        ) { error in
            XCTAssertEqual(error as? DeepgramCredentialError, .invalidCredential)
        }
    }

    func testRejectsInvalidUTF8CredentialFile() throws {
        let credentialURL = try makeCredentialFile(contents: Data([0xC3, 0x28]))

        XCTAssertThrowsError(
            try DeepgramFileCredentialStore(credentialURL: credentialURL).apiKey()
        ) { error in
            XCTAssertEqual(error as? DeepgramCredentialError, .invalidCredential)
        }
    }

    func testRejectsOversizedCredentialFile() throws {
        let credentialURL = try makeCredentialFile(contents: Data(repeating: 0x61, count: 4_097))

        XCTAssertThrowsError(
            try DeepgramFileCredentialStore(credentialURL: credentialURL).apiKey()
        ) { error in
            XCTAssertEqual(error as? DeepgramCredentialError, .invalidCredential)
        }
    }

    func testRejectsOverlyBroadDirectoryPermissions() throws {
        let credentialURL = try makeCredentialFile(contents: Data("test-token".utf8))
        try setPermissions(0o755, for: testRoot)

        XCTAssertThrowsError(
            try DeepgramFileCredentialStore(credentialURL: credentialURL).apiKey()
        ) { error in
            XCTAssertEqual(error as? DeepgramCredentialError, .unsafePermissions)
        }
    }

    func testRejectsOverlyBroadFilePermissions() throws {
        let credentialURL = try makeCredentialFile(contents: Data("test-token".utf8))
        try setPermissions(0o644, for: credentialURL)

        XCTAssertThrowsError(
            try DeepgramFileCredentialStore(credentialURL: credentialURL).apiKey()
        ) { error in
            XCTAssertEqual(error as? DeepgramCredentialError, .unsafePermissions)
        }
    }

    func testRejectsCredentialSymlink() throws {
        let realCredentialURL = testRoot.appendingPathComponent("real-token")
        try Data("test-token".utf8).write(to: realCredentialURL)
        try setPermissions(0o600, for: realCredentialURL)
        let credentialURL = testRoot.appendingPathComponent("deepgram-api-key")
        try FileManager.default.createSymbolicLink(
            at: credentialURL,
            withDestinationURL: realCredentialURL
        )

        XCTAssertThrowsError(
            try DeepgramFileCredentialStore(credentialURL: credentialURL).apiKey()
        ) { error in
            XCTAssertEqual(error as? DeepgramCredentialError, .invalidCredential)
        }
    }

    func testRejectsCredentialDirectorySymlink() throws {
        let realDirectoryURL = testRoot.appendingPathComponent("real-directory", isDirectory: true)
        try FileManager.default.createDirectory(
            at: realDirectoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try setPermissions(0o700, for: realDirectoryURL)
        let realCredentialURL = realDirectoryURL.appendingPathComponent("deepgram-api-key")
        try Data("test-token".utf8).write(to: realCredentialURL)
        try setPermissions(0o600, for: realCredentialURL)

        let linkedDirectoryURL = testRoot.appendingPathComponent("linked-directory", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linkedDirectoryURL,
            withDestinationURL: realDirectoryURL
        )

        XCTAssertThrowsError(
            try DeepgramFileCredentialStore(
                credentialURL: linkedDirectoryURL.appendingPathComponent("deepgram-api-key")
            ).apiKey()
        ) { error in
            XCTAssertEqual(error as? DeepgramCredentialError, .unsafePermissions)
        }
    }

    func testRejectsNonregularCredentialPath() throws {
        let credentialURL = testRoot.appendingPathComponent("deepgram-api-key", isDirectory: true)
        try FileManager.default.createDirectory(at: credentialURL, withIntermediateDirectories: false)

        XCTAssertThrowsError(
            try DeepgramFileCredentialStore(credentialURL: credentialURL).apiKey()
        ) { error in
            XCTAssertEqual(error as? DeepgramCredentialError, .invalidCredential)
        }
    }

    private func makeCredentialFile(contents: Data) throws -> URL {
        let credentialURL = testRoot.appendingPathComponent("deepgram-api-key")
        try contents.write(to: credentialURL)
        try setPermissions(0o600, for: credentialURL)
        return credentialURL
    }

    private func setPermissions(_ permissions: Int, for url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }
}
