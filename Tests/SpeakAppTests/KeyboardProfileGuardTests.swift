import Foundation
import XCTest

/// Source-level guards for the keyboard's dictation-profile chip. The keyboard
/// extension is not unit-testable on its own, so the invariants that make
/// profile post-processing safe are asserted against its sources here, next to
/// the other keyboard distribution guards.
final class KeyboardProfileGuardTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// A dictation profile rewrites the finished transcript inside the
    /// extension, which holds no API keys. Post-processing must therefore stay
    /// on Apple's on-device model and never open a network connection.
    func testProfilePostProcessingStaysOnDevice() throws {
        let model = try source("JustSpeakKeyboard/KeyboardViewModel.swift")
        let rootView = try source("JustSpeakKeyboard/KeyboardRootView.swift")

        XCTAssertTrue(model.contains("AppleFoundationModelPolisher.process"))
        XCTAssertTrue(model.contains("AppleFoundationModelPolisher.isAvailable"))
        for keyboardSource in [model, rootView] {
            XCTAssertFalse(keyboardSource.contains("URLSession"))
            XCTAssertFalse(keyboardSource.contains("apiKey"))
        }
    }

    /// The rewrite deletes text before the caret, so it may only run while the
    /// caret still follows what this session dictated, and must be abandoned
    /// when the destination or the session changes.
    func testPendingRewriteIsAnchoredAndAbandonedSafely() throws {
        let model = try source("JustSpeakKeyboard/KeyboardViewModel.swift")

        XCTAssertTrue(model.contains("cursorStillFollows"))
        XCTAssertTrue(model.contains("context.hasSuffix(anchor)"))
        XCTAssertTrue(model.contains("cancelPolish()"))
        XCTAssertTrue(model.contains("dispatch(.polishFailed)"))
    }

    /// One tap per switch, from the App Group-backed selection, blocked while
    /// capture or a rewrite is in flight.
    func testProfileChipIsOneTapAndDisabledWhileBusy() throws {
        let model = try source("JustSpeakKeyboard/KeyboardViewModel.swift")
        let rootView = try source("JustSpeakKeyboard/KeyboardRootView.swift")

        XCTAssertTrue(model.contains("preferences.profileSelection()"))
        XCTAssertTrue(model.contains("preferences.selectProfile(next)"))
        XCTAssertTrue(rootView.contains("keyboardProfileChip"))
        XCTAssertTrue(rootView.contains("model.cycleProfile"))
        XCTAssertTrue(rootView.contains(".disabled(model.isBusy)"))
    }

    /// The containing app mirrors its post-processing switch into the App Group
    /// so the keyboard's chip follows the app across restarts.
    func testContainingAppMirrorsItsPostProcessingPreference() throws {
        let coordinator = try source("Sources/SpeakiOS/Services/KeyboardInstantDictationCoordinator.swift")
        let setup = try source("Sources/SpeakiOS/Views/KeyboardSetupView.swift")

        for appSource in [coordinator, setup] {
            XCTAssertTrue(appSource.contains("mirrorAppProfilePreference("))
            XCTAssertTrue(appSource.contains("polishesTranscripts: AppSettings.shared.postProcessingEnabled"))
        }
    }
}
