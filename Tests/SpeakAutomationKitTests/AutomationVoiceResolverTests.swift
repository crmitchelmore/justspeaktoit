import SpeakCore
import XCTest

/// How every host turns `--voice`, `--provider`, `--model` and `--favorite`
/// into one voice: identically, from the voices the app can use now.
final class AutomationVoiceResolverTests: XCTestCase {
    private let onDevice = AutomationVoice(
        id: "system/default", name: "System default", provider: "system", providerName: "macOS System", onDevice: true
    )
    private let daniel = AutomationVoice(
        id: "system/com.apple.voice.Daniel", name: "Daniel", provider: "system", providerName: "macOS System",
        onDevice: true
    )
    private let alloy = AutomationVoice(
        id: "openai/alloy", name: "Alloy", provider: "openai", providerName: "OpenAI",
        models: ["openai/tts-1", "openai/tts-1-hd"], model: "openai/tts-1"
    )
    private let nova = AutomationVoice(
        id: "openai/nova", name: "Nova", provider: "openai", providerName: "OpenAI",
        models: ["openai/tts-1"], model: "openai/tts-1", favorite: true
    )
    private let rachel = AutomationVoice(
        id: "elevenlabs/rachel", name: "Rachel", provider: "elevenlabs", providerName: "ElevenLabs",
        selected: true
    )

    private var voices: [AutomationVoice] { [onDevice, daniel, alloy, nova, rachel] }

    private func resolve(_ selection: AutomationSpeechSelection,
                         in voices: [AutomationVoice]? = nil) throws -> AutomationVoiceChoice {
        try AutomationVoiceResolver.resolve(selection, in: voices ?? self.voices)
    }

    private func assertError(_ selection: AutomationSpeechSelection, in voices: [AutomationVoice]? = nil,
                             _ code: AutomationErrorCode, _ fragment: String, line: UInt = #line) {
        XCTAssertThrowsError(try self.resolve(selection, in: voices), line: line) { error in
            let error = error as? AutomationError
            XCTAssertEqual(error?.code, code, line: line)
            XCTAssertTrue(error?.message.contains(fragment) == true, error?.message ?? "", line: line)
        }
    }

    func testDefault_usesTheAppsSelectedVoice() throws {
        let choice = try self.resolve(AutomationSpeechSelection())
        XCTAssertEqual(choice.voice.id, "elevenlabs/rachel")
        XCTAssertFalse(choice.isFallback)
    }

    func testDefault_fallsBackOnDeviceWhenNothingIsConfigured() throws {
        let choice = try self.resolve(AutomationSpeechSelection(), in: [onDevice, daniel, alloy])
        XCTAssertEqual(choice.voice.id, "system/default")
        XCTAssertTrue(choice.isFallback)
        self.assertError(AutomationSpeechSelection(), in: [alloy], .unsupportedCommand, "No voice is configured")
    }

    func testVoice_matchesIDThenNameAndRefusesAmbiguity() throws {
        XCTAssertEqual(try self.resolve(AutomationSpeechSelection(voice: "OPENAI/ALLOY")).voice.id, "openai/alloy")
        XCTAssertEqual(try self.resolve(AutomationSpeechSelection(voice: "daniel")).voice.id, daniel.id)
        var twin = nova
        twin.id = "openai/nova-2"
        self.assertError(AutomationSpeechSelection(voice: "Nova"), in: [nova, twin], .invalidArgument, "Pass an ID")
        self.assertError(AutomationSpeechSelection(voice: "Nobody"), .invalidArgument, "speak voices")
    }

    func testSystemKeyword_choosesTheOnDeviceVoice() throws {
        XCTAssertEqual(try self.resolve(AutomationSpeechSelection(voice: "system")).voice.id, "system/default")
        self.assertError(AutomationSpeechSelection(voice: "system"), in: [alloy], .unsupportedCommand, "on-device")
    }

    func testProvider_prefersSelectedThenFavouriteThenFirst() throws {
        XCTAssertEqual(try self.resolve(AutomationSpeechSelection(provider: "OpenAI")).voice.id, "openai/nova")
        XCTAssertEqual(try self.resolve(AutomationSpeechSelection(provider: "elevenlabs")).voice.id, rachel.id)
        self.assertError(AutomationSpeechSelection(provider: "cartesia"), .invalidArgument, "Save its key")
    }

    func testFavorite_choosesOnlyAmongFavourites() throws {
        XCTAssertEqual(try self.resolve(AutomationSpeechSelection(favorite: "nova")).voice.id, "openai/nova")
        self.assertError(AutomationSpeechSelection(favorite: "Alloy"), .invalidArgument, "favourite voice")
    }

    func testModel_acceptsFullOrShortIDsAndRefusesOthers() throws {
        XCTAssertEqual(try self.resolve(AutomationSpeechSelection(voice: "alloy")).model, "openai/tts-1")
        XCTAssertEqual(
            try self.resolve(AutomationSpeechSelection(voice: "alloy", model: "tts-1-hd")).model, "openai/tts-1-hd")
        self.assertError(AutomationSpeechSelection(voice: "nova", model: "tts-1-hd"), .invalidArgument, "choose")
        self.assertError(AutomationSpeechSelection(model: "x"), .invalidArgument, "no model choice")
    }
}
