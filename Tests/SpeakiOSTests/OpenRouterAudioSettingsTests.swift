#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore
import XCTest

@testable import SpeakiOSLib

@MainActor
final class OpenRouterAudioSettingsTests: XCTestCase {
    func testDynamicTranscriptionSelection_UsesNormalBatchPreferences() {
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

    func testDynamicSpeechSelection_PersistsAndIsNeverReplacedByValidation() {
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

    func testSpeechSelectionWithoutVoice_KeepsProviderDefault() {
        let selection = OpenRouterSpeechSelection(modelID: "example/default-voice")
        XCTAssertNil(OpenRouterSpeechSelection(id: selection.id)?.voice)
    }

    func testAudioSessionEvents_OnlyDisruptiveChangesInterruptPlayback() {
        let cases: [AudioSessionCase] = [
            .init(name: AVAudioSession.interruptionNotification, key: AVAudioSessionInterruptionTypeKey,
             value: AVAudioSession.InterruptionType.began.rawValue, expected: true),
            .init(name: AVAudioSession.interruptionNotification, key: AVAudioSessionInterruptionTypeKey,
             value: AVAudioSession.InterruptionType.ended.rawValue, expected: false),
            .init(name: AVAudioSession.routeChangeNotification, key: AVAudioSessionRouteChangeReasonKey,
             value: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue, expected: true),
            .init(name: AVAudioSession.routeChangeNotification, key: AVAudioSessionRouteChangeReasonKey,
             value: AVAudioSession.RouteChangeReason.categoryChange.rawValue, expected: false)
        ]
        for item in cases {
            XCTAssertEqual(
                OpenRouterIOSAudioPlayback.interruptsPlayback(
                    Notification(name: item.name, userInfo: [item.key: item.value])
                ),
                item.expected
            )
        }
        XCTAssertTrue(OpenRouterIOSAudioPlayback.interruptsPlayback(
            Notification(name: AVAudioSession.mediaServicesWereLostNotification)
        ))
    }

    func testPlaybackRate_RejectsNonfiniteValuesAndClampsFiniteValues() {
        XCTAssertEqual(OpenRouterIOSAudioPlayback.playbackRate(for: .nan), 1)
        XCTAssertEqual(OpenRouterIOSAudioPlayback.playbackRate(for: .infinity), 1)
        XCTAssertEqual(OpenRouterIOSAudioPlayback.playbackRate(for: -.infinity), 1)
        let range = VoiceOutputProvider.openrouter.speedRange
        XCTAssertEqual(OpenRouterIOSAudioPlayback.playbackRate(for: -10), Float(range.lowerBound))
        XCTAssertEqual(OpenRouterIOSAudioPlayback.playbackRate(for: 10), Float(range.upperBound))
    }

    func testMissingKeyAndInvalidSelection_ReportActionableErrors() async throws {
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
private struct AudioSessionCase {
    let name: Notification.Name
    let key: String
    let value: UInt
    let expected: Bool
}
#endif
