import Foundation

enum WorkingDirectoryPreferenceError: Error, Equatable, LocalizedError {
    case invalidStoredPath
    case notFileURL
    case doesNotExist(String)
    case notDirectory(String)
    case notReadable(String)

    var errorDescription: String? {
        switch self {
        case .invalidStoredPath:
            return "The saved working folder path is invalid."
        case .notFileURL:
            return "Choose a folder on this Mac."
        case .doesNotExist(let path):
            return "The working folder no longer exists: \(path)"
        case .notDirectory(let path):
            return "The working folder selection is not a folder: \(path)"
        case .notReadable(let path):
            return "Atmosphere cannot read the working folder: \(path)"
        }
    }
}

/// Persists an optional working directory as a native file-system path.
///
/// Atmosphere is not sandboxed, so a security-scoped bookmark is unnecessary.
/// The directory is revalidated each time it is loaded, which prevents a stale
/// preference from silently becoming the working directory for a new chat.
struct WorkingDirectoryPreference {
    static let defaultStorageKey = "assistantWorkingDirectoryPath"

    private let userDefaults: UserDefaults
    private let fileManager: FileManager
    private let storageKey: String

    init(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        storageKey: String = Self.defaultStorageKey
    ) {
        self.userDefaults = userDefaults
        self.fileManager = fileManager
        self.storageKey = storageKey
    }

    /// Returns the saved folder after verifying it still exists and is usable.
    func selectedDirectory() throws -> URL? {
        guard let storedValue = userDefaults.object(forKey: storageKey) else {
            return nil
        }
        guard let path = storedValue as? String,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              NSString(string: path).isAbsolutePath else {
            throw WorkingDirectoryPreferenceError.invalidStoredPath
        }

        return try validate(
            URL(fileURLWithPath: path, isDirectory: true)
        )
    }

    /// Selects or changes the working folder and returns its standardized URL.
    @discardableResult
    func selectDirectory(_ directoryURL: URL) throws -> URL {
        let validatedURL = try validate(directoryURL)
        userDefaults.set(validatedURL.path, forKey: storageKey)
        return validatedURL
    }

    func removeDirectory() {
        userDefaults.removeObject(forKey: storageKey)
    }

    /// Validates a prospective folder without changing the saved preference.
    func validate(_ directoryURL: URL) throws -> URL {
        guard directoryURL.isFileURL else {
            throw WorkingDirectoryPreferenceError.notFileURL
        }

        let standardizedURL = directoryURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: standardizedURL.path,
            isDirectory: &isDirectory
        ) else {
            throw WorkingDirectoryPreferenceError.doesNotExist(standardizedURL.path)
        }
        guard isDirectory.boolValue else {
            throw WorkingDirectoryPreferenceError.notDirectory(standardizedURL.path)
        }
        guard fileManager.isReadableFile(atPath: standardizedURL.path) else {
            throw WorkingDirectoryPreferenceError.notReadable(standardizedURL.path)
        }

        return standardizedURL
    }
}
