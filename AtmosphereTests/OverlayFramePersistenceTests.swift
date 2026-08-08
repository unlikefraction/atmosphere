import AppKit
import XCTest
@testable import Atmosphere

final class OverlayFramePersistenceTests: XCTestCase {
    func testFrameIsReachableWhenVisibleOnOneScreen() {
        let frame = NSRect(x: 300, y: 200, width: 720, height: 590)
        let screens = [NSRect(x: 0, y: 0, width: 1_440, height: 900)]

        XCTAssertTrue(OverlayFramePersistence.isReachable(frame, in: screens))
    }

    func testFrameCanBeRestoredOnSecondaryScreenCoordinates() {
        let frame = NSRect(x: 1_600, y: 180, width: 720, height: 590)
        let screens = [
            NSRect(x: 0, y: 0, width: 1_440, height: 900),
            NSRect(x: 1_440, y: 0, width: 1_920, height: 1_080)
        ]

        XCTAssertTrue(OverlayFramePersistence.isReachable(frame, in: screens))
    }

    func testOffscreenFrameIsRejectedAfterDisplayDisappears() {
        let frame = NSRect(x: 1_600, y: 180, width: 720, height: 590)
        let remainingScreen = NSRect(x: 0, y: 0, width: 1_440, height: 900)

        XCTAssertFalse(
            OverlayFramePersistence.isReachable(frame, in: [remainingScreen])
        )
    }

    func testTinyVisibleSliverIsNotEnoughToRestore() {
        let frame = NSRect(x: 1_400, y: 880, width: 720, height: 590)
        let screen = NSRect(x: 0, y: 0, width: 1_440, height: 900)

        XCTAssertFalse(OverlayFramePersistence.isReachable(frame, in: [screen]))
    }

    func testInvalidFrameIsRejected() {
        let invalid = NSRect(x: CGFloat.nan, y: 0, width: 720, height: 590)
        let screen = NSRect(x: 0, y: 0, width: 1_440, height: 900)

        XCTAssertFalse(OverlayFramePersistence.isReachable(invalid, in: [screen]))
    }
}

final class OverlayFrameGrowthTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1_440, height: 900)

    func testGrowingKeepsTheBottomEdgeFixed() {
        let compact = NSRect(x: 360, y: 300, width: 720, height: 88)

        let grown = OverlayFramePersistence.frame(growing: compact, to: 420, within: screen)

        XCTAssertEqual(grown.minY, compact.minY, accuracy: 0.001)
        XCTAssertEqual(grown.height, 420, accuracy: 0.001)
        XCTAssertEqual(grown.minX, compact.minX, accuracy: 0.001)
        XCTAssertEqual(grown.width, compact.width, accuracy: 0.001)
    }

    func testCollapsingAlsoKeepsTheBottomEdgeFixed() {
        let expanded = NSRect(x: 360, y: 300, width: 720, height: 520)

        let collapsed = OverlayFramePersistence.frame(growing: expanded, to: 88, within: screen)

        XCTAssertEqual(collapsed.minY, expanded.minY, accuracy: 0.001)
        XCTAssertEqual(collapsed.height, 88, accuracy: 0.001)
    }

    func testGrowthPastTheTopSlidesThePanelBackOnScreen() {
        let nearTop = NSRect(x: 360, y: 760, width: 720, height: 88)

        let grown = OverlayFramePersistence.frame(growing: nearTop, to: 480, within: screen)

        XCTAssertEqual(grown.maxY, screen.maxY - OverlayFramePersistence.screenMargin, accuracy: 0.001)
        XCTAssertTrue(OverlayFramePersistence.isReachable(grown, in: [screen]))
    }

    func testAPanelTallerThanTheDisplayIsCentredRatherThanPushedOff() {
        let frame = NSRect(x: 360, y: 400, width: 720, height: 88)

        let grown = OverlayFramePersistence.frame(growing: frame, to: 1_200, within: screen)

        XCTAssertEqual(grown.midY, screen.midY, accuracy: 0.001)
    }

    func testWithoutAScreenTheFrameIsLeftWhereTheContentPutIt() {
        let frame = NSRect(x: 360, y: 760, width: 720, height: 88)

        let grown = OverlayFramePersistence.frame(growing: frame, to: 480, within: nil)

        XCTAssertEqual(grown.minY, frame.minY, accuracy: 0.001)
    }

    func testInvalidHeightsAreIgnored() {
        let frame = NSRect(x: 360, y: 400, width: 720, height: 88)

        XCTAssertEqual(OverlayFramePersistence.frame(growing: frame, to: .nan, within: screen), frame)
        XCTAssertEqual(OverlayFramePersistence.frame(growing: frame, to: 0, within: screen), frame)
    }
}
