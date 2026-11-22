import Foundation
import SpeakCore
import SpeakDesktop
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

    func testVoiceProfileValidation_RejectsInvalidFields() throws {
        let clipID = UUID()
        let validClip = VoiceProfileClip(
            id: clipID,
            filename: "clip-\(clipID.uuidString.lowercased()).wav",
            sampleRate: 24_000,
            durationSeconds: 10.0,
            transcript: "Clean reference sample.",
            source: .recorded
        )
        let validConsent = ConsentAttestation()

        XCTAssertThrowsError(
            try VoiceProfile(name: "   ", language: "en", clips: [validClip], consent: validConsent).validate()
        ) { XCTAssertEqual($0 as? VoiceProfileValidationError, .emptyName) }

        let longName = String(repeating: "a", count: VoiceProfile.maximumNameLength + 1)
        XCTAssertThrowsError(
            try VoiceProfile(name: longName, language: "en", clips: [validClip], consent: validConsent).validate()
        ) { XCTAssertEqual($0 as? VoiceProfileValidationError, .nameTooLong) }

        XCTAssertThrowsError(
            try VoiceProfile(name: "Voice", language: " ", clips: [validClip], consent: validConsent).validate()
        ) { XCTAssertEqual($0 as? VoiceProfileValidationError, .emptyLanguage) }

        XCTAssertThrowsError(
            try VoiceProfile(name: "Voice", language: "en", clips: [], consent: validConsent).validate()
        ) { XCTAssertEqual($0 as? VoiceProfileValidationError, .clipCountOutOfRange(0)) }

        XCTAssertThrowsError(
            try VoiceProfile(
                name: "Voice",
                language: "en",
                clips: [validClip, validClip, validClip, validClip],
                consent: validConsent
            ).validate()
        ) { XCTAssertEqual($0 as? VoiceProfileValidationError, .clipCountOutOfRange(4)) }

        let unsafeClip = VoiceProfileClip(
            filename: "../escape.wav", sampleRate: 24_000, durationSeconds: 10.0, transcript: "", source: .imported
        )
        XCTAssertThrowsError(
            try VoiceProfile(name: "Voice", language: "en", clips: [unsafeClip], consent: validConsent).validate()
        ) { XCTAssertEqual($0 as? VoiceProfileValidationError, .invalidClipFilename("../escape.wav")) }

        let badRate = VoiceProfileClip(
            filename: "clip.wav", sampleRate: 44_100, durationSeconds: 10.0, transcript: "", source: .imported
        )
        XCTAssertThrowsError(
            try VoiceProfile(name: "Voice", language: "en", clips: [badRate], consent: validConsent).validate()
        ) { XCTAssertEqual($0 as? VoiceProfileValidationError, .unsupportedSampleRate(44_100)) }

        let shortClip = VoiceProfileClip(
            filename: "clip.wav", sampleRate: 16_000, durationSeconds: 4.5, transcript: "", source: .recorded
        )
        XCTAssertThrowsError(
            try VoiceProfile(name: "Voice", language: "en", clips: [shortClip], consent: validConsent).validate()
        ) { XCTAssertEqual($0 as? VoiceProfileValidationError, .clipDurationOutOfRange(4.5)) }

        let expiredConsent = ConsentAttestation(version: "v0")
        XCTAssertThrowsError(
            try VoiceProfile(name: "Voice", language: "en", clips: [validClip], consent: expiredConsent).validate()
        ) { XCTAssertEqual($0 as? VoiceProfileValidationError, .missingConsent) }

        let badEmbedding = VoiceProfileEngineBinding(
            engineID: "local/tts/demo",
            engineDisplayName: "Demo",
            target: .localEmbedding(relativePath: "../outside.bin")
        )
        XCTAssertThrowsError(
            try VoiceProfile(
                name: "Voice",
                language: "en",
                clips: [validClip],
                consent: validConsent,
                engineBindings: ["local/tts/demo": badEmbedding]
            ).validate()
        ) { XCTAssertEqual($0 as? VoiceProfileValidationError, .invalidEngineBinding("local/tts/demo")) }
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

        XCTAssertThrowsError(
            try store.createProfile(name: "Narrator", language: "en", clips: [clipInput], consent: nil)
        ) { XCTAssertEqual($0 as? VoiceProfileStoreError, .consentRequired) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.metadataFileURL.path))

        XCTAssertThrowsError(
            try store.createProfile(
                name: "Narrator",
                language: "en",
                clips: [clipInput],
                consent: ConsentAttestation(version: "legacy")
            )
        ) { XCTAssertEqual($0 as? VoiceProfileStoreError, .consentRequired) }

        let created = try store.createProfile(
            name: "  Narrator  ",
            language: "en-GB",
            clips: [clipInput],
            consent: ConsentAttestation()
        )
        XCTAssertEqual(created.name, "Narrator")
        XCTAssertEqual(created.clips.count, 1)

        let clipURL = try store.clipURL(for: created.clips[0], in: created.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: clipURL.path))
        XCTAssertEqual(storeRoot.lastPathComponent, VoiceProfileStore.storageDirectoryName)

        #if !os(Windows)
        let dirPerms = (try FileManager.default.attributesOfItem(atPath: storeRoot.path)[.posixPermissions] as? NSNumber)?
            .intValue
        let metaPerms = (try FileManager.default.attributesOfItem(atPath: store.metadataFileURL.path)[.posixPermissions]
            as? NSNumber)?.intValue
        let wavPerms = (try FileManager.default.attributesOfItem(atPath: clipURL.path)[.posixPermissions] as? NSNumber)?
            .intValue
        XCTAssertEqual(dirPerms, 0o700)
        XCTAssertEqual(metaPerms, 0o600)
        XCTAssertEqual(wavPerms, 0o600)
        #endif

        let reloaded = try VoiceProfileStore(directory: storeRoot).listProfiles()
        XCTAssertEqual(reloaded, [created])

        let renamed = try store.renameProfile(id: created.id, name: "Studio Voice", language: "en-US")
        XCTAssertEqual(renamed.name, "Studio Voice")
        XCTAssertEqual(renamed.language, "en-US")

        let edited = try store.updateClipTranscript(
            profileID: created.id,
            clipID: created.clips[0].id,
            transcript: "Updated reference transcript."
        )
        XCTAssertEqual(edited.clips[0].transcript, "Updated reference transcript.")

        let clip2 = VoiceProfileStore.ClipInput(
            pcmBuffer: Self.makeSpeechBuffer(duration: 8.0, sampleRate: 16_000, withPauses: true),
            targetFormat: .pcm16k,
            transcript: "Clip two",
            source: .history
        )
        let clip3 = VoiceProfileStore.ClipInput(
            pcmBuffer: Self.makeSpeechBuffer(duration: 9.0, sampleRate: 24_000, withPauses: true),
            targetFormat: .pcm24k,
            transcript: "Clip three",
            source: .imported
        )
        let clip4 = VoiceProfileStore.ClipInput(
            pcmBuffer: cleanBuffer,
            targetFormat: .pcm24k,
            transcript: "Clip four",
            source: .recorded
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

    func testVoiceProfileStore_DeleteRemovesClipsEmbeddingsAndReturnsRemoteBindings() throws {
        let store = VoiceProfileStore(directory: VoiceProfileStore.defaultDirectory(in: temporaryRoot))
        let clipA = VoiceProfileStore.ClipInput(
            pcmBuffer: Self.makeSpeechBuffer(duration: 8.0, sampleRate: 24_000, withPauses: true),
            transcript: "Clip A",
            source: .recorded
        )
        let clipB = VoiceProfileStore.ClipInput(
            pcmBuffer: Self.makeSpeechBuffer(duration: 9.0, sampleRate: 24_000, withPauses: true),
            transcript: "Clip B",
            source: .imported
        )
        let created = try store.createProfile(
            name: "Clone Target",
            language: "en",
            clips: [clipA, clipB],
            consent: ConsentAttestation()
        )

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
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: store.rootDirectory.appendingPathComponent(created.id.uuidString.lowercased()).path
            )
        )
    }

    func testWAVCodec_RoundTrips16k24kStereoResampleFloatAndExtensible() throws {
        let source24k = Self.makeSpeechBuffer(duration: 2.0, sampleRate: 24_000, withPauses: false)
        let wav24 = try VoiceProfileWAVCodec.encodeWAV(source24k, format: .pcm24k)
        let decoded24 = try VoiceProfileWAVCodec.decodeWAV(wav24)
        XCTAssertEqual(decoded24.sampleRate, 24_000)
        XCTAssertEqual(decoded24.samples.count, source24k.samples.count)

        let wav16 = try VoiceProfileWAVCodec.encodeWAV(source24k, format: .pcm16k)
        let decoded16 = try VoiceProfileWAVCodec.decodeWAV(wav16)
        XCTAssertEqual(decoded16.sampleRate, 16_000)
        XCTAssertEqual(decoded16.durationSeconds, 2.0, accuracy: 0.02)

        let stereo48Data = Self.makeStereoPCM16WAV(sampleRate: 48_000, frameCount: 4_800)
        let decodedStereo = try VoiceProfileWAVCodec.decodeWAV(stereo48Data)
        XCTAssertEqual(decodedStereo.sampleRate, 48_000)
        XCTAssertEqual(decodedStereo.samples.count, 4_800)
        let resampledTo24 = VoiceProfileWAVCodec.resample(decodedStereo, to: .pcm24k)
        XCTAssertEqual(resampledTo24.sampleRate, 24_000)
        XCTAssertEqual(resampledTo24.samples.count, 2_400)

        let floatWAV = Self.makeFloat32WAV(sampleRate: 16_000, samples: [0.0, 0.25, -0.5, 0.75])
        let decodedFloat = try VoiceProfileWAVCodec.decodeWAV(floatWAV)
        XCTAssertEqual(decodedFloat.sampleRate, 16_000)
        XCTAssertEqual(decodedFloat.samples.count, 4)
        XCTAssertEqual(decodedFloat.samples[1], 0.25, accuracy: 1e-4)

        let extensibleWAV = Self.makeExtensiblePCM16WAV(sampleRate: 16_000, samples: [0, 16_384, -16_384])
        let decodedExtensible = try VoiceProfileWAVCodec.decodeWAV(extensibleWAV)
        XCTAssertEqual(decodedExtensible.sampleRate, 16_000)
        XCTAssertEqual(decodedExtensible.samples.count, 3)

        XCTAssertThrowsError(try VoiceProfileWAVCodec.decodeWAV(Data("not-a-wav".utf8))) {
            XCTAssertEqual($0 as? VoiceProfileWAVCodecError, .invalidWAVHeader)
        }
    }

    func testQualityGate_AcceptsCleanSpeechAndFlagsAllIssues() {
        let gate = VoiceProfileQualityGate()

        let clean = Self.makeSpeechBuffer(duration: 10.0, sampleRate: 24_000, fundamentalHz: 145, withPauses: true)
        let cleanReport = gate.evaluate(clean)
        XCTAssertTrue(cleanReport.passed, "Expected clean speech to pass: \(cleanReport.rejectionReasons)")
        XCTAssertTrue(cleanReport.issues.isEmpty)
        XCTAssertGreaterThanOrEqual(cleanReport.estimatedSNRDB, 12.0)

        let shortReport = gate.evaluate(Self.makeSpeechBuffer(duration: 3.0, sampleRate: 16_000, withPauses: true))
        XCTAssertFalse(shortReport.passed)
        XCTAssertTrue(shortReport.issues.contains {
            if case .tooShort = $0 { return true }
            return false
        })

        let longReport = gate.evaluate(Self.makeSpeechBuffer(duration: 34.0, sampleRate: 16_000, withPauses: true))
        XCTAssertFalse(longReport.passed)
        XCTAssertTrue(longReport.issues.contains {
            if case .tooLong = $0 { return true }
            return false
        })

        let clippedSamples = [Float](repeating: 1.0, count: 16_000 * 6)
        let clippedReport = gate.evaluate(VoiceProfilePCMBuffer(samples: clippedSamples, sampleRate: 16_000))
        XCTAssertFalse(clippedReport.passed)
        XCTAssertTrue(clippedReport.issues.contains {
            if case .excessiveClipping = $0 { return true }
            return false
        })

        let silentReport = gate.evaluate(VoiceProfilePCMBuffer(samples: [Float](repeating: 0, count: 16_000 * 8), sampleRate: 16_000))
        XCTAssertFalse(silentReport.passed)
        XCTAssertTrue(silentReport.issues.contains {
            if case .insufficientSpeech = $0 { return true }
            return false
        })

        let noisyReport = gate.evaluate(Self.makeWhiteNoiseBuffer(duration: 8.0, sampleRate: 16_000, amplitude: 0.25))
        XCTAssertFalse(noisyReport.passed)
        XCTAssertTrue(noisyReport.issues.contains {
            if case .lowSignalToNoise = $0 { return true }
            return false
        })

        let speakerOne = Self.makeSpeechBuffer(duration: 5.0, sampleRate: 16_000, fundamentalHz: 105, withPauses: false)
        let speakerTwo = Self.makeSpeechBuffer(duration: 5.0, sampleRate: 16_000, fundamentalHz: 270, withPauses: false)
        let dualSpeaker = VoiceProfilePCMBuffer(samples: speakerOne.samples + speakerTwo.samples, sampleRate: 16_000)
        let multiSpeakerReport = gate.evaluate(dualSpeaker)
        XCTAssertFalse(multiSpeakerReport.passed)
        XCTAssertTrue(multiSpeakerReport.issues.contains(.multipleSpeakersDetected))
    }

    func testClipTrimmer_SelectsCleanSpeechWindowFromLongRecording() {
        let rate = 16_000
        let leadingSilence = [Float](repeating: 0, count: rate * 10)
        let cleanMiddle = Self.makeSpeechBuffer(duration: 15.0, sampleRate: rate, fundamentalHz: 150, withPauses: true)
        let trailingSilence = [Float](repeating: 0, count: rate * 15)
        let longBuffer = VoiceProfilePCMBuffer(
            samples: leadingSilence + cleanMiddle.samples + trailingSilence,
            sampleRate: rate
        )

        let trimmed = VoiceProfileClipTrimmer().trim(longBuffer)
        XCTAssertGreaterThanOrEqual(trimmed.trimmedDurationSeconds, 10.0)
        XCTAssertLessThanOrEqual(trimmed.trimmedDurationSeconds, 20.0)
        XCTAssertGreaterThanOrEqual(trimmed.startTimeSeconds, 8.0)
        XCTAssertLessThanOrEqual(trimmed.endTimeSeconds, 28.0)
        XCTAssertTrue(trimmed.qualityReport.passed, "\(trimmed.qualityReport.rejectionReasons)")
    }

    func testPickerCatalogAndPromptCatalog() {
        let clip = VoiceProfileClip(
            filename: "clip.wav", sampleRate: 24_000, durationSeconds: 10.0, transcript: "Hi", source: .recorded
        )
        let unbound = VoiceProfile(name: "Beta", language: "en", clips: [clip], consent: ConsentAttestation())
        XCTAssertTrue(VoiceProfilePickerCatalog.entries(from: [unbound]).isEmpty)

        var bound = VoiceProfile(name: "Alpha", language: "en", clips: [clip], consent: ConsentAttestation())
        bound.engineBindings["xai"] = VoiceProfileEngineBinding(
            engineID: "xai",
            engineDisplayName: "xAI Voice",
            target: .remoteVoice(voiceID: "xai/custom-1", providerDisplayName: "xAI")
        )
        bound.engineBindings["local/tts/f5"] = VoiceProfileEngineBinding(
            engineID: "local/tts/f5",
            engineDisplayName: "Local F5",
            target: .localEmbedding(relativePath: "embeddings/f5.bin")
        )

        let entries = VoiceProfilePickerCatalog.entries(from: [unbound, bound])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.engineDisplayName), ["Local F5", "xAI Voice"])
        XCTAssertEqual(VoiceProfilePickerCatalog.groupTitle, "My voices")
        XCTAssertTrue(entries[0].desktopPickerLabel.hasPrefix("My voices · Alpha"))
        XCTAssertNotNil(VoiceProfilePickerCatalog.resolve(voiceID: entries[0].id, in: [bound]))
        XCTAssertNotNil(
            VoiceProfilePickerCatalog.resolve(desktopPickerIdentifier: entries[1].desktopPickerIdentifier, in: [bound])
        )
        XCTAssertTrue(VoiceProfilePickerCatalog.isProfileVoiceIdentifier("local/tts/abc"))
        XCTAssertTrue(VoiceProfilePickerCatalog.isProfileVoiceIdentifier("studio/abc"))

        XCTAssertGreaterThanOrEqual(VoiceProfilePromptCatalog.scripts.count, 3)
        for script in VoiceProfilePromptCatalog.scripts {
            XCTAssertFalse(script.sentences.isEmpty)
            XCTAssertFalse(script.fullText.isEmpty)
        }
    }

    // MARK: - Deterministic Audio Generators

    static func makeSpeechBuffer(
        duration: Double,
        sampleRate: Int,
        fundamentalHz: Double = 140.0,
        amplitude: Float = 0.35,
        withPauses: Bool = true
    ) -> VoiceProfilePCMBuffer {
        let count = Int((duration * Double(sampleRate)).rounded())
        var samples = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let seconds = Double(index) / Double(sampleRate)
            let envelope: Double
            if withPauses {
                // Alternate 1.2s voiced speech with 0.3s quiet pause.
                let cycle = seconds.truncatingRemainder(dividingBy: 1.5)
                envelope = cycle < 1.2 ? 1.0 : 0.002
            } else {
                envelope = 1.0
            }
            let pitch = fundamentalHz + 12.0 * sin(2.0 * .pi * 1.5 * seconds)
            let wave = 0.55 * sin(2.0 * .pi * pitch * seconds)
                + 0.30 * sin(2.0 * .pi * (pitch * 2.0) * seconds)
                + 0.15 * sin(2.0 * .pi * (pitch * 3.0) * seconds)
            samples[index] = Float(envelope * Double(amplitude) * wave)
        }
        return VoiceProfilePCMBuffer(samples: samples, sampleRate: sampleRate)
    }

    private static func makeWhiteNoiseBuffer(duration: Double, sampleRate: Int, amplitude: Float) -> VoiceProfilePCMBuffer {
        let count = Int((duration * Double(sampleRate)).rounded())
        var state: UInt64 = 0x5DEECE66D
        var samples = [Float](repeating: 0, count: count)
        for index in 0..<count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let signed = Double(Int64(bitPattern: state >> 16)) / Double(Int64.max >> 16)
            samples[index] = Float(signed) * amplitude
        }
        return VoiceProfilePCMBuffer(samples: samples, sampleRate: sampleRate)
    }

    private static func makeStereoPCM16WAV(sampleRate: Int, frameCount: Int) -> Data {
        var pcm = Data(capacity: frameCount * 4)
        for index in 0..<frameCount {
            let sample = Int16(12_000.0 * sin(2.0 * .pi * 220.0 * Double(index) / Double(sampleRate)))
            var left = sample.littleEndian
            var right = sample.littleEndian
            withUnsafeBytes(of: &left) { pcm.append(contentsOf: $0) }
            withUnsafeBytes(of: &right) { pcm.append(contentsOf: $0) }
        }
        return buildWAV(audioFormat: 1, channels: 2, sampleRate: sampleRate, bitsPerSample: 16, payload: pcm)
    }

    private static func makeFloat32WAV(sampleRate: Int, samples: [Float]) -> Data {
        var payload = Data(capacity: samples.count * 4)
        for sample in samples {
            var bits = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { payload.append(contentsOf: $0) }
        }
        return buildWAV(audioFormat: 3, channels: 1, sampleRate: sampleRate, bitsPerSample: 32, payload: payload)
    }

    private static func makeExtensiblePCM16WAV(sampleRate: Int, samples: [Int16]) -> Data {
        var payload = Data(capacity: samples.count * 2)
        for sample in samples {
            var leSample = sample.littleEndian
            withUnsafeBytes(of: &leSample) { payload.append(contentsOf: $0) }
        }
        var fmt = Data()
        appendLE(UInt16(0xFFFE), to: &fmt)
        appendLE(UInt16(1), to: &fmt)
        appendLE(UInt32(sampleRate), to: &fmt)
        appendLE(UInt32(sampleRate * 2), to: &fmt)
        appendLE(UInt16(2), to: &fmt)
        appendLE(UInt16(16), to: &fmt)
        appendLE(UInt16(22), to: &fmt)
        appendLE(UInt16(16), to: &fmt)
        appendLE(UInt32(4), to: &fmt)
        fmt.append(contentsOf: [0x01, 0x00, 0x00, 0x00]) // PCM SubFormat GUID start
        fmt.append(Data(repeating: 0, count: 12))
        return wrapRIFF(fmtChunk: fmt, dataChunk: payload)
    }

    private static func buildWAV(
        audioFormat: UInt16,
        channels: UInt16,
        sampleRate: Int,
        bitsPerSample: UInt16,
        payload: Data
    ) -> Data {
        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = UInt32(sampleRate) * UInt32(blockAlign)
        var fmt = Data()
        appendLE(audioFormat, to: &fmt)
        appendLE(channels, to: &fmt)
        appendLE(UInt32(sampleRate), to: &fmt)
        appendLE(byteRate, to: &fmt)
        appendLE(blockAlign, to: &fmt)
        appendLE(bitsPerSample, to: &fmt)
        return wrapRIFF(fmtChunk: fmt, dataChunk: payload)
    }

    private static func wrapRIFF(fmtChunk: Data, dataChunk: Data) -> Data {
        var body = Data("WAVE".utf8)
        body.append(Data("fmt ".utf8))
        appendLE(UInt32(fmtChunk.count), to: &body)
        body.append(fmtChunk)
        body.append(Data("data".utf8))
        appendLE(UInt32(dataChunk.count), to: &body)
        body.append(dataChunk)

        var file = Data("RIFF".utf8)
        appendLE(UInt32(body.count), to: &file)
        file.append(body)
        return file
    }

    private static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
