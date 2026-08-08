import Darwin
import Foundation
import XCTest
@testable import Atmosphere

final class CodexHomeIsolationTests: XCTestCase {
    private var testRoot: URL!
    private var privateHome: URL!
    private var sharedAuthentication: URL!

    override func setUpWithError() throws {
        testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtmosphereCodexHomeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: testRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try setPermissions(0o700, for: testRoot)
        privateHome = testRoot
            .appendingPathComponent(".atmosphere", isDirectory: true)
            .appendingPathComponent("codex-home", isDirectory: true)
        sharedAuthentication = testRoot
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    override func tearDownWithError() throws {
        if let testRoot {
            try? FileManager.default.removeItem(at: testRoot)
        }
        testRoot = nil
        privateHome = nil
        sharedAuthentication = nil
    }

    func testDefaultHomeLivesInPrivateAtmosphereDirectory() {
        XCTAssertEqual(
            CodexHomeIsolation.defaultPrivateHomeURL,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".atmosphere", isDirectory: true)
                .appendingPathComponent("codex-home", isDirectory: true)
                .standardizedFileURL
        )
    }

    func testPrepareCreatesPrivateHomeAndSharesOnlyAuthentication() throws {
        try makeSharedAuthentication()
        let isolation = makeIsolation()

        let result = try isolation.prepare()

        XCTAssertEqual(result, privateHome.standardizedFileURL)
        XCTAssertEqual(permissions(of: privateHome), 0o700)
        let linkedAuthentication = privateHome.appendingPathComponent("auth.json")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: linkedAuthentication.path),
            sharedAuthentication.path
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: privateHome.appendingPathComponent("config.toml").path
            )
        )
    }

    func testProcessEnvironmentOverridesOnlyCodexHome() throws {
        let isolation = makeIsolation()

        let environment = try isolation.processEnvironment(
            basedOn: ["PATH": "/usr/bin", "HOME": "/do/not/change"]
        )

        XCTAssertEqual(environment["CODEX_HOME"], privateHome.standardizedFileURL.path)
        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["HOME"], "/do/not/change")
    }

    func testPrepareRejectsConfigurationInsideIsolatedHome() throws {
        try FileManager.default.createDirectory(
            at: privateHome,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let configuration = privateHome.appendingPathComponent("config.toml")
        try Data("[mcp_servers.example]".utf8).write(to: configuration)

        XCTAssertThrowsError(try makeIsolation().prepare()) { error in
            XCTAssertEqual(
                error as? CodexHomeIsolationError,
                .unexpectedConfiguration(configuration.path)
            )
        }
    }

    func testPrepareRejectsUnexpectedAuthenticationSymlink() throws {
        try FileManager.default.createDirectory(
            at: privateHome,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let unexpected = testRoot.appendingPathComponent("other-auth.json")
        try Data("{}".utf8).write(to: unexpected)
        try setPermissions(0o600, for: unexpected)
        let isolatedAuthentication = privateHome.appendingPathComponent("auth.json")
        try FileManager.default.createSymbolicLink(
            at: isolatedAuthentication,
            withDestinationURL: unexpected
        )

        XCTAssertThrowsError(try makeIsolation().prepare()) { error in
            XCTAssertEqual(
                error as? CodexHomeIsolationError,
                .unsafeAuthenticationFile(isolatedAuthentication.path)
            )
        }
    }

    private func makeIsolation() -> CodexHomeIsolation {
        CodexHomeIsolation(
            privateHomeURL: privateHome,
            sharedAuthenticationURL: sharedAuthentication
        )
    }

    private func makeSharedAuthentication() throws {
        try FileManager.default.createDirectory(
            at: sharedAuthentication.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("{}".utf8).write(to: sharedAuthentication)
        try setPermissions(0o600, for: sharedAuthentication)
    }

    private func setPermissions(_ permissions: Int, for url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    private func permissions(of url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let value = attributes[.posixPermissions] as? NSNumber else {
            return nil
        }
        return value.intValue
    }
}
