import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore
@testable import SpeakDesktop

final class DesktopModulateTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testStandardRoutePreservesCustomFlagsMultipartOrderAndSpeakerFormatting() async throws {
        let multipart = DesktopMultipartFixture()
        defer { multipart.remove() }
        let audio = try fixture()
        let source = try Data(contentsOf: audio)
        let features = ModulateTranscriptionFeatures(
            speakerDiarization: true, emotionSignal: true, accentSignal: true, piiPhiTagging: true
        )
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://modulate-developer-apis.com/api/velma-2-stt-batch")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "fixture-key")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.httpBody, "Recordings must upload from a staged file")
            let body = try Self.uploadBody(multipart)
            XCTAssertNotNil(body.range(of: Data("name=\"upload_file\"".utf8)))
            XCTAssertNotNil(body.range(of: Data("Content-Type: audio/wav\r\n".utf8)))
            let audioRange = try XCTUnwrap(body.range(of: source))
            for field in ["speaker_diarization", "emotion_signal", "accent_signal", "pii_phi_tagging"] {
                let fieldBytes = Data("name=\"\(field)\"\r\n\r\ntrue\r\n".utf8)
                let range = try XCTUnwrap(body.range(of: fieldBytes))
                XCTAssertGreaterThan(range.lowerBound, audioRange.upperBound, "Feature flags must follow the file")
            }
            return .ok(Data(Self.standardResponse.utf8), url: request.url!)
        }
        let result = try await transcribe(audio, model: standardModel, features: features, multipart: multipart)
        XCTAssertEqual(result.text, "Speaker 1: Hello.\nSpeaker 2: Hi!")
        XCTAssertEqual(result.segments.map(\.text), ["Speaker 1: Hello.", "Speaker 2: Hi!"])
        XCTAssertEqual(result.segments.map(\.startTime), [0.1, 1])
        XCTAssertEqual(result.segments.map(\.endTime), [0.6, 1.5])
        XCTAssertEqual(result.duration, 2)
        XCTAssertEqual(result.rawPayload, Self.standardResponse)
        XCTAssertEqual(result.modelIdentifier, standardModel)
        try assertClean(multipart, audio: audio)
    }

    func testDisablingDiarizationKeepsPlainTranscriptAndSegments() async throws {
        let multipart = DesktopMultipartFixture()
        defer { multipart.remove() }
        let audio = try fixture()
        StubURLProtocol.handler = { request in
            let body = try Self.uploadBody(multipart)
            for field in ["speaker_diarization", "emotion_signal", "accent_signal", "pii_phi_tagging"] {
                XCTAssertNotNil(body.range(of: Data("name=\"\(field)\"\r\n\r\nfalse\r\n".utf8)))
            }
            return .ok(Data(Self.standardResponse.utf8), url: request.url!)
        }
        let result = try await transcribe(
            audio, model: standardModel, features: .init(speakerDiarization: false), multipart: multipart
        )
        XCTAssertEqual(result.text, "Hello. Hi!")
        XCTAssertEqual(result.segments.map(\.text), ["Hello.", "Hi!"])
        try assertClean(multipart, audio: audio)
    }

    func testEnglishFastOmitsAdvancedFlagsAndKeepsItsOwnCostAndResultShape() async throws {
        let multipart = DesktopMultipartFixture()
        defer { multipart.remove() }
        let audio = try fixture()
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/velma-2-stt-batch-english-vfast")
            let body = try Self.uploadBody(multipart)
            for field in ["speaker_diarization", "emotion_signal", "accent_signal", "pii_phi_tagging"] {
                XCTAssertNil(body.range(of: Data(field.utf8)), "English Fast must not receive \(field)")
            }
            return .ok(Data(#"{"text":"Fast result","duration_ms":3600000}"#.utf8), url: request.url!)
        }
        let result = try await transcribe(
            audio, model: fastModel,
            features: .init(speakerDiarization: true, emotionSignal: true, accentSignal: true, piiPhiTagging: true),
            multipart: multipart
        )
        XCTAssertEqual(result.text, "Fast result")
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments.first?.endTime, 3_600)
        XCTAssertEqual(result.cost?.totalCost, Decimal(string: "0.025"))
        try assertClean(multipart, audio: audio)
    }

    func testDefaultsMatchTheAppleSurfaceAndKeepSingleSpeakerTextUnlabelled() async throws {
        let multipart = DesktopMultipartFixture()
        defer { multipart.remove() }
        let audio = try fixture()
        StubURLProtocol.handler = { request in
            let body = try Self.uploadBody(multipart)
            XCTAssertNotNil(body.range(of: Data("name=\"speaker_diarization\"\r\n\r\ntrue\r\n".utf8)))
            for field in ["emotion_signal", "accent_signal", "pii_phi_tagging"] {
                XCTAssertNotNil(body.range(of: Data("name=\"\(field)\"\r\n\r\nfalse\r\n".utf8)))
            }
            return .ok(Data(Self.singleSpeakerResponse.utf8), url: request.url!)
        }
        let result = try await transcribe(audio, model: standardModel, multipart: multipart)
        XCTAssertEqual(result.text, "Only speaker")
        XCTAssertEqual(result.segments.map(\.text), ["Only speaker"])
        XCTAssertEqual(result.cost?.totalCost, Decimal(string: "0.03"))
        try assertClean(multipart, audio: audio)
    }

    func testCancellingEitherModelCleansUpItsActiveUpload() async throws {
        let multipart = DesktopMultipartFixture()
        defer { multipart.remove() }
        let audio = try fixture()
        for model in models {
            StubURLProtocol.reset()
            let uploading = expectation(description: "Uploading \(model)")
            StubURLProtocol.handler = { _ in uploading.fulfill(); return .hang }
            let session = StubURLProtocol.makeSession()
            let task = Task {
                try await DesktopTranscription.transcribe(
                    audioURL: audio, model: model, apiKey: "fixture-key", duration: 0,
                    staging: multipart.staging, session: session
                )
            }
            await fulfillment(of: [uploading], timeout: 5)
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("Expected cancellation")
            } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            try assertClean(multipart, audio: audio)
        }
    }

    func testMalformedSuccessPayloadsKeepSourceAndRemoveMultipartFiles() async throws {
        let multipart = DesktopMultipartFixture()
        defer { multipart.remove() }
        let audio = try fixture()
        for model in models {
            StubURLProtocol.handler = { request in .ok(Data("invalid JSON".utf8), url: request.url!) }
            do {
                _ = try await transcribe(audio, model: model, multipart: multipart)
                XCTFail("Expected response decoding failure")
            } catch { XCTAssertTrue(error is DecodingError) }
            try assertClean(multipart, audio: audio)
        }
    }

    func testValidatorPreservesAuthenticationEntitlementQuotaAndPayloadSemantics() async throws {
        let multipart = DesktopMultipartFixture()
        defer { multipart.remove() }
        let client = ModulateBatchClient(session: StubURLProtocol.makeSession(), multipartStaging: multipart.staging)
        for status in [200, 400, 422, 429, 401, 403, 500] {
            StubURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.path, "/api/velma-2-stt-batch")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "fixture-key")
                let body = StubURLProtocol.body(of: request)
                let silence = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(count: 8_000), sampleRate: 16_000))
                XCTAssertNotNil(body.range(of: silence))
                return .status(status, Data(#"{"detail":"invalid_api_key"}"#.utf8), url: request.url!)
            }
            let result = await client.validateAPIKey("fixture-key")
            if [200, 400, 422, 429].contains(status) {
                guard case .success = result.outcome else {
                    return XCTFail("\(status) should accept the key")
                }
            } else {
                guard case .failure = result.outcome else {
                    return XCTFail("\(status) should reject the key")
                }
            }
            XCTAssertEqual(result.debug?.requestHeaders["X-API-Key"], "[REDACTED]")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: multipart.directory.path))
    }
}

