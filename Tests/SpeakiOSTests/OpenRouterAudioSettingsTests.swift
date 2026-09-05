#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore
import XCTest

@testable import SpeakiOSLib

@MainActor
final class OpenRouterAudioSettingsTests: XCTestCase {
    func testDynamicTranscriptionSelectionUsesNormalBatchPreferences() {
        let settings = AppSettings.shared
        let original = settings.batchTranscriptionModel
        let originalMode = settings.transcriptionMode
        let originalRemoteMode = settings.rememberedRemoteTranscriptionMode
        defer {
            settings.batchTranscriptionModel = original
            settings.transcriptionMode = originalMode
            settings.rememberedRemoteTranscriptionMode = originalRemoteMode
        }
        let identifier = "openrouter/transcription/example/new-model"
        settings.selectOpenRouterTranscription(identifier)
        XCTAssertEqual(settings.batchTranscriptionModel, identifier)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "batchTranscriptionModel"), identifier)
        XCTAssertEqual(settings.transcriptionMode, .batch)
        XCTAssertEqual(settings.rememberedRemoteTranscriptionMode, .batch)
        XCTAssertTrue(AppSettings.supportsBatchModel(identifier))
        XCTAssertEqual(IOSBatchTranscriptionRoute.route(for: identifier), .openRouter)
    }

    func testDynamicSpeechSelectionPersistsAndIsNeverReplacedByValidation() {
        let settings = OpenClawSettings.shared
        let originalProvider = settings.ttsProvider
        let originalModel = settings.ttsModel
        let originalVoice = settings.ttsVoice
        let originalName = settings.ttsVoiceName
        let originalSpeed = settings.ttsSpeed
        defer {
            settings.ttsProvider = originalProvider
            settings.ttsModel = originalModel
            settings.ttsVoice = originalVoice
            settings.ttsVoiceName = originalName
            settings.ttsSpeed = originalSpeed
        }
        let selection = OpenRouterSpeechSelection(modelID: "example/new-speech", voice: "custom-voice")
        settings.selectOpenRouterSpeech(selection.id)
        settings.validateVoiceModelCombination()
        XCTAssertEqual(settings.ttsProvider, .openrouter)
        XCTAssertEqual(settings.ttsModel, selection.id)
        XCTAssertEqual(settings.ttsVoice, "custom-voice")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "openclaw.ttsModel"), selection.id)
        settings.ttsModel = "openrouter/speech/retired-selection"
        settings.validateVoiceModelCombination()
        XCTAssertEqual(settings.ttsModel, "openrouter/speech/retired-selection")
        XCTAssertEqual(settings.ttsProvider, .openrouter)
    }

    func testSpeechSelectionWithoutVoiceKeepsProviderDefault() {
        let selection = OpenRouterSpeechSelection(modelID: "example/default-voice")
        XCTAssertNil(OpenRouterSpeechSelection(id: selection.id)?.voice)
    }

    func testOnlyDisruptiveAudioSessionEventsInterruptPlayback() {
        let cases: [(Notification.Name, String, UInt, Bool)] = [
            (AVAudioSession.interruptionNotification, AVAudioSessionInterruptionTypeKey,
             AVAudioSession.InterruptionType.began.rawValue, true),
            (AVAudioSession.interruptionNotification, AVAudioSessionInterruptionTypeKey,
             AVAudioSession.InterruptionType.ended.rawValue, false),
            (AVAudioSession.routeChangeNotification, AVAudioSessionRouteChangeReasonKey,
             AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue, true),
            (AVAudioSession.routeChangeNotification, AVAudioSessionRouteChangeReasonKey,
             AVAudioSession.RouteChangeReason.categoryChange.rawValue, false)
        ]
        for (name, key, value, expected) in cases {
            XCTAssertEqual(
                OpenRouterIOSAudioPlayback.interruptsPlayback(Notification(name: name, userInfo: [key: value])),
                expected
            )
        }
        XCTAssertTrue(OpenRouterIOSAudioPlayback.interruptsPlayback(
            Notification(name: AVAudioSession.mediaServicesWereLostNotification)
        ))
    }

    func testPlaybackRateRejectsNonfiniteValuesAndClampsFiniteValues() {
        XCTAssertEqual(OpenRouterIOSAudioPlayback.playbackRate(for: .nan), 1)
        XCTAssertEqual(OpenRouterIOSAudioPlayback.playbackRate(for: .infinity), 1)
        XCTAssertEqual(OpenRouterIOSAudioPlayback.playbackRate(for: -.infinity), 1)
        let range = VoiceOutputProvider.openrouter.speedRange
        XCTAssertEqual(OpenRouterIOSAudioPlayback.playbackRate(for: -10), Float(range.lowerBound))
        XCTAssertEqual(OpenRouterIOSAudioPlayback.playbackRate(for: 10), Float(range.upperBound))
    }

    func testMissingKeyAndInvalidSelectionReportActionableErrors() async throws {
        let client = OpenRouterIOSVoiceOutputClient()
        do {
            try await client.speak(text: "Hello", apiKey: " ", selectionID: "", speed: 1)
            XCTFail("A missing key must fail before synthesis")
        } catch OpenRouterIOSVoiceOutputError.missingAPIKey {
            XCTAssertFalse(client.isSpeaking)
        }
        do {
            try await client.speak(text: "Hello", apiKey: "test", selectionID: "aura-2", speed: 1)
            XCTFail("An incompatible selection must fail before synthesis")
        } catch OpenRouterIOSVoiceOutputError.invalidSelection {
            XCTAssertFalse(client.isSpeaking)
        }
    }
}
#endif
