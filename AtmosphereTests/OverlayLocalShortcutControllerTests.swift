import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Atmosphere

final class OverlayLocalShortcutControllerTests: XCTestCase {
    @MainActor
    func testBareReservedKeysTriggerAndAreConsumed() throws {
        var voiceCount = 0
        var screenshotCount = 0
        let controller = OverlayLocalShortcutController(
            onToggleAudio: { voiceCount += 1 },
            onCaptureScreenshot: { screenshotCount += 1 }
        )
        controller.setEnabled(true)

        XCTAssertNil(
            OverlayLocalShortcutController.routeMonitoredEvent(
                try keyEvent(keyCode: kVK_ANSI_Backslash, characters: "\\"),
                through: controller
            )
        )
        XCTAssertNil(
            OverlayLocalShortcutController.routeMonitoredEvent(
                try keyEvent(keyCode: kVK_ANSI_Grave, characters: "`"),
                through: controller
            )
        )
        XCTAssertEqual(voiceCount, 1)
        XCTAssertEqual(screenshotCount, 1)
    }

    @MainActor
    func testReservedKeyRepeatIsConsumedWithoutRetriggering() throws {
        var voiceCount = 0
        let controller = OverlayLocalShortcutController(
            onToggleAudio: { voiceCount += 1 },
            onCaptureScreenshot: {}
        )
        controller.setEnabled(true)

        XCTAssertNil(
            OverlayLocalShortcutController.routeMonitoredEvent(
                try keyEvent(
                    keyCode: kVK_ANSI_Backslash,
                    characters: "\\"
                ),
                through: controller
            )
        )
        XCTAssertNil(
            OverlayLocalShortcutController.routeMonitoredEvent(
                try keyEvent(
                    keyCode: kVK_ANSI_Backslash,
                    characters: "\\",
                    isRepeat: true
                ),
                through: controller
            )
        )
        XCTAssertEqual(voiceCount, 1)
    }

    @MainActor
    func testModifiedOrDisabledReservedKeysRemainTextInput() throws {
        var actionCount = 0
        let controller = OverlayLocalShortcutController(
            onToggleAudio: { actionCount += 1 },
            onCaptureScreenshot: { actionCount += 1 }
        )

        XCTAssertNotNil(
            OverlayLocalShortcutController.routeMonitoredEvent(
                try keyEvent(keyCode: kVK_ANSI_Grave, characters: "`"),
                through: controller
            )
        )

        controller.setEnabled(true)
        for modifier: NSEvent.ModifierFlags in [
            .command,
            .control,
            .option,
            .shift,
            .function
        ] {
            let event = try keyEvent(
                keyCode: kVK_ANSI_Grave,
                characters: modifier == .shift ? "~" : "`",
                modifiers: modifier
            )
            let routed = OverlayLocalShortcutController.routeMonitoredEvent(
                event,
                through: controller
            )
            XCTAssertTrue(routed === event)
        }
        XCTAssertEqual(actionCount, 0)
    }

    @MainActor
    func testCapsLockDoesNotDisableReservedKeysAndUnrelatedKeysPassThrough() throws {
        var voiceCount = 0
        let controller = OverlayLocalShortcutController(
            onToggleAudio: { voiceCount += 1 },
            onCaptureScreenshot: {}
        )
        controller.setEnabled(true)

        XCTAssertNil(
            OverlayLocalShortcutController.routeMonitoredEvent(
                try keyEvent(
                    keyCode: kVK_ANSI_Backslash,
                    characters: "\\",
                    modifiers: .capsLock
                ),
                through: controller
            )
        )
        XCTAssertEqual(voiceCount, 1)

        let unrelated = try keyEvent(keyCode: kVK_ANSI_A, characters: "a")
        let routed = OverlayLocalShortcutController.routeMonitoredEvent(
            unrelated,
            through: controller
        )
        XCTAssertTrue(routed === unrelated)
    }

    @MainActor
    func testMonitorForwardsEventWhenControllerIsGone() throws {
        let event = try keyEvent(keyCode: kVK_ANSI_Backslash, characters: "\\")

        let routed = OverlayLocalShortcutController.routeMonitoredEvent(
            event,
            through: nil
        )

        XCTAssertTrue(routed === event)
    }

    @MainActor
    func testCommandKeysMapToTheirCommands() throws {
        XCTAssertEqual(
            AtmosphereCommandMap.command(forKeyCode: kVK_ANSI_M, modifiers: .command),
            .switchModel
        )
        XCTAssertEqual(
            AtmosphereCommandMap.command(forKeyCode: kVK_ANSI_N, modifiers: .command),
            .newConversation
        )
        // Command-backslash belongs to the global hot key and must pass through.
        XCTAssertNil(
            AtmosphereCommandMap.command(forKeyCode: kVK_ANSI_Backslash, modifiers: .command)
        )
        // Bare M is text input.
        XCTAssertNil(AtmosphereCommandMap.command(forKeyCode: kVK_ANSI_M, modifiers: []))
    }

    @MainActor
    func testCommandKeysAreRoutedAndConsumed() throws {
        var received: [AtmosphereCommand] = []
        let controller = OverlayLocalShortcutController(
            onToggleAudio: {},
            onCaptureScreenshot: {},
            onCommand: { received.append($0) }
        )
        controller.setEnabled(true)

        XCTAssertNil(
            OverlayLocalShortcutController.routeMonitoredEvent(
                try keyEvent(keyCode: kVK_ANSI_M, characters: "m", modifiers: .command),
                through: controller
            )
        )
        XCTAssertEqual(received, [.switchModel])
    }

    private func keyEvent(
        keyCode: Int,
        characters: String,
        modifiers: NSEvent.ModifierFlags = [],
        isRepeat: Bool = false
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: isRepeat,
                keyCode: UInt16(keyCode)
            )
        )
    }
}
