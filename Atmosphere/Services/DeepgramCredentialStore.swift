import Darwin
import Foundation

protocol DeepgramCredentialProviding: Sendable {
    func apiKey() throws -> String
}

enum DeepgramCredentialError: Error, Equatable, LocalizedError {
    case missingCredential
    case invalidCredential
    case unsafePermissions
    case readFailure

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "Save a Deepgram API key at ~/.atmosphere/deepgram-api-key."
        case .invalidCredential:
            return "The Deepgram API key file is empty or unreadable."
        case .unsafePermissions:
            return "Protect ~/.atmosphere with mode 700 and its Deepgram key file with mode 600."
        case .readFailure:
            return "Could not read ~/.atmosphere/deepgram-api-key. Check that it belongs to your account."
        }
    }
}

/// Reads the Deepgram credential from a private file owned by the current user.
///
/// Atmosphere deliberately does not fall back to Keychain: doing so could show
/// an access prompt after a rebuild, even when this file is configured.
struct DeepgramFileCredentialStore: DeepgramCredentialProviding {
    static var defaultCredentialURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".atmosphere", isDirectory: true)
            .appendingPathComponent("deepgram-api-key", isDirectory: false)
    }

    let credentialURL: URL

    init(credentialURL: URL = Self.defaultCredentialURL) {
        self.credentialURL = credentialURL.standardizedFileURL
    }

    func apiKey() throws -> String {
        let directoryURL = credentialURL.deletingLastPathComponent()
        let directoryDescriptor = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            switch errno {
            case ENOENT:
                throw DeepgramCredentialError.missingCredential
            case ELOOP, ENOTDIR:
                throw DeepgramCredentialError.unsafePermissions
            default:
                throw DeepgramCredentialError.readFailure
            }
        }
        defer { Darwin.close(directoryDescriptor) }

        var directoryStatus = stat()
        guard Darwin.fstat(directoryDescriptor, &directoryStatus) == 0 else {
            throw DeepgramCredentialError.readFailure
        }
        guard directoryStatus.st_mode & S_IFMT == S_IFDIR,
              directoryStatus.st_mode & 0o7777 == 0o700,
              directoryStatus.st_uid == geteuid() else {
            throw DeepgramCredentialError.unsafePermissions
        }

        let fileName = credentialURL.lastPathComponent
        guard !fileName.isEmpty, fileName != ".", fileName != ".." else {
            throw DeepgramCredentialError.invalidCredential
        }
        let credentialDescriptor = Darwin.openat(
            directoryDescriptor,
            fileName,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard credentialDescriptor >= 0 else {
            switch errno {
            case ENOENT:
                throw DeepgramCredentialError.missingCredential
            case ELOOP:
                throw DeepgramCredentialError.invalidCredential
            default:
                throw DeepgramCredentialError.readFailure
            }
        }
        defer { Darwin.close(credentialDescriptor) }

        var credentialStatus = stat()
        guard Darwin.fstat(credentialDescriptor, &credentialStatus) == 0 else {
            throw DeepgramCredentialError.readFailure
        }
        guard credentialStatus.st_mode & S_IFMT == S_IFREG else {
            throw DeepgramCredentialError.invalidCredential
        }
        guard credentialStatus.st_mode & 0o7777 == 0o600,
              credentialStatus.st_uid == geteuid() else {
            throw DeepgramCredentialError.unsafePermissions
        }
        guard credentialStatus.st_size > 0, credentialStatus.st_size <= 4_096 else {
            throw DeepgramCredentialError.invalidCredential
        }

        do {
            let handle = FileHandle(
                fileDescriptor: credentialDescriptor,
                closeOnDealloc: false
            )
            let data = try handle.read(upToCount: 4_097) ?? Data()
            guard !data.isEmpty,
                  data.count <= 4_096,
                  let value = String(data: data, encoding: .utf8) else {
                throw DeepgramCredentialError.invalidCredential
            }

            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw DeepgramCredentialError.invalidCredential
            }
            return trimmed
        } catch let error as DeepgramCredentialError {
            throw error
        } catch {
            throw DeepgramCredentialError.readFailure
        }
    }
}
