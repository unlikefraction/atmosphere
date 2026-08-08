import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Atmosphere

final class AtmosphereCommandMapTests: XCTestCase {
    func testCommandKeysMapToTheirActions() {
        XCTAssertEqual(
            AtmosphereCommandMap.command(forKeyCode: kVK_ANSI_N, modifiers: .command),
            .newConversation
        )
        XCTAssertEqual(
            AtmosphereCommandMap.command(forKeyCode: kVK_Delete, modifiers: .command),
            .clearAndHide
        )
        XCTAssertEqual(
            AtmosphereCommandMap.command(forKeyCode: kVK_ANSI_Slash, modifiers: .command),
            .toggleShortcuts
        )
        XCTAssertEqual(
            AtmosphereCommandMap.command(
                forKeyCode: kVK_ANSI_C,
                modifiers: [.command, .shift]
            ),
            .copyLastAnswer
        )
    }

    func testArrowKeysRecallHistoryWithOrWithoutTheFunctionFlag() {
        XCTAssertEqual(
            AtmosphereCommandMap.command(forKeyCode: kVK_UpArrow, modifiers: .command),
            .historyOlder
        )
        XCTAssertEqual(
            AtmosphereCommandMap.command(
                forKeyCode: kVK_DownArrow,
                modifiers: [.command, .function]
            ),
            .historyNewer
        )
    }

    func testGlobalAndSystemShortcutsAreNotClaimed() {
        // Command-backslash belongs to the global show/hide hot key.
        XCTAssertNil(
            AtmosphereCommandMap.command(forKeyCode: kVK_ANSI_Backslash, modifiers: .command)
        )
        // Command-grave belongs to the system's window cycling.
        XCTAssertNil(
            AtmosphereCommandMap.command(forKeyCode: kVK_ANSI_Grave, modifiers: .command)
        )
        // Plain typing is never a command.
        XCTAssertNil(AtmosphereCommandMap.command(forKeyCode: kVK_ANSI_N, modifiers: []))
        XCTAssertNil(
            AtmosphereCommandMap.command(forKeyCode: kVK_ANSI_N, modifiers: [.command, .option])
        )
    }

    func testEditingShortcutsStayWithTheTextSystem() {
        for keyCode in [kVK_ANSI_A, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z] {
            XCTAssertNil(
                AtmosphereCommandMap.command(forKeyCode: keyCode, modifiers: .command),
                "⌘\(keyCode) must remain available to the composer"
            )
        }
    }

    func testOnlyHistorySteppingRepeatsWhileHeld() {
        for command in AtmosphereCommand.allCases {
            let expected = command == .historyOlder || command == .historyNewer
            XCTAssertEqual(command.repeatsWhenHeld, expected, "\(command)")
        }
    }

    func testEveryCommandDocumentsKeysForTheShortcutSheet() {
        for command in AtmosphereCommand.allCases {
            XCTAssertFalse(command.title.isEmpty, "\(command)")
            XCTAssertFalse(command.keys.isEmpty, "\(command)")
        }
    }

    @MainActor
    func testMonitorRoutesCommandsAndConsumesTheEvent() throws {
        var received: [AtmosphereCommand] = []
        let controller = OverlayLocalShortcutController(
            onToggleAudio: {},
            onCaptureScreenshot: {},
            onCommand: { received.append($0) }
        )
        controller.setEnabled(true)

        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "n",
                charactersIgnoringModifiers: "n",
                isARepeat: false,
                keyCode: UInt16(kVK_ANSI_N)
            )
        )

        XCTAssertNil(
            OverlayLocalShortcutController.routeMonitoredEvent(event, through: controller)
        )
        XCTAssertEqual(received, [.newConversation])
    }

    @MainActor
    func testDisabledMonitorLeavesCommandsToTheSystem() throws {
        var received: [AtmosphereCommand] = []
        let controller = OverlayLocalShortcutController(
            onToggleAudio: {},
            onCaptureScreenshot: {},
            onCommand: { received.append($0) }
        )

        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "n",
                charactersIgnoringModifiers: "n",
                isARepeat: false,
                keyCode: UInt16(kVK_ANSI_N)
            )
        )

        XCTAssertTrue(
            OverlayLocalShortcutController.routeMonitoredEvent(event, through: controller) === event
        )
        XCTAssertTrue(received.isEmpty)
    }

    @MainActor
    func testHeldCommandFiresOnceExceptForHistoryStepping() throws {
        var received: [AtmosphereCommand] = []
        let controller = OverlayLocalShortcutController(
            onToggleAudio: {},
            onCaptureScreenshot: {},
            onCommand: { received.append($0) }
        )
        controller.setEnabled(true)

        func repeated(keyCode: Int, characters: String) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: .command,
                    timestamp: 0,
                    windowNumber: 0,
                    context: nil,
                    characters: characters,
                    charactersIgnoringModifiers: characters,
                    isARepeat: true,
                    keyCode: UInt16(keyCode)
                )
            )
        }

        _ = OverlayLocalShortcutController.routeMonitoredEvent(
            try repeated(keyCode: kVK_ANSI_N, characters: "n"),
            through: controller
        )
        XCTAssertTrue(received.isEmpty)

        _ = OverlayLocalShortcutController.routeMonitoredEvent(
            try repeated(keyCode: kVK_UpArrow, characters: "\u{F700}"),
            through: controller
        )
        XCTAssertEqual(received, [.historyOlder])
    }
}
