import Foundation
import SpeakCore
import XCTest

final class VoiceProfileAudioPortableTests: XCTestCase {
    func testWAVCodec_RoundTrips16k24kStereoResampleFloatAndExtensible() throws {
        let source24k = VoiceProfilePortableTests.makeSpeechBuffer(duration: 2.0, sampleRate: 24_000, withPauses: false)
        let wav24 = try VoiceProfileWAVCodec.encodeWAV(source24k, format: .pcm24k)
        let decoded24 = try VoiceProfileWAVCodec.decodeWAV(wav24)
        XCTAssertEqual(decoded24.sampleRate, 24_000)
        XCTAssertEqual(decoded24.samples.count, source24k.samples.count)

        let sliced = (Data(repeating: 0xAA, count: 16) + wav24).dropFirst(16)
        let decodedSlice = try VoiceProfileWAVCodec.decodeWAV(sliced)
        XCTAssertEqual(decodedSlice.sampleRate, 24_000)
        XCTAssertEqual(decodedSlice.samples.count, source24k.samples.count)

        let wav16 = try VoiceProfileWAVCodec.encodeWAV(source24k, format: .pcm16k)
        let decoded16 = try VoiceProfileWAVCodec.decodeWAV(wav16)
        XCTAssertEqual(decoded16.sampleRate, 16_000)
        XCTAssertEqual(decoded16.durationSeconds, 2.0, accuracy: 0.02)

        let stereo48Data = makeStereoPCM16WAV(sampleRate: 48_000, frameCount: 4_800)
        let decodedStereo = try VoiceProfileWAVCodec.decodeWAV(stereo48Data)
        XCTAssertEqual(decodedStereo.sampleRate, 48_000)
        XCTAssertEqual(decodedStereo.samples.count, 4_800)
        let resampledTo24 = VoiceProfileWAVCodec.resample(decodedStereo, to: .pcm24k)
        XCTAssertEqual(resampledTo24.sampleRate, 24_000)
        XCTAssertEqual(resampledTo24.samples.count, 2_400)

        let floatWAV = makeFloat32WAV(sampleRate: 16_000, samples: [0.0, 0.25, -0.5, 0.75])
        let decodedFloat = try VoiceProfileWAVCodec.decodeWAV(floatWAV)
        XCTAssertEqual(decodedFloat.sampleRate, 16_000)
        XCTAssertEqual(decodedFloat.samples, [0.0, 0.25, -0.5, 0.75])

        let extensibleWAV = makeExtensiblePCM16WAV(sampleRate: 16_000, samples: [0, 16_384, -16_384])
        let decodedExtensible = try VoiceProfileWAVCodec.decodeWAV(extensibleWAV)
        XCTAssertEqual(decodedExtensible.sampleRate, 16_000)
        XCTAssertEqual(decodedExtensible.samples.count, 3)

        XCTAssertThrowsError(try VoiceProfileWAVCodec.decodeWAV(Data("not-a-wav".utf8))) {
            XCTAssertEqual($0 as? VoiceProfileWAVCodecError, .invalidWAVHeader)
        }
    }

