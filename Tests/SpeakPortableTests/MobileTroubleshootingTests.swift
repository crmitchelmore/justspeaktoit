import SpeakCore
import XCTest

final class MobileTroubleshootingTests: XCTestCase {
    private typealias Rules = MobileTroubleshooting

    private let healthyCloud = Rules.Input(
        microphone: .granted,
        transcription: Rules.Provider(name: "Deepgram", key: .present, canVerify: true)
    )

    func testHealthyCloudSetup_reportsOnlyPassingChecks() {
        let findings = Rules.findings(healthyCloud)

        XCTAssertEqual(findings.map(\.check), [.microphone, .transcriptionKey])
        XCTAssertEqual(Rules.overall(findings), .ok)
        XCTAssertEqual(findings.last?.fixes, [.verifyKey], "A saved key that can be checked offers the check")
    }

    func testDeniedMicrophone_isAnIssueSortedFirstWithASettingsFix() {
        let input = Rules.Input(
            microphone: .denied,
            transcription: Rules.Provider(name: "Deepgram", key: .missing),
            keyboard: .ready
        )
        let findings = Rules.findings(input)

        XCTAssertEqual(findings.first?.check, .microphone)
        XCTAssertEqual(findings.first?.fixes, [.openSystemSettings])
        XCTAssertEqual(findings.map(\.severity), [.issue, .issue, .ok])
        XCTAssertEqual(Rules.overall(findings), .issue)
    }

    func testUndeterminedPermissions_offerTheInAppPrompt() {
        let input = Rules.Input(
            microphone: .notDetermined, speechRecognition: .notDetermined, recogniser: .ready,
            transcription: Rules.Provider(name: nil, key: .notRequired)
        )
        let fixes = Rules.findings(input).filter { $0.severity == .warning }.flatMap(\.fixes)

        XCTAssertEqual(fixes, [.requestMicrophone, .requestSpeechRecognition])
    }

    func testOnDeviceModel_hidesTheKeyCheckAndReportsTheRecogniser() {
        for (recogniser, severity) in [
            (Rules.Recogniser.ready, Rules.Severity.ok), (.needsDownload, .warning),
            (.unsupportedLanguage, .issue), (.unavailable, .warning), (.unknown, .info)
        ] {
            let input = Rules.Input(
                microphone: .granted, speechRecognition: .granted, recogniser: recogniser,
                transcription: Rules.Provider(name: nil, key: .notRequired)
            )
            let findings = Rules.findings(input)

            XCTAssertNil(findings.first { $0.check == .transcriptionKey })
            XCTAssertEqual(findings.first { $0.check == .recogniser }?.severity, severity, "\(recogniser)")
        }
    }

    func testRejectedAndUnreadableKeys_areNotReportedAsMissing() {
        let rejected = Rules.findings(Rules.Input(
            microphone: .granted, transcription: Rules.Provider(name: "ElevenLabs", key: .rejected)
        )).first { $0.check == .transcriptionKey }
        let unreadable = Rules.findings(Rules.Input(
            microphone: .granted, transcription: Rules.Provider(name: "ElevenLabs", key: .unreadable)
        )).first { $0.check == .transcriptionKey }

        XCTAssertEqual(rejected?.severity, .issue)
        XCTAssertEqual(rejected?.title, "ElevenLabs Rejected the Transcription Key")
        XCTAssertEqual(unreadable?.severity, .warning)
        XCTAssertEqual(unreadable?.fixes, [.openAPIKeys])
    }

    func testCleanupKey_isOnlyCheckedWhileCleanupIsOn() {
        let missingKey = Rules.Provider(name: "OpenRouter", key: .missing)
        let cleanupOff = Rules.Input(
            microphone: .granted, transcription: healthyCloud.transcription,
            postProcessingEnabled: false, postProcessing: missingKey
        )
        let cleanupOn = Rules.Input(
            microphone: .granted, transcription: healthyCloud.transcription,
            postProcessingEnabled: true, postProcessing: missingKey
        )

        XCTAssertNil(Rules.findings(cleanupOff).first { $0.check == .postProcessingKey })
        XCTAssertEqual(
            Rules.findings(cleanupOn).first { $0.check == .postProcessingKey }?.fixes,
            [.openAPIKeys, .disablePostProcessing]
        )
    }

    func testKeyboard_isOmittedWhenNotOfferedAndFlagsMissingFullAccess() {
        XCTAssertNil(Rules.findings(healthyCloud).first { $0.check == .keyboard })

        let input = Rules.Input(
            microphone: .granted, transcription: healthyCloud.transcription, keyboard: .needsFullAccess
        )
        let keyboard = Rules.findings(input).first { $0.check == .keyboard }

        XCTAssertEqual(keyboard?.severity, .warning)
        XCTAssertEqual(keyboard?.fixes.first, .openKeyboardSetup)
    }

    func testAndroidWording_keepsVerdictsButDropsIOSOnlyAdvice() {
        let input = Rules.Input(
            microphone: .denied, recogniser: .unavailable,
            transcription: Rules.Provider(name: nil, key: .notRequired), keyboard: .ready
        )
        let iOS = Rules.findings(input)
        let android = Rules.findings(input, platform: .android)

        XCTAssertEqual(iOS, Rules.findings(input, platform: .iOS))
        XCTAssertEqual(android.map(\.check), iOS.map(\.check))
        XCTAssertEqual(android.first { $0.check == .microphone }?.fixes, [.openSystemSettings])
        XCTAssertEqual(
            android.first { $0.check == .recogniser }?.severity, .issue,
            "Android has no server fallback when the recogniser is missing"
        )
        let keyboard = android.first { $0.check == .keyboard }
        XCTAssertFalse(keyboard?.detail.contains("Full Access") ?? true)
    }
}
