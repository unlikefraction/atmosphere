import Foundation

/// Persists one of Atmosphere's three supported overlay opacity levels.
struct OverlayOpacityPreference {
    static let defaultStorageKey = "overlayOpacity"
    static let defaultValue = 1.0
    static let options = [0.25, 0.5, 1.0]

    private let userDefaults: UserDefaults
    private let storageKey: String

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = Self.defaultStorageKey
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
    }

    func value() -> Double {
        guard let storedValue = userDefaults.object(forKey: storageKey) as? NSNumber else {
            return Self.defaultValue
        }
        return Self.normalized(storedValue.doubleValue)
    }

    @discardableResult
    func save(_ value: Double) -> Double {
        let normalizedValue = Self.normalized(value)
        userDefaults.set(normalizedValue, forKey: storageKey)
        return normalizedValue
    }

    static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return options.min {
            abs($0 - value) < abs($1 - value)
        } ?? defaultValue
    }
}
