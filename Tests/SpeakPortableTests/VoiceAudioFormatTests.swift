import Foundation
import XCTest
@testable import SpeakCore

final class VoiceAudioFormatTests: XCTestCase {
    func testFormats_CanonicalIdentifiersMetadataAndPlatformDefaultsStayCompatible() throws {
        XCTAssertEqual(VoiceAudioFormat.allCases.map(\.rawValue), ["mp3", "m4a", "wav"])
        XCTAssertEqual(VoiceAudioFormat.allCases.map(\.displayName), ["MP3", "AAC (M4A)", "WAV"])
        XCTAssertEqual(VoiceAudioFormat.allCases.map(\.fileExtension), ["mp3", "m4a", "wav"])
        XCTAssertTrue(Set(VoiceAudioFormat.allCases.map(\.fileExtension))
            .isSubset(of: RecordingAudioFormats.archiveExtensions))
        XCTAssertEqual(VoiceAudioFormat.macDefault, .mp3)
        XCTAssertEqual(try VoiceAudioFormat.storedValue(nil), .wav)
        XCTAssertThrowsError(try VoiceAudioFormat.storedValue(""))
        XCTAssertThrowsError(try VoiceAudioFormat.storedValue("future/container"))
        XCTAssertThrowsError(try VoiceAudioFormat.storedValue("MP3"))
        for format in VoiceAudioFormat.allCases {
            XCTAssertEqual(try JSONDecoder().decode(VoiceAudioFormat.self,
                from: JSONEncoder().encode(format)), format)
        }
    }

    func testTransfer_UnknownRawFormatSurvivesWithoutDefaultMaterializationOrTypeCoercion() throws {
        let key = VoiceAudioFormat.preferenceKey
        XCTAssertEqual(key, ApplicationPreferenceKey.ttsOutputFormat.rawValue)
        XCTAssertTrue(DesktopConfiguration.voiceTransferKeys.contains(key))
        XCTAssertNil(try VoiceAudioFormat.preference(in: [:]))
        let unknown = try DesktopConfiguration(values: [key: AnyCodable(.string("future/container"))])
        let restored = try JSONDecoder().decode(DesktopConfiguration.self, from: JSONEncoder().encode(unknown))
        XCTAssertEqual(try VoiceAudioFormat.preference(in: restored.values), "future/container")
        XCTAssertThrowsError(try VoiceAudioFormat.preference(in: [key: AnyCodable(.int(1))]))
        XCTAssertThrowsError(try DesktopConfiguration(values: [key: AnyCodable(.string("mp3\n"))]))
    }

    func testGeneratedWAV_IsByteExactAndCannotBeRenamedToCompressedContainers() throws {
        let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: 48_000))
        let audio = try VoiceGeneratedAudio(validating: wav, sampleRate: 48_000)
        XCTAssertEqual(audio.wav, wav)
        XCTAssertEqual(audio.data, wav)
        XCTAssertEqual(audio.format, .wav)
        XCTAssertEqual(audio.sampleRate, 48_000)
        XCTAssertThrowsError(try VoiceGeneratedAudio(encoded: wav, format: .mp3, decodedWAV: wav, sampleRate: 48_000))
        XCTAssertThrowsError(try VoiceGeneratedAudio(encoded: wav, format: .m4a, decodedWAV: wav, sampleRate: 48_000))
        XCTAssertThrowsError(try VoiceAudioFormat.mp3.validateContainer(Data([0xFF, 0xE0, 0x90, 0])))
        XCTAssertThrowsError(try VoiceAudioFormat.m4a.validateContainer(Data("not an MP4".utf8)))
    }

    func testM4A_BoundedExtendedBoxesAreAcceptedButTruncatedOrMissingMediaIsRefused() throws {
        // Synthetic structure checks only; native tests must prove actual encoding and decoding.
        let ftyp = box("ftyp", payload: Data("M4A ".utf8))
        let moov = box("moov")
        let mdat = Data([0, 0, 0, 1]) + Data("mdat".utf8)
            + Data([0, 0, 0, 0, 0, 0, 0, 18, 1, 2])
        try VoiceAudioFormat.m4a.validateContainer(ftyp + moov + mdat)
        XCTAssertThrowsError(try VoiceAudioFormat.m4a.validateContainer(ftyp + moov))
        XCTAssertThrowsError(try VoiceAudioFormat.m4a.validateContainer(ftyp + moov + mdat.dropLast()))
        XCTAssertThrowsError(try VoiceAudioFormat.m4a.validateContainer(ftyp + moov + Data(repeating: 255, count: 8)))
    }

    func testContainerBound_ExactMaximumIsAdmittedOnlyBySanityCheckAndLimitPlusOneRefuses() throws {
        let limit = DeepgramSpeechExport.maximumPCMBytes + 4_096
        var encoded = Data([0xFF, 0xF3, 0x90, 0])
        encoded.append(Data(repeating: 0, count: limit - encoded.count))
        try VoiceAudioFormat.mp3.validateContainer(encoded)
        encoded.append(0)
        XCTAssertThrowsError(try VoiceAudioFormat.mp3.validateContainer(encoded))
        // This does not claim that the synthetic frame-shaped payload decodes as real audio.
    }

    private func box(_ kind: String, payload: Data = Data()) -> Data {
        let size = UInt32(payload.count + 8)
        return Data([UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)])
            + Data(kind.utf8) + payload
    }
}
