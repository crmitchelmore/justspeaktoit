import Foundation
import XCTest
@testable import SpeakCore

final class VoiceStudioTests: XCTestCase {
    // MARK: - Endpoint Security Policy

    func testCredentialsFollowStudioAndValidatedOrigin() throws {
        var config = VoiceStudioConfiguration(kind: .voiceStudio, baseURLString: "https://studio.example/v1")
        let original = try config.apiKeyCredentialIdentifier
        config.baseURLString = "HTTPS://STUDIO.EXAMPLE:443/v2"
        XCTAssertEqual(try config.apiKeyCredentialIdentifier, original)
        for different in ["https://studio.example:444/v1", "https://other.example/v1"] {
            config.baseURLString = different
            XCTAssertNotEqual(try config.apiKeyCredentialIdentifier, original)
        }
        config.baseURLString = "https://studio.example"
        config.kind = .voicebox
        XCTAssertNotEqual(try config.apiKeyCredentialIdentifier, original)
        config.baseURLString = "http://studio.example"
        XCTAssertThrowsError(try config.apiKeyCredentialIdentifier)
    }

    func testNativeStudioKeyMessageAcceptsOnlyAnOriginScopedIdentifierForItsStudio() throws {
        let config = VoiceStudioConfiguration(kind: .voicebox)
        let id = UUID().uuidString
        func decode(_ identifier: String) throws -> VoiceProviderCredentialMessage {
            try .init(operation: "replace", purpose: "voice-output", providerID: config.kind.rawValue,
                      identifier: identifier, sessionID: id, epoch: id, requestID: id, key: "synthetic")
        }
        let identifier = try config.apiKeyCredentialIdentifier
        guard case .save(_, let request) = try decode(identifier) else { return XCTFail("Expected save") }
        XCTAssertEqual(request.identifier, identifier)
        XCTAssertThrowsError(try decode(config.kind.apiKeyCredentialIdentifier))
        XCTAssertThrowsError(try decode(VoiceStudioConfiguration(kind: .voiceStudio).apiKeyCredentialIdentifier))
    }

    func testEndpointPolicyAllowsLoopbackCleartextWithoutAPIKey() throws {
        let validLoopbacks = [
            "http://127.0.0.1:17493",
            "http://127.0.1.5:8000",
            "http://localhost:8000/",
            "http://[::1]:9880",
            "http://[0:0:0:0:0:0:0:1]:9880"
        ]
        for raw in validLoopbacks {
            let endpoint = try VoiceStudioEndpointPolicy.validate(baseURLString: raw, apiKey: nil)
            XCTAssertTrue(endpoint.isLoopback, raw)
            XCTAssertEqual(endpoint.scheme, "http")
        }
    }

    func testEndpointPolicyRejectsCleartextNonLoopbackAndUnauthenticatedRemoteHTTPS() {
        let cleartextRemote = [
            "http://192.168.1.42:8000",
            "http://10.0.0.5:17493",
            "http://voice.example.com:8000",
            "http://localhost.evil.com:8000",
            "http://0177.0.0.1:8000",
            "http://127.1:8000",
            "http://0.0.0.0:8000",
            "http://[::ffff:192.168.1.1]:8000"
        ]
        for raw in cleartextRemote {
            XCTAssertThrowsError(
                try VoiceStudioEndpointPolicy.validate(baseURLString: raw, apiKey: "secret"),
                raw
            ) { err in
                guard case VoiceStudioError.cleartextNonLoopbackDisallowed = err else {
                    return XCTFail("Expected cleartextNonLoopbackDisallowed for \(raw), got \(err)")
                }
            }
        }

        XCTAssertThrowsError(
            try VoiceStudioEndpointPolicy.validate(baseURLString: "https://voice.example.com", apiKey: nil)
        ) { error in
            XCTAssertEqual(error as? VoiceStudioError, .remoteHTTPSRequiresAPIKey(host: "voice.example.com"))
        }

        XCTAssertThrowsError(
            try VoiceStudioEndpointPolicy.validate(baseURLString: "https://voice.example.com", apiKey: "   ")
        ) { error in
            XCTAssertEqual(error as? VoiceStudioError, .remoteHTTPSRequiresAPIKey(host: "voice.example.com"))
        }

        XCTAssertNoThrow(
            try VoiceStudioEndpointPolicy.validate(
                baseURLString: "https://voice.example.com/studio/",
                apiKey: "studio-token-123"
            )
        )
    }

