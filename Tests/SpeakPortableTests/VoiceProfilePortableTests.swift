import Foundation
import SpeakCore
import XCTest

final class VoiceProfilePortableTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-profile-portable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testVoiceProfileValidation_RejectsInvalidNameLanguageAndClipCount() {
        let validClip = Self.makeClip()
        let consent = ConsentAttestation()

        assertValidationError(
            VoiceProfile(name: "   ", language: "en", clips: [validClip], consent: consent),
            .emptyName
        )
        let longName = String(repeating: "a", count: VoiceProfile.maximumNameLength + 1)
        assertValidationError(
            VoiceProfile(name: longName, language: "en", clips: [validClip], consent: consent),
            .nameTooLong
        )
        assertValidationError(
            VoiceProfile(name: "Voice", language: " ", clips: [validClip], consent: consent),
            .emptyLanguage
        )
        assertValidationError(
            VoiceProfile(name: "Voice", language: "en", clips: [], consent: consent),
            .clipCountOutOfRange(0)
        )
        let fourClips = [validClip, validClip, validClip, validClip]
        assertValidationError(
            VoiceProfile(name: "Voice", language: "en", clips: fourClips, consent: consent),
            .clipCountOutOfRange(4)
        )
    }

    func testVoiceProfileValidation_RejectsUnsafeClipsBadRatesConsentAndBindings() {
        let validClip = Self.makeClip()
        let consent = ConsentAttestation()

        let unsafeClip = VoiceProfileClip(
            filename: "../escape.wav", sampleRate: 24_000, durationSeconds: 10.0, transcript: "", source: .imported
        )
        assertValidationError(
            VoiceProfile(name: "Voice", language: "en", clips: [unsafeClip], consent: consent),
            .invalidClipFilename("../escape.wav")
        )
        let badRate = VoiceProfileClip(
            filename: "clip.wav", sampleRate: 44_100, durationSeconds: 10.0, transcript: "", source: .imported
        )
        assertValidationError(
            VoiceProfile(name: "Voice", language: "en", clips: [badRate], consent: consent),
            .unsupportedSampleRate(44_100)
        )
        let shortClip = VoiceProfileClip(
            filename: "clip.wav", sampleRate: 16_000, durationSeconds: 4.5, transcript: "", source: .recorded
        )
        assertValidationError(
            VoiceProfile(name: "Voice", language: "en", clips: [shortClip], consent: consent),
            .clipDurationOutOfRange(4.5)
        )
        assertValidationError(
            VoiceProfile(name: "Voice", language: "en", clips: [validClip], consent: ConsentAttestation(version: "v0")),
            .missingConsent
        )
        let badEmbedding = VoiceProfileEngineBinding(
            engineID: "local/tts/demo",
            engineDisplayName: "Demo",
            target: .localEmbedding(relativePath: "../outside.bin")
        )
        assertValidationError(
            VoiceProfile(
                name: "Voice",
                language: "en",
                clips: [validClip],
                consent: consent,
                engineBindings: ["local/tts/demo": badEmbedding]
            ),
            .invalidEngineBinding("local/tts/demo")
        )
    }

    func testVoiceProfileStore_ConsentFailClosedAndPrivateIsolation() throws {
        let storeRoot = VoiceProfileStore.defaultDirectory(in: temporaryRoot)
        let store = VoiceProfileStore(directory: storeRoot)
        let cleanBuffer = Self.makeSpeechBuffer(duration: 10.0, sampleRate: 24_000, withPauses: true)
        let clipInput = VoiceProfileStore.ClipInput(
            pcmBuffer: cleanBuffer,
            targetFormat: .pcm24k,
            transcript: "Good morning, this is a reference recording.",
            source: .recorded
        )

        assertConsentRequired(store: store, clipInput: clipInput, consent: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.metadataFileURL.path))
        assertConsentRequired(store: store, clipInput: clipInput, consent: ConsentAttestation(version: "legacy"))

        let created = try store.createProfile(
            name: "  Narrator  ", language: "en-GB", clips: [clipInput], consent: ConsentAttestation()
        )
        XCTAssertEqual(created.name, "Narrator")
        XCTAssertEqual(created.clips.count, 1)

        let clipURL = try store.clipURL(for: created.clips[0], in: created.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: clipURL.path))
        XCTAssertEqual(storeRoot.lastPathComponent, VoiceProfileStore.storageDirectoryName)
        try assertRestrictedPermissions(storeRoot: storeRoot, metaURL: store.metadataFileURL, clipURL: clipURL)
        XCTAssertEqual(try VoiceProfileStore(directory: storeRoot).listProfiles(), [created])

        try assertRenameTranscriptAndClipLimits(store: store, created: created, cleanBuffer: cleanBuffer)
    }

    func testVoiceProfileStore_DeleteRemovesClipsEmbeddingsAndReturnsRemoteBindings() throws {
        let store = VoiceProfileStore(directory: VoiceProfileStore.defaultDirectory(in: temporaryRoot))
        let created = try createTwoClipProfile(in: store)

        let localBinding = VoiceProfileEngineBinding(
            engineID: "local/tts/cosyvoice",
            engineDisplayName: "CosyVoice Local",
            target: .localEmbedding(relativePath: "embeddings/cosyvoice.bin")
        )
        let remoteXAI = VoiceProfileEngineBinding(
            engineID: "xai",
            engineDisplayName: "xAI Voice",
            target: .remoteVoice(voiceID: "xai/clone-123", providerDisplayName: "xAI")
        )
        let remoteEleven = VoiceProfileEngineBinding(
            engineID: "elevenlabs",
            engineDisplayName: "ElevenLabs",
            target: .remoteVoice(voiceID: "voice-abc", providerDisplayName: "ElevenLabs")
        )
        _ = try store.upsertEngineBinding(localBinding, for: created.id)
        _ = try store.upsertEngineBinding(remoteXAI, for: created.id)
        let updated = try store.upsertEngineBinding(remoteEleven, for: created.id)

        let embeddingURL = try XCTUnwrap(store.embeddingURL(for: localBinding, in: created.id))
        try FileManager.default.createDirectory(
            at: embeddingURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("embedding".utf8).write(to: embeddingURL)
        let clipURL = try store.clipURL(for: updated.clips[0], in: created.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: clipURL.path))

        let result = try store.deleteProfile(id: created.id)
        XCTAssertEqual(result.deletedProfileID, created.id)
        XCTAssertEqual(result.deletedProfileName, "Clone Target")
        XCTAssertEqual(result.remoteBindings.map(\.engineID), ["elevenlabs", "xai"])
        XCTAssertEqual(result.remoteBindings.map(\.remoteVoiceID), ["voice-abc", "xai/clone-123"])
        XCTAssertTrue(try store.listProfiles().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clipURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: embeddingURL.path))
        let folder = store.rootDirectory.appendingPathComponent(created.id.uuidString.lowercased())
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    static func makeSpeechBuffer(
        duration: Double,
        sampleRate: Int,
        fundamentalHz: Double = 140.0,
        amplitude: Float = 0.35,
        withPauses: Bool = true
    ) -> VoiceProfilePCMBuffer {
        let count = Int((duration * Double(sampleRate)).rounded())
        var samples = [Float](repeating: 0, count: count)
        var phase = 0.0
        for index in 0..<count {
            let seconds = Double(index) / Double(sampleRate)
            let cycle = seconds.truncatingRemainder(dividingBy: 1.5)
            let envelope = withPauses ? (cycle < 1.2 ? 1.0 : 0.002) : 1.0
            let pitch = fundamentalHz + 12.0 * sin(2.0 * .pi * 1.5 * seconds)
            phase += 2.0 * .pi * pitch / Double(sampleRate)
            let wave = 0.55 * sin(phase)
                + 0.30 * sin(phase * 2.0)
                + 0.15 * sin(phase * 3.0)
            samples[index] = Float(envelope * Double(amplitude) * wave)
        }
        return VoiceProfilePCMBuffer(samples: samples, sampleRate: sampleRate)
    }
}

