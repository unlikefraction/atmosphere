import AppKit
import SwiftUI
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

@MainActor
final class OverlayWindowDragTests: XCTestCase {
    func testFooterMouseDownStartsNativeWindowDrag() throws {
        let window = DragRecordingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let dragView = OverlayWindowDragView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        content.addSubview(dragView)
        window.contentView = content
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 100, y: 16),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))

        dragView.mouseDown(with: event)

        XCTAssertTrue(window.dragEvent === event)
        XCTAssertTrue(dragView.acceptsFirstMouse(for: event))
    }

    func testFooterDragBackgroundLeavesButtonsAndComposerInFront() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let dragView = OverlayWindowDragView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        let button = NSButton(frame: NSRect(x: 200, y: 4, width: 80, height: 24))
        let composer = NSTextView(frame: NSRect(x: 0, y: 32, width: 300, height: 68))
        content.addSubview(dragView)
        content.addSubview(button)
        content.addSubview(composer)

        XCTAssertTrue(content.hitTest(NSPoint(x: 100, y: 16)) === dragView)
        XCTAssertTrue(content.hitTest(NSPoint(x: 220, y: 16)) === button)
        XCTAssertTrue(content.hitTest(NSPoint(x: 100, y: 60)) === composer)
    }

    func testSwiftUIFooterPassesEmptyAndPassiveAreasToDragBackground() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: Atmo.Metric.footerHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: FooterDragFixture())
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 720, height: Atmo.Metric.footerHeight)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        for x: CGFloat in [30, 200, 400] {
            XCTAssertTrue(
                host.hitTest(NSPoint(x: x, y: Atmo.Metric.footerHeight / 2)) is OverlayWindowDragView,
                "Passive status or empty footer area should start a drag at x=\(x)"
            )
        }
        for x: CGFloat in [100, 650] {
            let hit = try XCTUnwrap(host.hitTest(NSPoint(x: x, y: Atmo.Metric.footerHeight / 2)))
            XCTAssertFalse(hit is OverlayWindowDragView, "Footer buttons must keep receiving clicks")
        }
    }

    private struct FooterDragFixture: View {
        var body: some View {
            HStack(spacing: 8) {
                Text("Status")
                    .allowsHitTesting(false)
                Button("Model") {}
                    .buttonStyle(AtmoFooterButtonStyle())
                    .frame(width: 80)
                Spacer(minLength: 8)
                Button("More") {}
                    .buttonStyle(AtmoFooterButtonStyle())
                    .frame(width: 80)
            }
            .padding(.horizontal, Atmo.Metric.gutter)
            .frame(width: 720, height: Atmo.Metric.footerHeight)
            .background {
                OverlayWindowDragArea()
                    .background(Color.primary.opacity(0.035))
                    .accessibilityHidden(true)
            }
        }
    }

    private final class DragRecordingWindow: NSWindow {
        var dragEvent: NSEvent?

        override func performDrag(with event: NSEvent) {
            dragEvent = event
        }
    }
}
