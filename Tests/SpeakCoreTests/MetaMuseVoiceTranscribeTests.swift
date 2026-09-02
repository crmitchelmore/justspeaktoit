import Foundation
import XCTest

@testable import SpeakCore

final class MetaMuseVoiceTranscribeTests: XCTestCase {
    func testCatalogAndRouting_exposeLiveAndBatchOnBothPlatforms() throws {
        XCTAssertTrue(ModelCatalog.liveTranscription.contains { $0.id == MetaMuseVoiceTranscribe.liveCatalogID })
        XCTAssertTrue(ModelCatalog.batchTranscription.contains { $0.id == MetaMuseVoiceTranscribe.batchCatalogID })

        let route = try XCTUnwrap(LiveTranscriptionRouting.route(for: MetaMuseVoiceTranscribe.liveCatalogID))
        XCTAssertEqual(route.provider, .meta)
        XCTAssertEqual(route.apiModelName, MetaMuseVoiceTranscribe.modelID)
        XCTAssertEqual(route.sampleRate, 24_000)
        XCTAssertEqual(route.apiKeyIdentifier, "meta.apiKey")
        XCTAssertTrue(route.isSupportedOnIOS)
        XCTAssertTrue(LiveTranscriptionRouting.iOSSupportedProviders.contains(.meta))
        XCTAssertTrue(
            LiveTranscriptionClientFactory.makeClient(
                for: route,
                apiKey: "key",
                language: "en-GB",
                keywords: ["JustSpeakToIt"]
            ) is MetaMuseLiveClient
        )
    }