private extension VoiceProfilePortableTests {
    static func makeClip() -> VoiceProfileClip {
        let clipID = UUID()
        return VoiceProfileClip(
            id: clipID,
            filename: "clip-\(clipID.uuidString.lowercased()).wav",
            sampleRate: 24_000,
            durationSeconds: 10.0,
            transcript: "Clean reference sample.",
            source: .recorded
        )
    }

    func assertValidationError(_ profile: VoiceProfile, _ expected: VoiceProfileValidationError) {
        XCTAssertThrowsError(try profile.validate()) {
            XCTAssertEqual($0 as? VoiceProfileValidationError, expected)
        }
    }

    func assertConsentRequired(
        store: VoiceProfileStore, clipInput: VoiceProfileStore.ClipInput, consent: ConsentAttestation?
    ) {
        XCTAssertThrowsError(
            try store.createProfile(name: "Narrator", language: "en", clips: [clipInput], consent: consent)
        ) { XCTAssertEqual($0 as? VoiceProfileStoreError, .consentRequired) }
    }

    func assertRestrictedPermissions(storeRoot: URL, metaURL: URL, clipURL: URL) throws {
        #if !os(Windows)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: storeRoot.path)
        let metaAttrs = try FileManager.default.attributesOfItem(atPath: metaURL.path)
        let wavAttrs = try FileManager.default.attributesOfItem(atPath: clipURL.path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((metaAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((wavAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        #endif
    }

    func assertRenameTranscriptAndClipLimits(
        store: VoiceProfileStore,
        created: VoiceProfile,
        cleanBuffer: VoiceProfilePCMBuffer
    ) throws {
        let renamed = try store.renameProfile(id: created.id, name: "Studio Voice", language: "en-US")
        XCTAssertEqual(renamed.name, "Studio Voice")
        XCTAssertEqual(renamed.language, "en-US")

        let edited = try store.updateClipTranscript(
            profileID: created.id, clipID: created.clips[0].id, transcript: "Updated reference transcript."
        )
        XCTAssertEqual(edited.clips[0].transcript, "Updated reference transcript.")

        let clip2 = VoiceProfileStore.ClipInput(
            pcmBuffer: Self.makeSpeechBuffer(duration: 8.0, sampleRate: 16_000, withPauses: true),
            targetFormat: .pcm16k, transcript: "Clip two", source: .history
        )
        let clip3 = VoiceProfileStore.ClipInput(
            pcmBuffer: Self.makeSpeechBuffer(duration: 9.0, sampleRate: 24_000, withPauses: true),
            targetFormat: .pcm24k, transcript: "Clip three", source: .imported
        )
        let clip4 = VoiceProfileStore.ClipInput(
            pcmBuffer: cleanBuffer, targetFormat: .pcm24k, transcript: "Clip four", source: .recorded
        )
        _ = try store.addClip(clip2, to: created.id)
        let withThree = try store.addClip(clip3, to: created.id)
        XCTAssertEqual(withThree.clips.count, 3)

        XCTAssertThrowsError(try store.addClip(clip4, to: created.id)) {
            XCTAssertEqual($0 as? VoiceProfileStoreError, .clipLimitReached(3))
        }
        _ = try store.removeClip(clipID: withThree.clips[2].id, from: created.id)
        let withOne = try store.removeClip(clipID: withThree.clips[1].id, from: created.id)
        XCTAssertEqual(withOne.clips.count, 1)
        XCTAssertThrowsError(try store.removeClip(clipID: withOne.clips[0].id, from: created.id)) {
            XCTAssertEqual($0 as? VoiceProfileStoreError, .cannotRemoveLastClip)
        }
    }

    func createTwoClipProfile(in store: VoiceProfileStore) throws -> VoiceProfile {
        let clipA = VoiceProfileStore.ClipInput(
            pcmBuffer: Self.makeSpeechBuffer(duration: 8.0, sampleRate: 24_000, withPauses: true),
            transcript: "Clip A", source: .recorded
        )
        let clipB = VoiceProfileStore.ClipInput(
            pcmBuffer: Self.makeSpeechBuffer(duration: 9.0, sampleRate: 24_000, withPauses: true),
            transcript: "Clip B", source: .imported
        )
        return try store.createProfile(
            name: "Clone Target", language: "en", clips: [clipA, clipB], consent: ConsentAttestation()
        )
    }
}