private extension DesktopModulateTests {
    var models: [String] { ModelCatalog.batchTranscriptionOptions(forProvider: "modulate").map(\.id) }
    var standardModel: String { models.first { !$0.hasSuffix("-english-vfast") }! }
    var fastModel: String { models.first { $0.hasSuffix("-english-vfast") }! }

    static let standardResponse = #"""
    {"text":"Hello. Hi!","duration_ms":2000,"utterances":[
      {"text":"Hello.","start_ms":100,"duration_ms":500,"speaker":1,"language":"en","emotion":"happy"},
      {"text":"Hi!","start_ms":1000,"duration_ms":500,"speaker":2,"language":"en","accent":"British"}]}
    """#
    static let singleSpeakerResponse = #"""
    {"text":"Only speaker","duration_ms":3600000,"utterances":[
      {"text":"Only speaker","start_ms":0,"duration_ms":1000,"speaker":1,"language":"en"}]}
    """#

    func transcribe(
        _ audio: URL, model: String, features: ModulateTranscriptionFeatures = .init(),
        multipart: DesktopMultipartFixture
    ) async throws -> TranscriptionResult {
        try await DesktopTranscription.transcribe(
            audioURL: audio, model: model, apiKey: "fixture-key", duration: 10,
            modulateFeatures: features, staging: multipart.staging, session: StubURLProtocol.makeSession()
        )
    }

    func fixture() throws -> URL {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([0, 255, 255, 127]), sampleRate: 16_000)).write(to: audio)
        addTeardownBlock { try? FileManager.default.removeItem(at: audio) }
        return audio
    }

    static func uploadBody(_ multipart: DesktopMultipartFixture) throws -> Data {
        let files = try FileManager.default.contentsOfDirectory(
            at: multipart.directory, includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.count, 1)
        return try Data(contentsOf: XCTUnwrap(files.first))
    }

    func assertClean(_ multipart: DesktopMultipartFixture, audio: URL) throws {
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: multipart.directory.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }
}