    func testQualityGate_AcceptsCleanSpeechAndFlagsAllIssues() {
        let gate = VoiceProfileQualityGate()

        let clean = VoiceProfilePortableTests.makeSpeechBuffer(
            duration: 10.0, sampleRate: 24_000, fundamentalHz: 145, withPauses: true
        )
        let cleanReport = gate.evaluate(clean)
        XCTAssertTrue(cleanReport.passed, "Expected clean speech to pass: \(cleanReport.rejectionReasons)")
        XCTAssertTrue(cleanReport.issues.isEmpty)
        XCTAssertGreaterThanOrEqual(cleanReport.estimatedSNRDB, 12.0)

        let shortBuf = VoiceProfilePortableTests.makeSpeechBuffer(duration: 3.0, sampleRate: 16_000, withPauses: true)
        assertIssue(in: gate.evaluate(shortBuf)) { if case .tooShort = $0 { return true }; return false }

        let longBuf = VoiceProfilePortableTests.makeSpeechBuffer(duration: 34.0, sampleRate: 16_000, withPauses: true)
        assertIssue(in: gate.evaluate(longBuf)) { if case .tooLong = $0 { return true }; return false }

        let clipped = VoiceProfilePCMBuffer(samples: [Float](repeating: 1.0, count: 16_000 * 6), sampleRate: 16_000)
        assertIssue(in: gate.evaluate(clipped)) { if case .excessiveClipping = $0 { return true }; return false }

        let silent = VoiceProfilePCMBuffer(samples: [Float](repeating: 0, count: 16_000 * 8), sampleRate: 16_000)
        assertIssue(in: gate.evaluate(silent)) { if case .insufficientSpeech = $0 { return true }; return false }

        let noisy = makeWhiteNoiseBuffer(duration: 8.0, sampleRate: 16_000, amplitude: 0.25)
        assertIssue(in: gate.evaluate(noisy)) { if case .lowSignalToNoise = $0 { return true }; return false }

        let firstSpeaker = VoiceProfilePortableTests.makeSpeechBuffer(
            duration: 5.0, sampleRate: 16_000, fundamentalHz: 105, withPauses: false
        )
        let secondSpeaker = VoiceProfilePortableTests.makeSpeechBuffer(
            duration: 5.0, sampleRate: 16_000, fundamentalHz: 270, withPauses: false
        )
        let dualSpeaker = VoiceProfilePCMBuffer(
            samples: firstSpeaker.samples + secondSpeaker.samples, sampleRate: 16_000
        )
        let dualReport = gate.evaluate(dualSpeaker)
        XCTAssertTrue(dualReport.issues.contains(.multipleSpeakersDetected), "dualReport=\(dualReport)")
    }

    func testClipTrimmer_SelectsCleanSpeechWindowFromLongRecording() {
        let rate = 16_000
        let leadingSilence = [Float](repeating: 0, count: rate * 10)
        let cleanMiddle = VoiceProfilePortableTests.makeSpeechBuffer(
            duration: 15.0, sampleRate: rate, fundamentalHz: 150, withPauses: true
        )
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
        let resolvedDesktop = VoiceProfilePickerCatalog.resolve(
            desktopPickerIdentifier: entries[1].desktopPickerIdentifier, in: [bound]
        )
        XCTAssertNotNil(resolvedDesktop)
        XCTAssertTrue(VoiceProfilePickerCatalog.isProfileVoiceIdentifier("local/tts/abc"))
        XCTAssertTrue(VoiceProfilePickerCatalog.isProfileVoiceIdentifier("studio/abc"))

        XCTAssertGreaterThanOrEqual(VoiceProfilePromptCatalog.scripts.count, 3)
        for script in VoiceProfilePromptCatalog.scripts {
            XCTAssertFalse(script.sentences.isEmpty)
            XCTAssertFalse(script.fullText.isEmpty)
        }
    }
}

private extension VoiceProfileAudioPortableTests {
    func assertIssue(in report: VoiceProfileQualityReport, matching predicate: (VoiceProfileQualityIssue) -> Bool) {
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.issues.contains(where: predicate))
    }

    func makeWhiteNoiseBuffer(duration: Double, sampleRate: Int, amplitude: Float) -> VoiceProfilePCMBuffer {
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

    func makeStereoPCM16WAV(sampleRate: Int, frameCount: Int) -> Data {
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

    func makeFloat32WAV(sampleRate: Int, samples: [Float]) -> Data {
        var payload = Data(capacity: samples.count * 4)
        for sample in samples {
            var bits = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { payload.append(contentsOf: $0) }
        }
        return buildWAV(audioFormat: 3, channels: 1, sampleRate: sampleRate, bitsPerSample: 32, payload: payload)
    }

    func makeExtensiblePCM16WAV(sampleRate: Int, samples: [Int16]) -> Data {
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
        fmt.append(contentsOf: [0x01, 0x00, 0x00, 0x00])
        fmt.append(Data(repeating: 0, count: 12))
        return wrapRIFF(fmtChunk: fmt, dataChunk: payload)
    }

    func buildWAV(
        audioFormat: UInt16, channels: UInt16, sampleRate: Int, bitsPerSample: UInt16, payload: Data
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

    func wrapRIFF(fmtChunk: Data, dataChunk: Data) -> Data {
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

    func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
