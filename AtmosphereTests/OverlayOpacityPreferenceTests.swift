import XCTest
@testable import Atmosphere

final class OverlayOpacityPreferenceTests: XCTestCase {
    private var suiteName: String!
    private var userDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "OverlayOpacityPreferenceTests-\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)
        userDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        userDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsToFullyOpaque() {
        XCTAssertEqual(makePreference().value(), 1.0)
    }

    func testSavedOpacityPersists() {
        let preference = makePreference()

        XCTAssertEqual(preference.save(0.5), 0.5, accuracy: 0.001)
        XCTAssertEqual(makePreference().value(), 0.5, accuracy: 0.001)
    }

    func testValuesSnapToSupportedOptions() {
        let preference = makePreference()

        XCTAssertEqual(preference.save(0), 0.25)
        XCTAssertEqual(preference.save(0.44), 0.5)
        XCTAssertEqual(preference.save(0.82), 1.0)
        XCTAssertEqual(preference.save(2), 1.0)
    }

    func testNonFiniteValueFallsBackToDefault() {
        XCTAssertEqual(
            makePreference().save(.nan),
            OverlayOpacityPreference.defaultValue
        )
        XCTAssertEqual(
            makePreference().save(.infinity),
            OverlayOpacityPreference.defaultValue
        )
    }

    func testInvalidStoredTypeFallsBackToDefault() {
        userDefaults.set(
            "transparent",
            forKey: OverlayOpacityPreference.defaultStorageKey
        )

        XCTAssertEqual(
            makePreference().value(),
            OverlayOpacityPreference.defaultValue
        )
    }

    func testStoredOutOfRangeValueIsNormalizedOnLoad() {
        userDefaults.set(
            2.0,
            forKey: OverlayOpacityPreference.defaultStorageKey
        )

        XCTAssertEqual(
            makePreference().value(),
            1.0
        )
    }

    private func makePreference() -> OverlayOpacityPreference {
        OverlayOpacityPreference(userDefaults: userDefaults)
    }
}
