import Darwin
import Foundation

enum CodexHomeIsolationError: Error, Equatable, LocalizedError {
    case unsafeDirectory(String)
    case unexpectedConfiguration(String)
    case unsafeAuthenticationFile(String)
    case preparationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsafeDirectory(let path):
            return "Atmosphere's private ChatGPT runtime directory is unsafe: \(path)."
        case .unexpectedConfiguration(let path):
            return "Atmosphere refused to load an unexpected Codex configuration at \(path)."
        case .unsafeAuthenticationFile(let path):
            return "Atmosphere refused to use an unsafe ChatGPT authentication file at \(path)."
        case .preparationFailed(let details):
            return "Atmosphere could not prepare its private ChatGPT runtime (\(details))."
        }
    }
}

/// Gives Atmosphere a Codex home that contains authentication only.
///
/// The normal Codex home can contain user-installed MCP servers and plugins.
/// App Server configuration layers deep-merge those maps, so an empty override
/// is not sufficient to remove them. A separate home is the security boundary:
/// Atmosphere can share the user's ChatGPT sign-in without inheriting any tool
/// server, plugin, hook, instruction, or project-trust configuration.
struct CodexHomeIsolation {
    static var defaultPrivateHomeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".atmosphere", isDirectory: true)
            .appendingPathComponent("codex-home", isDirectory: true)
            .standardizedFileURL
    }

    static var defaultSharedAuthenticationURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
            .standardizedFileURL
    }

    let privateHomeURL: URL
    let sharedAuthenticationURL: URL

    init(
        privateHomeURL: URL = Self.defaultPrivateHomeURL,
        sharedAuthenticationURL: URL = Self.defaultSharedAuthenticationURL
    ) {
        self.privateHomeURL = privateHomeURL.standardizedFileURL
        self.sharedAuthenticationURL = sharedAuthenticationURL.standardizedFileURL
    }

    func prepare(fileManager: FileManager = .default) throws -> URL {
        let atmosphereDirectory = privateHomeURL.deletingLastPathComponent()
        try ensurePrivateDirectory(at: atmosphereDirectory, fileManager: fileManager)
        try ensurePrivateDirectory(at: privateHomeURL, fileManager: fileManager)

        // Loading even a locally added config would make the no-MCP guarantee
        // dependent on mutable external state. Fail closed instead.
        let configurationURL = privateHomeURL.appendingPathComponent("config.toml")
        if try nodeStatus(at: configurationURL) != nil {
            throw CodexHomeIsolationError.unexpectedConfiguration(configurationURL.path)
        }

        let isolatedAuthenticationURL = privateHomeURL.appendingPathComponent("auth.json")
        if let isolatedStatus = try nodeStatus(at: isolatedAuthenticationURL) {
            try validateExistingAuthentication(
                at: isolatedAuthenticationURL,
                status: isolatedStatus,
                fileManager: fileManager
            )
        } else if let sharedStatus = try nodeStatus(at: sharedAuthenticationURL) {
            try validateRegularPrivateFile(at: sharedAuthenticationURL, status: sharedStatus)
            do {
                try fileManager.createSymbolicLink(
                    at: isolatedAuthenticationURL,
                    withDestinationURL: sharedAuthenticationURL
                )
            } catch {
                throw CodexHomeIsolationError.preparationFailed(error.localizedDescription)
            }
        }

        return privateHomeURL
    }

    func processEnvironment(
        basedOn environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> [String: String] {
        let preparedHome = try prepare(fileManager: fileManager)
        var isolatedEnvironment = environment
        isolatedEnvironment["CODEX_HOME"] = preparedHome.path
        return isolatedEnvironment
    }

    private func ensurePrivateDirectory(
        at url: URL,
        fileManager: FileManager
    ) throws {
        if let status = try nodeStatus(at: url) {
            guard status.st_mode & S_IFMT == S_IFDIR,
                  status.st_uid == geteuid() else {
                throw CodexHomeIsolationError.unsafeDirectory(url.path)
            }
        } else {
            do {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw CodexHomeIsolationError.preparationFailed(error.localizedDescription)
            }
        }

        guard Darwin.chmod(url.path, 0o700) == 0 else {
            throw CodexHomeIsolationError.preparationFailed(
                String(cString: strerror(errno))
            )
        }
    }

    private func validateExistingAuthentication(
        at url: URL,
        status: stat,
        fileManager: FileManager
    ) throws {
        switch status.st_mode & S_IFMT {
        case S_IFREG:
            try validateRegularPrivateFile(at: url, status: status)

        case S_IFLNK:
            let destination: String
            do {
                destination = try fileManager.destinationOfSymbolicLink(atPath: url.path)
            } catch {
                throw CodexHomeIsolationError.unsafeAuthenticationFile(url.path)
            }

            let destinationURL: URL
            if destination.hasPrefix("/") {
                destinationURL = URL(fileURLWithPath: destination)
            } else {
                destinationURL = url.deletingLastPathComponent()
                    .appendingPathComponent(destination)
            }
            guard destinationURL.standardizedFileURL == sharedAuthenticationURL else {
                throw CodexHomeIsolationError.unsafeAuthenticationFile(url.path)
            }

            // A dangling link is allowed so a later managed sign-in can restore
            // the shared auth file. If the target exists, it must remain private.
            if let sharedStatus = try nodeStatus(at: sharedAuthenticationURL) {
                try validateRegularPrivateFile(
                    at: sharedAuthenticationURL,
                    status: sharedStatus
                )
            }

        default:
            throw CodexHomeIsolationError.unsafeAuthenticationFile(url.path)
        }
    }

    private func validateRegularPrivateFile(at url: URL, status: stat) throws {
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & 0o7777 == 0o600 else {
            throw CodexHomeIsolationError.unsafeAuthenticationFile(url.path)
        }
    }

    private func nodeStatus(at url: URL) throws -> stat? {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else {
            if errno == ENOENT { return nil }
            throw CodexHomeIsolationError.preparationFailed(
                String(cString: strerror(errno))
            )
        }
        return status
    }
}
