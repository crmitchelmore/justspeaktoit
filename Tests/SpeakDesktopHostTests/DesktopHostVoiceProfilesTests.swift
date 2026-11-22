import Foundation
import SpeakCore
import SpeakDesktop
import XCTest

@testable import SpeakDesktopHost

final class DesktopHostVoiceProfilesTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUpWithError() throws {
        FakeLog.shared.reset()
        FakeSpeech.shared.reset()
        DesktopHostModels.configure(streamingQualified: false)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-profiles-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        controller = try DesktopHostController<FakePlatform>.consented(
            directory: directory,
            effects: SyntheticEffects()
        )
    }

    override func tearDown() async throws {
        if let controller {
            await controller.close()
        }
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        controller = nil
    }

    func testVoiceProfiles_IsolatedFromHistorySettingsAndMigrationBackup() async throws {
        await controller.markReadyForSelfTest()
        let clip = VoiceProfileStore.ClipInput(
            pcmBuffer: Self.makeSpeechBuffer(duration: 8.0, sampleRate: 24_000, withPauses: true),
            transcript: "Private isolated transcript phrase.",
            source: .recorded
        )
        let profile = try await controller.createVoiceProfile(
            name: "Private Desktop Voice",
            language: "en-US",
            clips: [clip],
            consent: ConsentAttestation()
        )

        let storeRoot = await controller.voiceProfiles.rootDirectory
        XCTAssertEqual(storeRoot.lastPathComponent, VoiceProfileStore.storageDirectoryName)
        let loaded = await controller.listVoiceProfiles()
        XCTAssertEqual(loaded, [profile])

        // History store must not contain the voice profile.
        let historyRecords = try await controller.store.records()
        XCTAssertTrue(historyRecords.isEmpty)

        // Host settings.json must not store private voice profile metadata or consent.
        let settingsURL = directory.appendingPathComponent("settings.json")
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let settingsText = try String(contentsOf: settingsURL, encoding: .utf8)
            XCTAssertFalse(settingsText.contains("Private Desktop Voice"))
            XCTAssertFalse(settingsText.contains(profile.id.uuidString))
        }

        // Migration export snapshot must exclude every voice profile record and WAV clip.
        let captured = SnapshotCapture()
        let destination = directory.appendingPathComponent("backup.zip")
        let stagingDir = directory.appendingPathComponent("migration-staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let adapter = DesktopMigrationBackup.Adapter(
            digests: EmptyDigestProvider(),
            archive: { snapshot in
                captured.store(snapshot)
                let fakeZip = stagingDir.appendingPathComponent("export.zip")
                try Data("zip".utf8).write(to: fakeZip)
                return fakeZip
            },
            publish: { src, dst in try FileManager.default.copyItem(at: src, to: dst) }
        )
        let outcome = await DesktopMigrationBackup.export(
            store: controller.store,
            destination: destination,
            contents: .init(includeAudio: true, profiles: nil, configuration: nil),
            adapter: adapter
        )
        XCTAssertEqual(outcome, .saved)
        let snapshot = try XCTUnwrap(captured.snapshot)
        let serializedSnapshot = try String(data: JSONEncoder().encode(snapshot), encoding: .utf8) ?? ""
        XCTAssertFalse(serializedSnapshot.contains(profile.id.uuidString))
        XCTAssertFalse(serializedSnapshot.contains("Private Desktop Voice"))
        XCTAssertFalse(serializedSnapshot.contains(profile.clips[0].filename))
    }

    func testPrepareFromHistory_TrimsLongRecordingAndSuggestsTranscript() async throws {
        await controller.markReadyForSelfTest()
        let rate = 16_000
        let silenceLead = [Float](repeating: 0, count: rate * 10)
        let cleanSpeech = Self.makeSpeechBuffer(duration: 15.0, sampleRate: rate, fundamentalHz: 145, withPauses: true)
        let silenceTail = [Float](repeating: 0, count: rate * 11)
        let longBuffer = VoiceProfilePCMBuffer(
            samples: silenceLead + cleanSpeech.samples + silenceTail,
            sampleRate: rate
        )
        let wavData = try VoiceProfileWAVCodec.encodeWAV(longBuffer, format: .pcm16k)

        let recordID = UUID()
        let audioFilename = "\(recordID.uuidString).wav"
        try wavData.write(to: controller.store.directory.appendingPathComponent(audioFilename), options: .atomic)
        var record = DesktopRecordingStore.Record(
            id: recordID,
            audioFilename: audioFilename,
            modelIdentifier: ModelCatalog.defaultBatchTranscriptionModel
        )
        record.processedText = "  Clean sample from history  "
        try await controller.store.save(record)

        let prepared = try await controller.prepareVoiceProfileClipFromHistory(
            recordID: recordID,
            targetFormat: .pcm16k
        )
        XCTAssertEqual(prepared.source, .history)
        XCTAssertGreaterThanOrEqual(prepared.pcmBuffer.durationSeconds, 10.0)
        XCTAssertLessThanOrEqual(prepared.pcmBuffer.durationSeconds, 20.0)
        XCTAssertTrue(prepared.qualityReport.passed, "\(prepared.qualityReport.rejectionReasons)")
        XCTAssertEqual(prepared.suggestedTranscript, "Clean sample from history")
        XCTAssertNotNil(prepared.trimResult)
    }

    func testPrepareFromFile_SupportsWAVAndPlatformConverterAndTranscribes() async throws {
        await controller.markReadyForSelfTest()
        let cleanBuffer = Self.makeSpeechBuffer(duration: 9.0, sampleRate: 16_000, withPauses: true)
        let wavURL = directory.appendingPathComponent("sample.wav")
        try VoiceProfileWAVCodec.encodeWAV(cleanBuffer, format: .pcm16k).write(to: wavURL)

        let preparedWAV = try await controller.prepareVoiceProfileClipFromFile(at: wavURL, targetFormat: .pcm16k)
        XCTAssertTrue(preparedWAV.qualityReport.passed)
        XCTAssertEqual(preparedWAV.source, .imported)

        FakeLog.shared.setAudioConverter { _, outputURL in
            let converted = try VoiceProfileWAVCodec.encodeWAV(cleanBuffer, format: .pcm16k)
            try converted.write(to: outputURL)
            return cleanBuffer.durationSeconds
        }
        let m4aURL = directory.appendingPathComponent("sample.m4a")
        try Data("synthetic-m4a".utf8).write(to: m4aURL)
        let preparedM4A = try await controller.prepareVoiceProfileClipFromFile(at: m4aURL, targetFormat: .pcm24k)
        XCTAssertTrue(preparedM4A.qualityReport.passed)
        XCTAssertEqual(preparedM4A.pcmBuffer.sampleRate, 24_000)

        let credentialName = await controller.credentialIdentifier(for: ModelCatalog.defaultBatchTranscriptionModel)
        FakeLog.shared.setKey("synthetic-key", name: credentialName)
        let transcript = try await controller.transcribeVoiceProfileClip(preparedM4A.pcmBuffer)
        XCTAssertEqual(transcript, "Synthetic transcript")
    }

    func testMyVoicesPickerAndReadAloudFailClosedWithoutFallback() async throws {
        await controller.markReadyForSelfTest()
        let clip = VoiceProfileStore.ClipInput(
            pcmBuffer: Self.makeSpeechBuffer(duration: 8.0, sampleRate: 24_000, withPauses: true),
            transcript: "Original script",
            source: .recorded
        )

        do {
            _ = try await controller.createVoiceProfile(
                name: "Unconsented",
                language: "en",
                clips: [clip],
                consent: nil
            )
            XCTFail("Expected missing consent to fail")
        } catch let error as VoiceProfileStoreError {
            XCTAssertEqual(error, .consentRequired)
        }

        let created = try await controller.createVoiceProfile(
            name: "Custom Presenter",
            language: "en-GB",
            clips: [clip],
            consent: ConsentAttestation()
        )
        let edited = try await controller.updateVoiceProfileClipTranscript(
            profileID: created.id,
            clipID: created.clips[0].id,
            transcript: "Edited script"
        )
        XCTAssertEqual(edited.clips[0].transcript, "Edited script")

        // Unbound profile exposes zero playable entries in My voices.
        let initialPicker = await controller.voiceOutputSettings().favoritePicker(
            accountInventory: nil,
            voiceProfiles: await controller.listVoiceProfiles()
        )
        XCTAssertFalse(initialPicker.labels.contains { $0.hasPrefix(VoiceProfilePickerCatalog.groupTitle) })

        let localBinding = VoiceProfileEngineBinding(
            engineID: "local/tts/demo",
            engineDisplayName: "Local Demo Engine",
            target: .localEmbedding(relativePath: "embeddings/demo.bin")
        )
        let remoteBinding = VoiceProfileEngineBinding(
            engineID: "elevenlabs",
            engineDisplayName: "ElevenLabs",
            target: .remoteVoice(voiceID: "el-voice-77", providerDisplayName: "ElevenLabs")
        )
        _ = try await controller.upsertVoiceProfileBinding(localBinding, for: created.id)
        _ = try await controller.upsertVoiceProfileBinding(remoteBinding, for: created.id)

        let entries = await controller.myVoicePickerEntries()
        XCTAssertEqual(entries.count, 2)
        let boundPicker = await controller.voiceOutputSettings().favoritePicker(
            accountInventory: nil,
            voiceProfiles: await controller.listVoiceProfiles()
        )
        XCTAssertTrue(boundPicker.labels[0].hasPrefix("My voices · Custom Presenter"))
        XCTAssertEqual(Set(boundPicker.identifiers).count, boundPicker.identifiers.count)
        XCTAssertTrue(boundPicker.identifiers.allSatisfy { $0.utf8.count <= 260 })

        let localEntry = try XCTUnwrap(entries.first { $0.engineID == "local/tts/demo" })
        await controller.handleVoicePicker(voiceID: localEntry.desktopPickerIdentifier, action: 0)

        do {
            _ = try await controller.currentVoiceSelection()
            XCTFail("Expected unbound/unimplemented profile engine to refuse synthesis")
        } catch let error as DesktopHostError {
            XCTAssertTrue(error.localizedDescription.contains("Custom Presenter"))
        }
        XCTAssertTrue(FakeSpeech.shared.spoken.isEmpty)

        let deletion = try await controller.deleteVoiceProfile(id: created.id)
        XCTAssertEqual(deletion.remoteBindings.map(\.remoteVoiceID), ["el-voice-77"])
        let remaining = await controller.listVoiceProfiles()
        XCTAssertTrue(remaining.isEmpty)
    }

    private static func makeSpeechBuffer(
        duration: Double,
        sampleRate: Int,
        fundamentalHz: Double = 140.0,
        withPauses: Bool
    ) -> VoiceProfilePCMBuffer {
        let count = Int((duration * Double(sampleRate)).rounded())
        var samples = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let seconds = Double(index) / Double(sampleRate)
            let envelope = !withPauses || seconds.truncatingRemainder(dividingBy: 1.5) < 1.2 ? 1.0 : 0.002
            let wave = 0.55 * sin(2.0 * .pi * fundamentalHz * seconds)
                + 0.30 * sin(2.0 * .pi * (fundamentalHz * 2.0) * seconds)
                + 0.15 * sin(2.0 * .pi * (fundamentalHz * 3.0) * seconds)
            samples[index] = Float(envelope * 0.35 * wave)
        }
        return VoiceProfilePCMBuffer(samples: samples, sampleRate: sampleRate)
    }
}

private struct EmptyDigestProvider: LocalModelDigestProvider {
    func sha256(for id: String) throws -> String? { nil }
}

private final class SnapshotCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: DataMigrationSnapshot?
    var snapshot: DataMigrationSnapshot? { lock.withLock { captured } }
    func store(_ value: DataMigrationSnapshot) { lock.withLock { captured = value } }
}