    func testEndpointPolicyRejectsEmbeddedCredentialsQueriesAndCrossOriginAudioURL() throws {
        XCTAssertThrowsError(
            try VoiceStudioEndpointPolicy.validate(baseURLString: "http://user:pass@127.0.0.1:8000", apiKey: nil)
        ) { error in
            XCTAssertEqual(error as? VoiceStudioError, .credentialsInURLDisallowed)
        }

        XCTAssertThrowsError(
            try VoiceStudioEndpointPolicy.validate(baseURLString: "https://127.0.0.1:8000?key=abc", apiKey: nil)
        )
        XCTAssertThrowsError(
            try VoiceStudioEndpointPolicy.validate(baseURLString: "ftp://127.0.0.1:8000", apiKey: nil)
        )

        let endpoint = try VoiceStudioEndpointPolicy.validate(baseURLString: "https://studio.example.com", apiKey: "k")
        let sameOrigin = try endpoint.resolveSameOriginAudioURL("/outputs/clip.wav", kind: .voicebox)
        XCTAssertEqual(sameOrigin.absoluteString, "https://studio.example.com/outputs/clip.wav")

        XCTAssertThrowsError(
            try endpoint.resolveSameOriginAudioURL("https://attacker.example.net/clip.wav", kind: .voicebox)
        ) { error in
            guard case VoiceStudioError.crossOriginAudioURLDisallowed = error else {
                return XCTFail("Expected crossOriginAudioURLDisallowed, got \(error)")
            }
        }

        XCTAssertThrowsError(
            try endpoint.resolveSameOriginAudioURL("http://studio.example.com/outputs/clip.wav", kind: .voicebox)
        ) { error in
            guard case VoiceStudioError.crossOriginAudioURLDisallowed = error else {
                return XCTFail("Expected scheme downgrade rejection, got \(error)")
            }
        }
    }

    // MARK: - WAV Validation & Normalization

    func testWAVNormalizationConvertsStereoFloatWAVToMono24kPCM16() throws {
        let stereoFloatWAV = VoiceStudioTestAudio.makeFloat32StereoWAV(sampleRate: 48_000, frames: 2_400)
        let normalized = try VoiceStudioWAV.normalizeToMono24kPCM16(stereoFloatWAV)
        XCTAssertEqual(normalized.sampleRate, 24_000)
        XCTAssertEqual(normalized.frameCount, 1_200)
        let audio = try DeepgramSpeechWAV.canonical(normalized.wavData, sampleRate: 24_000, requireComplete: true)
        XCTAssertEqual(audio.frameCount, 1_200)

        XCTAssertThrowsError(try VoiceStudioWAV.normalizeToMono24kPCM16(Data())) { error in
            XCTAssertEqual(error as? VoiceStudioWAVError, .emptyAudio)
        }
        XCTAssertThrowsError(try VoiceStudioWAV.normalizeToMono24kPCM16(Data("not-a-wav".utf8)))
    }

    func testDesktopConfigurationRejectsCleartextRemoteURLAndRoundTripsStudioFields() throws {
        XCTAssertThrowsError(
            try DesktopConfiguration(values: [
                VoiceStudioPreference.baseURLKey: AnyCodable(.string("http://remote-studio.example.com:8000"))
            ])
        )

        let valid = try DesktopConfiguration(values: [
            VoiceStudioPreference.enabledKey: AnyCodable(.bool(true)),
            VoiceStudioPreference.kindKey: AnyCodable(.string(VoiceStudioKind.gptSoVITS.rawValue)),
            VoiceStudioPreference.baseURLKey: AnyCodable(.string("http://127.0.0.1:9880")),
            VoiceStudioPreference.gptSoVITSReferenceAudioPathKey: AnyCodable(.string("/tmp/ref.wav")),
            VoiceStudioPreference.gptSoVITSReferencePromptTextKey: AnyCodable(.string("Hello")),
            VoiceStudioPreference.gptSoVITSReferencePromptLanguageKey: AnyCodable(.string("en")),
            VoiceStudioPreference.gptSoVITSTextLanguageKey: AnyCodable(.string("en"))
        ])
        let restored = try JSONDecoder().decode(DesktopConfiguration.self, from: JSONEncoder().encode(valid))
        XCTAssertEqual(restored.voiceStudioConfiguration.kind, .gptSoVITS)
        XCTAssertEqual(restored.voiceStudioConfiguration.gptSoVITSReferenceAudioPath, "/tmp/ref.wav")
        XCTAssertTrue(restored.voiceStudioConfiguration.enabled)
    }
}

enum VoiceStudioTestAudio {
    static func makePCM16MonoWAV(sampleRate: Int, frames: Int) throws -> Data {
        var pcm = Data(capacity: frames * 2)
        for index in 0..<frames {
            let sample = Int16(sin(Double(index) * 0.25) * 8_000.0)
            var little = UInt16(bitPattern: sample).littleEndian
            withUnsafeBytes(of: &little) { pcm.append(contentsOf: $0) }
        }
        return try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: sampleRate, channels: 1, bitsPerSample: 16))
    }

    static func makeFloat32StereoWAV(sampleRate: Int, frames: Int) -> Data {
        let dataBytes = frames * 2 * 4
        var wav = Data(capacity: 44 + dataBytes)
        func appendASCII(_ str: String) { wav.append(Data(str.utf8)) }
        func appendUInt16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
        }
        func appendUInt32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
        }
        func appendFloat32(_ value: Float32) {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { wav.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendUInt32(UInt32(36 + dataBytes))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(3)
        appendUInt16(2)
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * 8))
        appendUInt16(8)
        appendUInt16(32)
        appendASCII("data")
        appendUInt32(UInt32(dataBytes))
        for index in 0..<frames {
            let sample = Float32(sin(Double(index) * 0.2) * 0.4)
            appendFloat32(sample)
            appendFloat32(sample)
        }
        return wav
    }
}
