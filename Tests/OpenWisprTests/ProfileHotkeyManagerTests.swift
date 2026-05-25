import AppKit
import XCTest
@testable import OpenWisprLib

final class ProfileHotkeyManagerTests: XCTestCase {
    private let cmdKeyCode: UInt16 = 55
    private let optionKeyCode: UInt16 = 58
    private let fnKeyCode: UInt16 = 63
    private let shiftKeyCode: UInt16 = 56
    private let spaceKeyCode: UInt16 = 49
    private let cmdFlag = UInt64(1 << 20)
    private let optionFlag = UInt64(1 << 19)
    private let fnFlag = UInt64(1 << 23)
    private let shiftFlag = UInt64(1 << 17)

    func testEmptyProfilesDoNotStart() {
        var starts: [String] = []
        let manager = ProfileHotkeyManager(
            profiles: [],
            onKeyDown: { starts.append($0.id) }
        )

        manager.handleEvent(flagsChanged(fnKeyCode, flags: fnFlag))

        XCTAssertEqual(starts, [])
    }

    func testToggleModeDefersBareModifierUntilRelease() {
        var starts: [String] = []
        let manager = makeManager { starts.append($0.id) }

        manager.handleEvent(flagsChanged(fnKeyCode, flags: fnFlag))

        XCTAssertEqual(starts, [])

        manager.handleEvent(flagsChanged(fnKeyCode, flags: 0))

        XCTAssertEqual(starts, ["fn"])
    }

    func testToggleModePrefersChordBeforeBareModifierRelease() {
        var starts: [String] = []
        let manager = makeManager { starts.append($0.id) }

        manager.handleEvent(flagsChanged(fnKeyCode, flags: fnFlag))
        manager.handleEvent(flagsChanged(shiftKeyCode, flags: fnFlag | shiftFlag))
        manager.handleEvent(flagsChanged(fnKeyCode, flags: shiftFlag))

        XCTAssertEqual(starts, ["shift-fn"])
    }

    func testToggleModeCancelsBareModifierWhenUnmatchedKeyIsPressed() {
        var starts: [String] = []
        let manager = makeManager { starts.append($0.id) }

        manager.handleEvent(flagsChanged(fnKeyCode, flags: fnFlag))
        manager.handleEvent(keyDown(spaceKeyCode, flags: fnFlag))
        manager.handleEvent(flagsChanged(fnKeyCode, flags: 0))

        XCTAssertEqual(starts, [])
    }

    func testModifierChordDoesNotUseStaleModifierState() {
        var starts: [String] = []
        let manager = ProfileHotkeyManager(
            profiles: [
                profile(id: "cmd-option", keyCode: optionKeyCode, modifiers: ["cmd"]),
            ],
            toggleMode: true,
            onKeyDown: { starts.append($0.id) }
        )

        manager.handleEvent(flagsChanged(cmdKeyCode, flags: cmdFlag))
        manager.handleEvent(flagsChanged(optionKeyCode, flags: optionFlag))

        XCTAssertEqual(starts, [])
    }

    func testModifierChordStartsWhenRequiredModifierIsPresent() {
        var starts: [String] = []
        let manager = ProfileHotkeyManager(
            profiles: [
                profile(id: "cmd-option", keyCode: optionKeyCode, modifiers: ["cmd"]),
            ],
            toggleMode: true,
            onKeyDown: { starts.append($0.id) }
        )

        manager.handleEvent(flagsChanged(cmdKeyCode, flags: cmdFlag))
        manager.handleEvent(flagsChanged(optionKeyCode, flags: cmdFlag | optionFlag))

        XCTAssertEqual(starts, ["cmd-option"])
    }

    func testModifierChordDoesNotRetriggerOnNonModifierKey() {
        var starts: [String] = []
        let manager = ProfileHotkeyManager(
            profiles: [
                profile(id: "cmd-option", keyCode: optionKeyCode, modifiers: ["cmd"]),
            ],
            toggleMode: true,
            onKeyDown: { starts.append($0.id) }
        )

        manager.handleEvent(flagsChanged(cmdKeyCode, flags: cmdFlag))
        manager.handleEvent(flagsChanged(optionKeyCode, flags: cmdFlag | optionFlag))
        manager.handleEvent(keyDown(spaceKeyCode, flags: cmdFlag | optionFlag))

        XCTAssertEqual(starts, ["cmd-option"])
    }

    func testHoldModeModifierChordStopsWhenAnyChordModifierIsReleased() {
        var starts: [String] = []
        var stops: [String] = []
        let manager = ProfileHotkeyManager(
            profiles: [
                profile(id: "cmd-option", keyCode: optionKeyCode, modifiers: ["cmd"]),
            ],
            toggleMode: false,
            onKeyDown: { starts.append($0.id) },
            onKeyUp: { stops.append($0.id) }
        )

        manager.handleEvent(flagsChanged(cmdKeyCode, flags: cmdFlag))
        manager.handleEvent(flagsChanged(optionKeyCode, flags: cmdFlag | optionFlag))
        manager.handleEvent(flagsChanged(cmdKeyCode, flags: optionFlag))

        XCTAssertEqual(starts, ["cmd-option"])
        XCTAssertEqual(stops, ["cmd-option"])
    }

    private func makeManager(onStart: @escaping (DictationProfile) -> Void) -> ProfileHotkeyManager {
        ProfileHotkeyManager(
            profiles: [
                profile(id: "fn", keyCode: fnKeyCode, modifiers: []),
                profile(id: "shift-fn", keyCode: fnKeyCode, modifiers: ["shift"]),
            ],
            toggleMode: true,
            onKeyDown: onStart
        )
    }

    private func profile(id: String, keyCode: UInt16, modifiers: [String]) -> DictationProfile {
        DictationProfile(
            id: id,
            hotkey: HotkeyConfig(keyCode: keyCode, modifiers: modifiers),
            modelSize: nil,
            language: nil,
            action: nil,
            targetLanguage: nil,
            translator: nil,
            polish: nil,
            transcriber: nil
        )
    }

    private func flagsChanged(_ keyCode: UInt16, flags: UInt64) -> NSEvent {
        event(type: .flagsChanged, keyCode: keyCode, flags: flags)
    }

    private func keyDown(_ keyCode: UInt16, flags: UInt64) -> NSEvent {
        event(type: .keyDown, keyCode: keyCode, flags: flags)
    }

    private func event(type: NSEvent.EventType, keyCode: UInt16, flags: UInt64) -> NSEvent {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}
