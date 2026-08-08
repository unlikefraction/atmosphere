import XCTest
@testable import Atmosphere

final class SkyPhaseTests: XCTestCase {
    func testEveryHourOfTheDayResolvesToAPhase() {
        for hour in 0..<24 {
            XCTAssertNotNil(SkyPhase.current(hour: hour), "hour \(hour)")
        }
    }

    func testPhaseBoundariesFollowTheSun() {
        XCTAssertEqual(SkyPhase.current(hour: 0), .night)
        XCTAssertEqual(SkyPhase.current(hour: 4), .night)
        XCTAssertEqual(SkyPhase.current(hour: 5), .dawn)
        XCTAssertEqual(SkyPhase.current(hour: 7), .dawn)
        XCTAssertEqual(SkyPhase.current(hour: 8), .day)
        XCTAssertEqual(SkyPhase.current(hour: 16), .day)
        XCTAssertEqual(SkyPhase.current(hour: 17), .dusk)
        XCTAssertEqual(SkyPhase.current(hour: 19), .dusk)
        XCTAssertEqual(SkyPhase.current(hour: 20), .night)
        XCTAssertEqual(SkyPhase.current(hour: 23), .night)
    }

    func testOnlyNightCarriesStars() {
        XCTAssertTrue(SkyPhase.night.isDark)
        for phase in [SkyPhase.dawn, .day, .dusk] {
            XCTAssertFalse(phase.isDark, "\(phase)")
        }
    }

    func testEveryPhaseHasAGlyphAndGreeting() {
        for phase in SkyPhase.allCases {
            XCTAssertFalse(phase.glyph.isEmpty, "\(phase)")
            XCTAssertFalse(phase.greeting.isEmpty, "\(phase)")
        }
    }

    func testPhaseIsDerivedFromTheGivenDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: 2026, month: 8, day: 5, hour: 18)
        let evening = calendar.date(from: components)!

        XCTAssertEqual(SkyPhase.now(evening, calendar: calendar), .dusk)
    }
}
