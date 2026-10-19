import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

final class DesktopHostVoiceSelectionOwnershipTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<VoiceFormatPlatform>!

    override func setUp() async throws {
        FakeLog.shared.reset(); FakeSpeech.shared.reset(); VoiceFormatProbe.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-selection-owned-\(UUID())")
        controller = try DesktopHostController(directory: directory, effects: VoiceFormatEffects())
        await controller.markReadyForSelfTest()
    }

    override func tearDown() async throws {
        await controller.close()
        try FileManager.default.removeItem(at: directory)
    }

    private func importValues(_ values: [String: AnyCodable]) async throws {
        let path = directory.appendingPathComponent("owned-import.json")
        try JSONEncoder().encode(DesktopConfigurationDocument(
            preferences: DesktopConfiguration(values: values))).write(to: path)
        try await controller.importConfiguration(path: path.path)
    }

    func testImportABA_FencesCapturedCodecAdmissionEvenWhenTheWholeVoiceValueIsRestored() async throws {
        try await importValues(["defaultTTSVoice": AnyCodable(.string("openai/alloy"))])
        let initial = await controller.voiceOutputSettings()
        try await importValues(initial.configurationProjection(over: [:]))
        let original = await controller.voiceOutputSettings()
        let revision = await controller.voiceSettingsRevision
        let epoch = await controller.voiceCredentialEpoch
        let gate = VoiceFormatGate()
        VoiceFormatProbe.shared.holdAvailability(gate)
        let host = try XCTUnwrap(controller)
        let pending = Task { await host.saveVoiceAudioFormat("m4a") }
        await gate.waitUntilEntered()
        try await importValues(["defaultTTSVoice": AnyCodable(.string("future/voice"))])
        try await importValues(original.configurationProjection(over: [:]))
        let restored = await controller.voiceOutputSettings()
        let changedRevision = await controller.voiceSettingsRevision
        let changedEpoch = await controller.voiceCredentialEpoch
        XCTAssertEqual(restored, original)
        XCTAssertGreaterThan(changedRevision, revision)
        XCTAssertNotEqual(changedEpoch, epoch)
        let heldTask = await controller.readAloudState.formatSaveTask
        let active = await controller.activeOperations
        XCTAssertNotNil(heldTask); XCTAssertGreaterThan(active, 0)
        await gate.release()
        let failure = await pending.value
        XCTAssertNotNil(failure)
        let after = await controller.voiceOutputSettings()
        XCTAssertEqual(after, original)
        XCTAssertEqual(VoiceFormatProbe.shared.counts, [1, 0, 0, 0])
    }

    func testUnavailableImport_DoesNotRewriteCapturedGenerationOrRetainedPlaybackAndExport() async throws {
        try await importValues(["defaultTTSVoice": AnyCodable(.string("openai/alloy"))])
        let source = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Synthetic immutable source.")
        let gate = VoiceFormatGate()
        VoiceFormatProbe.shared.hold(gate)
        let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: 24_000))
        await controller.generateVoiceSource(source,
            options: .init(autoPlay: false, saveToRecordings: false, format: .mp3)) { captured, selection, credential in
                XCTAssertEqual(captured, source)
                XCTAssertEqual(selection.voice.id, "openai/alloy")
                _ = try await credential(); VoiceFormatProbe.shared.request(); return wav
            }
        await gate.waitUntilEntered()
        try await importValues(["defaultTTSVoice": AnyCodable(.string("future/unavailable"))])
        await gate.release()
        let generation = await controller.voiceGenerationTask
        await generation?.value
        let captured = await controller.generatedVoice
        let result = try XCTUnwrap(captured)
        XCTAssertEqual(result.source, source); XCTAssertEqual(result.voice.id, "openai/alloy")
        XCTAssertEqual(result.audio.format, .mp3)
        let counts = VoiceFormatProbe.shared.counts
        await controller.playGeneratedVoice(result.id.uuidString)
        let playback = await controller.voiceGenerationTask
        await playback?.value
        let destination = directory.deletingLastPathComponent().appendingPathComponent("retained-\(UUID()).mp3")
        defer { try? FileManager.default.removeItem(at: destination) }
        await controller.exportGeneratedVoice(result.id.uuidString, path: destination.path)
        let export = await controller.readAloudState.exportTask
        await export?.value
        XCTAssertEqual(try Data(contentsOf: destination), result.audio.data)
        XCTAssertEqual(VoiceFormatProbe.shared.counts, counts)
        let saved = await controller.voiceOutputSettings()
        XCTAssertEqual(saved.voiceID, "future/unavailable")
        XCTAssertThrowsError(try saved.synthesisSelection())
        await controller.close()
        let retained = await controller.generatedVoice
        XCTAssertEqual(retained?.id, result.id)
        await controller.playGeneratedVoice(result.id.uuidString)
        XCTAssertEqual(VoiceFormatProbe.shared.counts, counts)
    }
}
