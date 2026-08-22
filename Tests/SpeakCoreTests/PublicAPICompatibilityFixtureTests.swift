import Foundation
import XCTest

import SpeakCore

/// External-consumer compile fixture (issue #680): code written against the
/// pre-#628 exported `SpeakCore` API must keep compiling through the
/// deprecated shims. This file deliberately uses the plain `import` (no
/// `@testable`) and only the public surface, exactly as an external SwiftPM
/// consumer would.
@available(*, deprecated, message: "Exercises deprecated compatibility shims on purpose")
final class PublicAPICompatibilityFixtureTests: XCTestCase {
    func testSpeakErrorMessage_userMessage_keepsThePre628CallShape() {
        let network = SpeakErrorMessage.userMessage(for: URLError(.notConnectedToInternet))
        XCTAssertFalse(network.title.isEmpty)
        XCTAssertFalse(network.message.isEmpty)
        _ = network.action

        let keychain = SpeakErrorMessage.userMessage(for: SecureStorageError.valueNotFound)
        XCTAssertFalse(keychain.title.isEmpty)
    }

    func testKeyboardHandoffStore_keepsThePre777Initializer() throws {
        // #790: `init(defaults:)` was removed by the v4 handoff layout; it is
        // back, detecting the role from the process like `shared` does, and
        // drives the same store as the explicit-role initializer.
        let suite = "PublicAPICompatibility.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = KeyboardHandoffStore(defaults: defaults)
        XCTAssertTrue(store.isAvailable)
        XCTAssertFalse(KeyboardHandoffStore(defaults: nil).isAvailable)

        let request = try store.createRequest()
        let explicitRole = KeyboardHandoffStore(defaults: defaults, role: .containingApp)
        XCTAssertEqual(explicitRole.activeRecord()?.requestID, request.requestID)
        XCTAssertEqual(try explicitRole.markRecording(requestID: request.requestID).phase, .recording)
        XCTAssertEqual(store.activeRecord()?.phase, .recording)
    }

    func testDictationProfile_keepsThePre782Initializer() {
        // #791: the initializer without `transcriptionRouting:` is back; a
        // profile created through it derives its routing from the identifier,
        // as profiles saved before routing metadata existed always have.
        let profile = DictationProfile(
            id: UUID(),
            name: "Legacy",
            matchers: [DictationProfileMatcher(value: "com.example.app")],
            transcriptionModelID: "local/whisperkit/tiny",
            polishEnabled: true,
            polishModelID: "openai/gpt-5-mini",
            polishPrompt: "Tidy this.",
            polishOutputLanguage: "en",
            polishIncludeLexiconDirectives: true,
            polishIncludeContextTags: false,
            languageIdentifier: "en_GB"
        )

        XCTAssertNil(profile.transcriptionRouting)
        XCTAssertEqual(profile.resolvedTranscriptionOverride?.routing, .localBatch)
        XCTAssertEqual(profile.resolvedTranscriptionOverride?.modelID, "local/whisperkit/tiny")
        XCTAssertEqual(profile.polishModelID, "openai/gpt-5-mini")
        XCTAssertEqual(profile.languageIdentifier, "en_GB")

        let routed = DictationProfile(
            name: "Explicit",
            transcriptionModelID: "deepgram/nova-4-custom-streaming",
            transcriptionRouting: .remoteStreaming
        )
        XCTAssertEqual(routed.resolvedTranscriptionOverride?.routing, .remoteStreaming)
    }
}
