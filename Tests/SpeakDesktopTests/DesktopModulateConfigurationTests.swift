import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
@testable import SpeakDesktop
import XCTest

final class DesktopModulateConfigurationTests: XCTestCase {
    private let keys: [ApplicationPreferenceKey] = [
        .modulateSpeakerDiarization, .modulateEmotionSignal, .modulateAccentSignal, .modulatePIIPhiTagging
    ]

    func testAbsentPreferences_PreserveLegacyAllOffLiveOptions() throws {
        let configuration = try DesktopConfiguration()
        XCTAssertEqual(configuration.liveOptions.modulate, .none)
        let applied = try configuration.applying(configuration.entries)
        XCTAssertEqual(applied.liveOptions.modulate, .none)
        XCTAssertEqual(applied.modulateBatchFeatures, .init())
        for key in keys {
            let field = try XCTUnwrap(DesktopConfiguration.fields.first { $0.key == key.rawValue })
            XCTAssertEqual(field.group, "Transcription")
            XCTAssertTrue(field.title.contains("Modulate"))
            XCTAssertEqual(field.defaultValue, AnyCodable(.string("")))
            XCTAssertNil(applied.values[key.rawValue])
            guard case .choice(let choices) = field.kind else { return XCTFail("A legacy/default choice is required.") }
            XCTAssertEqual(choices.map(\.value), ["", "1", "0"])
        }
    }

    func testEveryFeatureCombination_ApplyAndCodableRestartPreserveExactOptions() throws {
        for mask in 0..<16 {
            let configuration = try configuration(mask: mask)
            let applied = try configuration.applying(configuration.entries)
            let restored = try JSONDecoder().decode(
                DesktopConfiguration.self, from: JSONEncoder().encode(applied)
            )
            let options = restored.liveOptions.modulate
            XCTAssertEqual(options.speakerDiarization, mask & 1 != 0)
            XCTAssertEqual(options.emotionSignal, mask & 2 != 0)
            XCTAssertEqual(options.accentSignal, mask & 4 != 0)
            XCTAssertEqual(options.piiPhiTagging, mask & 8 != 0)
            let fields = Dictionary(uniqueKeysWithValues: restored.modulateBatchFeatures.multipartFields)
            for (index, name) in [
                "speaker_diarization", "emotion_signal", "accent_signal", "pii_phi_tagging"
            ].enumerated() {
                XCTAssertEqual(fields[name], String(mask & (1 << index) != 0))
            }
            XCTAssertEqual(restored.values["futureModulate"], AnyCodable(.string("preserved")))
        }
        XCTAssertEqual(DesktopConfiguration.modulatePreferenceKeys, Set(keys.map(\.rawValue)))
    }

    func testNativeResetToDefaults_RemovesOverridesRatherThanExportingAnEmptyString() throws {
        let configuration = try configuration(mask: 15)
        var entries = configuration.entries
        for key in keys {
            let index = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == key.rawValue })
            entries[index] = ""
        }
        let reset = try configuration.applying(entries)
        for key in keys { XCTAssertNil(reset.values[key.rawValue]) }
        XCTAssertEqual(reset.liveOptions.modulate, .none)
        XCTAssertEqual(reset.modulateBatchFeatures, .init())
        XCTAssertEqual(reset.values["futureModulate"], AnyCodable(.string("preserved")))
        let restored = try JSONDecoder().decode(DesktopConfiguration.self, from: JSONEncoder().encode(reset))
        XCTAssertEqual(restored, reset)
    }

    func testBatchFeatureSnapshot_SurvivesOtherCaptureHelpersWithoutChangingOldInitializer() throws {
        let initial = try configuration(mask: 6)
        let later = try configuration(mask: 9)
        // swiftlint:disable:next line_length
        let captured = DesktopProfileSession.defaults(modelIdentifier: "modulate/velma-2-stt-batch", postProcessing: .init())
            .capturingModulateFeatures(initial.modulateBatchFeatures)
            .capturingTranscriptionOptions(later.liveOptions)
        XCTAssertEqual(captured.modulateBatchFeatures, initial.modulateBatchFeatures)
        XCTAssertEqual(captured.transcriptionOptions, later.liveOptions)
        XCTAssertEqual(
            DesktopProfileSession.defaults(modelIdentifier: "modulate/velma-2-stt-batch", postProcessing: .init())
                .modulateBatchFeatures, .init()
        )
    }

    func testFeaturePreferences_RejectNumbersStringsNullAndMalformedEditorBooleans() throws {
        for key in keys {
            for invalid in [
                AnyCodable(.int(1)), AnyCodable(.string("true")), AnyCodable(.string("1")),
                AnyCodable(.string("0")), AnyCodable(.string("")), AnyCodable(.null)
            ] {
                XCTAssertThrowsError(try DesktopConfiguration(values: [key.rawValue: invalid]))
            }
            let configuration = try DesktopConfiguration()
            var entries = configuration.entries
            let index = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == key.rawValue })
            entries[index] = "true"
            XCTAssertThrowsError(try configuration.applying(entries))
        }
    }

    func testConfiguredFeatures_ReachTheExistingModulateWireWithoutProviderSubstitution() throws {
        for mask in 0..<16 {
            let configuration = try configuration(mask: mask)
            let factory = AssemblyAISocketFactory()
            let client = try XCTUnwrap(DesktopLiveTranscription.makeClient(
                model: "modulate/velma-2-stt-streaming", apiKey: "synthetic", language: nil, azureEndpoint: "",
                options: configuration.liveOptions, makeConnection: { factory.make($0) }
            ))
            client.start(onTranscript: { _, _ in }, onError: { XCTFail("\($0)") })
            defer { client.cancel() }
            let request = try XCTUnwrap(factory.requests.first)
            let url = try XCTUnwrap(request.url)
            let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(url.host, ModulateTranscriptionService.streamingURL.host)
            for (index, name) in [
                "speaker_diarization", "emotion_signal", "accent_signal", "pii_phi_tagging"
            ].enumerated() {
                XCTAssertEqual(values[name], String(mask & (1 << index) != 0))
            }
        }
    }

    private func configuration(mask: Int) throws -> DesktopConfiguration {
        var values = Dictionary(uniqueKeysWithValues: keys.enumerated().map {
            ($0.element.rawValue, AnyCodable(.bool(mask & (1 << $0.offset) != 0)))
        })
        values["futureModulate"] = AnyCodable(.string("preserved"))
        return try DesktopConfiguration(values: values)
    }
}