    func testHandshake_usesDedicatedSpeechContractAndBiasOptions() throws {
        let data = try MetaMuseLiveClient.handshakeData(
            apiKey: "secret",
            model: MetaMuseVoiceTranscribe.modelID,
            sampleRate: 24_000,
            language: "fr-FR",
            keywords: ["Muse Voice", "JustSpeakToIt"]
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let authorization = try XCTUnwrap(json["authorization"] as? [String: String])

        XCTAssertEqual(authorization["accessToken"], "Bearer secret")
        XCTAssertEqual(json["audioEncoding"] as? String, "PCM_24KHZ")
        XCTAssertEqual(json["model"] as? String, MetaMuseVoiceTranscribe.modelID)
        XCTAssertEqual(json["mode"] as? String, "ENDPOINTING")
        XCTAssertEqual(json["partialMode"] as? String, "CUMULATIVE")
        XCTAssertEqual(json["languageBias"] as? [String], ["French"])
        XCTAssertEqual(json["keywords"] as? [String], ["Muse Voice", "JustSpeakToIt"])
    }

    func testServerEvents_preserveEndpointingSemantics() {
        XCTAssertEqual(
            MetaMuseServerEvent(object: [
                "type": "transcript", "transcript": "hello", "final": false
            ]),
            .transcript("hello")
        )
        XCTAssertEqual(
            MetaMuseServerEvent(object: [
                "type": "speechEnd", "turnId": 7, "audioProcessedMs": 2_400
            ]),
            .lifecycle,
            "speechEnd is only a boundary; speechComplete carries the authoritative final text"
        )
        XCTAssertEqual(
            MetaMuseServerEvent(object: [
                "type": "speechComplete", "turnId": 7, "transcript": "Hello."
            ]),
            .speechComplete(turnID: 7, transcript: "Hello.")
        )
        XCTAssertNil(MetaMuseServerEvent(object: ["type": "speechComplete", "turnId": 7]))
        XCTAssertNil(MetaMuseServerEvent(object: ["transcript": "missing type"]))
    }

    func testReconnectPolicy_retriesOnlyTransientPreHandshakeFailure() {
        XCTAssertTrue(
            MetaMuseLiveClient.shouldReconnect(
                didHandshake: false, attempt: 0, closeCode: 1_011, isEnding: false
            )
        )
        XCTAssertTrue(
            MetaMuseLiveClient.shouldReconnect(
                didHandshake: false, attempt: 0, closeCode: nil, isEnding: false
            )
        )
        XCTAssertFalse(
            MetaMuseLiveClient.shouldReconnect(
                didHandshake: true, attempt: 0, closeCode: 1_011, isEnding: false
            )
        )
        XCTAssertFalse(
            MetaMuseLiveClient.shouldReconnect(
                didHandshake: false, attempt: 1, closeCode: 1_011, isEnding: false
            )
        )
        XCTAssertFalse(
            MetaMuseLiveClient.shouldReconnect(
                didHandshake: false, attempt: 0, closeCode: 1_011, isEnding: true
            ),
            "Cancellation/finalisation must never resurrect a session"
        )
        XCTAssertFalse(
            MetaMuseLiveClient.shouldReconnect(
                didHandshake: false, attempt: 0, closeCode: 1_008, isEnding: false
            )
        )
    }

    func testErrors_mapAuthenticationRateLimitAndPolicyFailures() {
        XCTAssertEqual(MetaMuseError.fromHTTPStatus(401, body: "bad key"), .authentication)
        XCTAssertEqual(MetaMuseError.fromHTTPStatus(429, body: "slow down"), .rateLimited)
        XCTAssertEqual(MetaMuseError.fromHTTPStatus(413, body: "large"), .requestTooLarge)
        XCTAssertEqual(MetaMuseLiveClient.error(fromServerMessage: "invalid access token"), .authentication)
        XCTAssertEqual(MetaMuseLiveClient.error(fromServerMessage: "concurrency limit reached"), .rateLimited)
        XCTAssertEqual(
            MetaMuseLiveClient.error(fromServerMessage: "below-realtime ingress"),
            .streamingPolicy("below-realtime ingress")
        )
    }

    func testLanguageAndKeywords_normalizeSupportedValues() {
        XCTAssertEqual(MetaMuseVoiceTranscribe.languageBias(for: "en_GB"), ["English"])
        XCTAssertEqual(MetaMuseVoiceTranscribe.languageBias(for: "zh-Hans"), ["Mandarin Chinese"])
        XCTAssertEqual(MetaMuseVoiceTranscribe.languageBias(for: "unknown"), [])
        XCTAssertEqual(
            MetaMuseVoiceTranscribe.keywords(from: " Muse Voice, eSIM\nmuse voice, 5G "),
            ["Muse Voice", "eSIM", "5G"]
        )
    }

    func testBatchRequest_usesMultipartSpeechEndpointContract() throws {
        let wav = MetaMuseAudioPreparer.wavData(pcm: Data([0, 0]), sampleRate: 16_000)
        let request = try MetaMuseBatchClient.makeRequest(
            endpoint: MetaMuseVoiceTranscribe.transcribeURL,
            apiKey: "secret",
            audio: wav,
            filename: "sample.wav",
            model: MetaMuseVoiceTranscribe.modelID,
            mode: .endpointing,
            languageBias: ["English"],
            keywords: ["Muse"]
        )
        let body = try XCTUnwrap(request.httpBody)

        XCTAssertEqual(request.url, MetaMuseVoiceTranscribe.transcribeURL)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertNotNil(body.range(of: Data(#"name="request""#.utf8)))
        XCTAssertNotNil(body.range(of: Data(#""audioEncoding":"WAV""#.utf8)))
        XCTAssertNotNil(body.range(of: Data(#""mode":"ENDPOINTING""#.utf8)))
        XCTAssertNotNil(body.range(of: Data(#""languageBias":["English"]"#.utf8)))
        XCTAssertNotNil(body.range(of: Data(#""keywords":["Muse"]"#.utf8)))
        XCTAssertNotNil(body.range(of: Data(#"name="audio"; filename="sample.wav""#.utf8)))
        XCTAssertTrue(body.contains(Data("RIFF".utf8)))
    }

    func testAudioPreparation_buildsSupportedPCM16WAVHeader() {
        let data = MetaMuseAudioPreparer.wavData(pcm: Data([1, 2, 3, 4]), sampleRate: 16_000)

        XCTAssertEqual(String(bytes: data[0..<4], encoding: .utf8), "RIFF")
        XCTAssertEqual(String(bytes: data[8..<12], encoding: .utf8), "WAVE")
        XCTAssertEqual(String(bytes: data[36..<40], encoding: .utf8), "data")
        XCTAssertEqual(data.count, 48)
    }

    func testAudioPreparation_resamplesImportedAudioTo16kHzMonoPCM() async throws {
        let audioURL = try makeTemporaryWAV(sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let prepared = try await MetaMuseAudioPreparer.prepareWAV(at: audioURL)

        let rate = prepared.data[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        let channels = prepared.data[22..<24].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
        let bitDepth = prepared.data[34..<36].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
        XCTAssertEqual(rate, 16_000)
        XCTAssertEqual(channels, 1)
        XCTAssertEqual(bitDepth, 16)
        XCTAssertEqual(prepared.duration, 0.1, accuracy: 0.002)
    }

    func testRealtimeURL_carriesDocumentedSessionIdentifier() throws {
        let url = try XCTUnwrap(MetaMuseLiveClient.webSocketURL(sessionID: "session-1"))

        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "api.meta.ai")
        XCTAssertEqual(url.path, "/v1/asr/realtime")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "sessionId", value: "session-1")])
    }

    func testHandshake_selects16kHzEncodingAndOmitsEmptyBias() throws {
        let data = try MetaMuseLiveClient.handshakeData(
            apiKey: "secret",
            model: MetaMuseVoiceTranscribe.modelID,
            sampleRate: 16_000,
            language: nil,
            keywords: []
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["audioEncoding"] as? String, "PCM_16KHZ")
        XCTAssertEqual(json["emitAudioProgress"] as? Bool, false)
        XCTAssertNil(json["languageBias"])
        XCTAssertNil(json["keywords"])
    }

    func testCloseCodes_mapToDocumentedRecoveryOutcomes() {
        let fallback = URLError(.networkConnectionLost)

        XCTAssertEqual(
            MetaMuseLiveClient.error(closeCode: 1_008, reason: Data("backlog".utf8), fallback: fallback),
            .streamingPolicy("backlog")
        )
        XCTAssertEqual(
            MetaMuseLiveClient.error(closeCode: 1_013, reason: nil, fallback: fallback),
            .rateLimited
        )
        XCTAssertEqual(
            MetaMuseLiveClient.error(closeCode: 1_011, reason: Data("backend".utf8), fallback: fallback),
            .unavailable("backend")
        )
    }

    func testAPIModelName_stripsCataloguePrefixAndStreamingSuffix() {
        XCTAssertEqual(
            MetaMuseBatchClient.apiModelName(from: MetaMuseVoiceTranscribe.liveCatalogID),
            MetaMuseVoiceTranscribe.modelID
        )
        XCTAssertEqual(
            MetaMuseBatchClient.apiModelName(from: MetaMuseVoiceTranscribe.batchCatalogID),
            MetaMuseVoiceTranscribe.modelID
        )
    }

    private func makeTemporaryWAV(sampleRate: Int = 16_000) throws -> URL {
        let pcm = Data(repeating: 0, count: sampleRate / 5)
        let data = MetaMuseAudioPreparer.wavData(pcm: pcm, sampleRate: sampleRate)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meta-muse-\(UUID().uuidString).wav")
        try data.write(to: url, options: .atomic)
        return url
    }
}
