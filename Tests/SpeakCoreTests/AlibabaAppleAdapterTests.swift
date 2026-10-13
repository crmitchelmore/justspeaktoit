import AVFoundation
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class AlibabaAppleAdapterTests: XCTestCase {
    func testSharedFactory_ConstructsTheFinalizingClientWithAuthoritativeSnapshots() throws {
        let route = try XCTUnwrap(LiveTranscriptionRouting.route(for: AlibabaSpeechModels.funLive))
        let client = try XCTUnwrap(LiveTranscriptionClientFactory.makeClient(
            for: route, apiKey: "synthetic", language: "Automatic"
        ))
        XCTAssertTrue(client is AlibabaFunASRLiveClient)
        XCTAssertTrue(client is any FinalizingStreamingTranscriptionClient)
        XCTAssertTrue(client is any StreamingTranscriptSnapshotProviding)
    }

    func testSavingCredential_CapturesConfigurationAndIgnoresLaterFormChanges() throws {
        let suite = "com.justspeaktoit.tests.alibaba.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertThrowsError(try AlibabaSpeechConfiguration.credentialsForSaving("synthetic", defaults: defaults))
        defaults.set("ap-southeast-1", forKey: "alibaba.newKey.region")
        defaults.set("llm-example", forKey: "alibaba.newKey.workspace")
        let saved = try AlibabaSpeechConfiguration.credentialsForSaving("synthetic", defaults: defaults)
        defaults.set("cn-beijing", forKey: "alibaba.newKey.region")
        let config = try AlibabaSpeechConfiguration(credentials: saved)
        XCTAssertEqual(config.region, .singapore)
        XCTAssertEqual(config.workspace, "llm-example")
        XCTAssertTrue(ConfigTransferManager.transferableSecretIdentifiers.contains("alibaba.apiKey"))
    }

    func testSilentRecording_NeverCallsTheProviderOrCreatesPlaceholderText() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = 1_600
        let samples = try XCTUnwrap(buffer.floatChannelData)
        samples[0].initialize(repeating: 0, count: 1_600)
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let credential = try AlibabaSpeechConfiguration(
            region: .singapore, workspace: "llm-example", apiKey: "synthetic"
        ).encodedCredentials()
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        for model in AlibabaSpeechModels.batchIDs {
            let result = try await AlibabaAppleBatchTranscription.transcribeFile(
                at: url, credentials: credential, model: model, language: nil, session: StubURLProtocol.makeSession()
            )
            XCTAssertEqual(result.text, "")
            XCTAssertEqual(result.modelIdentifier, model)
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testAudibleRecording_UsesTheSharedProviderWithDecodedDuration() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = 1_600
        let samples = try XCTUnwrap(buffer.floatChannelData)
        samples[0].initialize(repeating: 0.2, count: 1_600)
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let credential = try AlibabaSpeechConfiguration(
            region: .singapore, workspace: "llm-example", apiKey: "synthetic"
        ).encodedCredentials()
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.respond { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            return (response, Data(#"{"output":{"text":"Hello."}}"#.utf8))
        }
        let result = try await AlibabaAppleBatchTranscription.transcribeFile(
            at: url, credentials: credential, model: " \(AlibabaSpeechModels.funFlash) ", language: "Automatic",
            session: StubURLProtocol.makeSession()
        )
        XCTAssertEqual(result.text, "Hello.")
        XCTAssertEqual(result.duration, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(result.modelIdentifier, AlibabaSpeechModels.funFlash)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
    }
}
