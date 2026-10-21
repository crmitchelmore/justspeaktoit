import SpeakCore
@testable import SpeakDesktop
import XCTest

final class DesktopLinuxGlobalShortcutPlanTests: XCTestCase {
    private let dictation = DesktopShortcutLinuxChord(keysym: 0x20, modifiers: 12)
    private var runnable: Set<DesktopShortcutAction> {
        Set(DesktopShortcutAction.allCases).subtracting([.editSelectionByVoice])
    }

    private func plan(
        _ bindings: DesktopShortcutBindings = .defaults, runnable: Set<DesktopShortcutAction>? = nil
    ) -> DesktopLinuxGlobalShortcutPlan {
        DesktopLinuxGlobalShortcutPlan(bindings: bindings, runnable: runnable ?? self.runnable, dictation: dictation)
    }

    func testDefaultProjectionUsesOnlyCanonicalEnabledSupportedGlobals() {
        let result = plan()
        let expected = DesktopShortcutAction.allCases.filter {
            let binding = DesktopShortcutBindings.defaults[$0]
            return binding.isEnabled && binding.isGlobal && $0.supportsGlobalShortcut && runnable.contains($0)
        }
        XCTAssertEqual(result.entries.map(\.action), expected)
        for entry in result.entries {
            XCTAssertEqual(Int(entry.identifier), DesktopShortcutAction.allCases.firstIndex(of: entry.action))
            XCTAssertEqual(entry.chord, DesktopShortcutBindings.defaults[entry.action].linuxChord)
        }
        XCTAssertNotNil(result.refusals[.editSelectionByVoice])
    }

    func testDisabledAndWindowLocalBindingsNeverEnterTheGlobalPlan() {
        var bindings = DesktopShortcutBindings.defaults
        for action in DesktopShortcutAction.allCases {
            var binding = bindings[action]
            binding.isGlobal = false
            bindings[action] = binding
        }
        XCTAssertTrue(plan(bindings).entries.isEmpty)
        for action in DesktopShortcutAction.allCases {
            var binding = bindings[action]
            binding.isGlobal = true
            binding.isEnabled = false
            bindings[action] = binding
        }
        XCTAssertTrue(plan(bindings).entries.isEmpty)
        XCTAssertTrue(plan(bindings).refusals.isEmpty)
    }

    func testCapabilityChangesDoNotRequireAnotherCatalogue() {
        XCTAssertTrue(plan(runnable: []).entries.isEmpty)
        for action in DesktopShortcutAction.allCases where action.supportsGlobalShortcut {
            var bindings = DesktopShortcutBindings.defaults
            for candidate in DesktopShortcutAction.allCases {
                var binding = bindings[candidate]
                binding.isEnabled = candidate == action
                binding.isGlobal = true
                bindings[candidate] = binding
            }
            XCTAssertEqual(plan(bindings, runnable: [action]).entries.map(\.action), [action])
        }
    }

    func testDictationCollisionIsRefusedWithoutChangingSavedBindings() throws {
        var bindings = DesktopShortcutBindings.defaults
        bindings[.speakClipboard] = try XCTUnwrap(
            DesktopShortcutBinding(linux: dictation, isGlobal: true, isEnabled: true)
        )
        let before = bindings
        let result = plan(bindings)
        XCTAssertFalse(result.entries.contains { $0.action == .speakClipboard })
        XCTAssertTrue(result.refusals[.speakClipboard]?.contains("dictation") == true)
        XCTAssertEqual(bindings, before)
    }

    func testHostCapabilityCannotPromoteWindowOnlyActionsToGlobal() {
        var bindings = DesktopShortcutBindings.defaults
        for action in DesktopShortcutAction.allCases {
            var binding = bindings[action]
            binding.isEnabled = true
            binding.isGlobal = true
            bindings[action] = binding
        }
        let result = plan(bindings, runnable: Set(DesktopShortcutAction.allCases))
        XCTAssertTrue(result.entries.allSatisfy { $0.action.supportsGlobalShortcut })
        for action in DesktopShortcutAction.allCases where !action.supportsGlobalShortcut {
            XCTAssertNotNil(result.refusals[action])
        }
    }

    func testDuplicateChordsKeepCanonicalFirstActionOnly() {
        var bindings = DesktopShortcutBindings.defaults
        bindings[.speakClipboard] = bindings[.speakSelectedText]
        let result = plan(bindings)
        XCTAssertTrue(result.entries.contains { $0.action == .speakSelectedText })
        XCTAssertFalse(result.entries.contains { $0.action == .speakClipboard })
        XCTAssertTrue(
            result.refusals[.speakClipboard]?.contains(DesktopShortcutAction.speakSelectedText.displayName) == true
        )
    }

    func testOrdinaryTypingIsNotGrabbedAndMacControlIsPreservedUnregistered() {
        var bindings = DesktopShortcutBindings.defaults
        bindings[.speakClipboard] = DesktopShortcutBinding(
            keyCode: 49, modifiers: .shift, isGlobal: true, isEnabled: true
        )
        bindings[.speakSelectedText] = DesktopShortcutBinding(
            keyCode: 17, modifiers: .control, isGlobal: true, isEnabled: true
        )
        let result = plan(bindings)
        XCTAssertNotNil(result.refusals[.speakClipboard])
        XCTAssertNotNil(result.refusals[.speakSelectedText])
        XCTAssertFalse(result.entries.contains { [.speakClipboard, .speakSelectedText].contains($0.action) })
    }

    func testHighFunctionKeysCanBeGlobalWithoutCapturingTyping() throws {
        let key = try XCTUnwrap(DesktopShortcutKey.all.first { $0.linuxKeysym == 0xFFCA })
        var bindings = DesktopShortcutBindings.defaults
        bindings[.speakClipboard] = DesktopShortcutBinding(
            keyCode: key.macKeyCode, modifiers: [], isGlobal: true, isEnabled: true
        )
        XCTAssertEqual(plan(bindings).entries.first { $0.action == .speakClipboard }?.chord.keysym, 0xFFCA)
    }
}
