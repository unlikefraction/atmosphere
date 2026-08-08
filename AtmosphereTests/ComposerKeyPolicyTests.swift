import AppKit
import XCTest
@testable import Atmosphere

final class ComposerKeyPolicyTests: XCTestCase {
    func testReturnSubmits() {
        XCTAssertEqual(
            action(),
            .submit
        )
    }

    func testShiftReturnInsertsNewline() {
        XCTAssertEqual(
            action(modifiers: [.shift]),
            .insertNewline
        )
    }

    func testFieldEditorNewlineCommandUsesSameContract() {
        XCTAssertEqual(
            action(commandSelector: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))),
            .submit
        )
        XCTAssertEqual(
            action(
                commandSelector: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
                modifiers: [.shift]
            ),
            .insertNewline
        )
    }

    func testMarkedTextDefersToInputMethod() {
        XCTAssertEqual(
            action(hasMarkedText: true),
            .deferToTextSystem
        )
    }

    func testOtherKeysDeferToTextSystem() {
        XCTAssertEqual(
            action(commandSelector: #selector(NSResponder.deleteBackward(_:))),
            .deferToTextSystem
        )
    }

    func testOptionAndControlReturnRemainNativeTextCommands() {
        XCTAssertEqual(action(modifiers: [.option]), .deferToTextSystem)
        XCTAssertEqual(action(modifiers: [.control]), .deferToTextSystem)
    }

    func testCommandReturnSubmits() {
        XCTAssertEqual(action(modifiers: [.command]), .submit)
    }

    func testRepeatedReturnIsConsumedWithoutSubmittingAgain() {
        XCTAssertEqual(action(isRepeat: true), .consume)
    }

    private func action(
        commandSelector: Selector = #selector(NSResponder.insertNewline(_:)),
        modifiers: NSEvent.ModifierFlags = [],
        hasMarkedText: Bool = false,
        isRepeat: Bool = false
    ) -> ComposerKeyAction {
        ComposerKeyPolicy.action(
            for: commandSelector,
            modifiers: modifiers,
            hasMarkedText: hasMarkedText,
            isRepeat: isRepeat
        )
    }
}

final class ComposerFocusPolicyTests: XCTestCase {
    func testVisibleEnabledComposerAcceptsRequestedFocus() {
        XCTAssertTrue(
            ComposerFocusPolicy.shouldFocus(
                isRequested: true,
                isEnabled: true,
                isWindowVisible: true,
                hasAttachedSheet: false
            )
        )
    }

    func testComposerDoesNotStealFocusFromAttachedSheet() {
        XCTAssertFalse(
            ComposerFocusPolicy.shouldFocus(
                isRequested: true,
                isEnabled: true,
                isWindowVisible: true,
                hasAttachedSheet: true
            )
        )
    }

    func testHiddenDisabledOrUnrequestedComposerDoesNotFocus() {
        XCTAssertFalse(
            ComposerFocusPolicy.shouldFocus(
                isRequested: true,
                isEnabled: true,
                isWindowVisible: false,
                hasAttachedSheet: false
            )
        )
        XCTAssertFalse(
            ComposerFocusPolicy.shouldFocus(
                isRequested: true,
                isEnabled: false,
                isWindowVisible: true,
                hasAttachedSheet: false
            )
        )
        XCTAssertFalse(
            ComposerFocusPolicy.shouldFocus(
                isRequested: false,
                isEnabled: true,
                isWindowVisible: true,
                hasAttachedSheet: false
            )
        )
    }
}

@MainActor
final class ComposerTextScrollViewTests: XCTestCase {
    func testComposerStartsCompactGrowsAndCapsItsHeight() {
        let scrollView = ComposerTextScrollView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: 320,
                height: ComposerTextScrollView.minimumHeight
            )
        )
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 320,
                height: ComposerTextScrollView.minimumHeight
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        window.contentView?.layoutSubtreeIfNeeded()

        setText("", in: scrollView)
        XCTAssertEqual(
            scrollView.currentPreferredHeight,
            ComposerTextScrollView.minimumHeight,
            accuracy: 0.5
        )

        setText("One\nTwo\nThree", in: scrollView)
        XCTAssertGreaterThan(
            scrollView.currentPreferredHeight,
            ComposerTextScrollView.minimumHeight
        )

        let longDraft = Array(repeating: "A line of draft text", count: 30)
            .joined(separator: "\n")
        setText(longDraft, in: scrollView)
        XCTAssertEqual(
            scrollView.currentPreferredHeight,
            ComposerTextScrollView.maximumHeight,
            accuracy: 0.5
        )

        setText("", in: scrollView)
        XCTAssertEqual(
            scrollView.currentPreferredHeight,
            ComposerTextScrollView.minimumHeight,
            accuracy: 0.5
        )

        withExtendedLifetime(window) {}
    }

    private func setText(_ text: String, in scrollView: ComposerTextScrollView) {
        scrollView.textView.string = text
        scrollView.layoutSubtreeIfNeeded()
        scrollView.refreshLayout(scrollToSelection: false)
    }
}
