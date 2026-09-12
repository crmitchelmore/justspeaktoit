import Foundation
import XCTest

@testable import SpeakCore

final class LiveClientOptionsTests: XCTestCase {
    func testAssemblyAIInitializersPreserveLegacyURLAndEncodeBoundedKeyterms() throws {
        let legacy = AssemblyAILiveClient(apiKey: "test-key")
        let empty = AssemblyAILiveClient(apiKey: "test-key", keyterms: [])
        XCTAssertEqual(
            legacy.makeRequest(endpoint: .europe)?.url,
            empty.makeRequest(endpoint: .europe)?.url
        )

        let terms = ["München", #"quoted \"term\"!"#]
            + [String](repeating: "", count: 2)
            + [String](repeating: String(repeating: "x", count: 51), count: 2)
            + (0..<105).map { "valid-\($0)" }
        let client = AssemblyAILiveClient(apiKey: "test-key", keyterms: terms)

        for endpoint in [AssemblyAIStreamingEndpoint.europe, .global] {
            let request = try XCTUnwrap(client.makeRequest(endpoint: endpoint))
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "test-key")
            XCTAssertEqual(components.host, endpoint.rawValue)
            let encoded = try XCTUnwrap(components.queryItems?.first { $0.name == "keyterms_prompt" }?.value)
            let data = try XCTUnwrap(encoded.data(using: .utf8))
            let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String])
            XCTAssertEqual(decoded.count, 100)
            XCTAssertEqual(Array(decoded.prefix(2)), ["München", #"quoted \"term\"!"#])
            XCTAssertFalse(decoded.contains(String(repeating: "x", count: 51)))
        }
    }

    func testModulateInitializersPreserveLegacyURLAndRouteEveryOptionOnce() throws {
        let legacy = ModulateLiveClient(apiKey: "test-key")
        let empty = ModulateLiveClient(apiKey: "test-key", options: .none)
        XCTAssertEqual(legacy.makeRequest()?.url, empty.makeRequest()?.url)

        let options = ModulateLiveOptions(
            speakerDiarization: true,
            emotionSignal: false,
            accentSignal: true,
            piiPhiTagging: true
        )
        let request = try XCTUnwrap(ModulateLiveClient(apiKey: "test-key", options: options).makeRequest())
        let items = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.filter { $0.name == "speaker_diarization" }.map(\.value), ["true"])
        XCTAssertEqual(items.filter { $0.name == "emotion_signal" }.map(\.value), ["false"])
        XCTAssertEqual(items.filter { $0.name == "accent_signal" }.map(\.value), ["true"])
        XCTAssertEqual(items.filter { $0.name == "pii_phi_tagging" }.map(\.value), ["true"])
        XCTAssertEqual(request.timeoutInterval, 30)
    }

    func testFactoryPreservesOldOverloadsAndRoutesProviderOptions() throws {
        let assemblyRoute = LiveTranscriptionRoute(
            modelID: "assemblyai/test", provider: .assemblyai,
            apiModelName: "universal-3-5-pro", sampleRate: 16_000
        )
        XCTAssertNotNil(LiveTranscriptionClientFactory.makeClient(
            for: assemblyRoute, apiKey: "test-key", language: nil
        ))
        XCTAssertNotNil(LiveTranscriptionClientFactory.makeClient(
            for: assemblyRoute, apiKey: "test-key", language: nil,
            keywords: ["legacy"], azureEndpoint: ""
        ))

        let assembly = try XCTUnwrap(LiveTranscriptionClientFactory.makeClient(
            for: assemblyRoute, apiKey: "test-key", language: nil,
            options: LiveClientOptions(assemblyAIKeyterms: ["proper noun"])
        ) as? AssemblyAILiveClient)
        XCTAssertTrue(try XCTUnwrap(assembly.makeRequest(endpoint: .europe)?.url?.absoluteString)
            .contains("keyterms_prompt"))

        let modulateRoute = LiveTranscriptionRoute(
            modelID: "modulate/test", provider: .modulate,
            apiModelName: "velma", sampleRate: 16_000
        )
        let modulate = try XCTUnwrap(LiveTranscriptionClientFactory.makeClient(
            for: modulateRoute, apiKey: "test-key", language: nil,
            options: LiveClientOptions(modulate: ModulateLiveOptions(emotionSignal: true))
        ) as? ModulateLiveClient)
        XCTAssertTrue(try XCTUnwrap(modulate.makeRequest()?.url?.absoluteString).contains("emotion_signal=true"))

        let googleRoute = LiveTranscriptionRoute(
            modelID: "google/test", provider: .google,
            apiModelName: "gemini", sampleRate: 16_000
        )
        let google = try XCTUnwrap(LiveTranscriptionClientFactory.makeClient(
            for: googleRoute, apiKey: "test-key", language: nil,
            options: LiveClientOptions(keywords: ["vocabulary"])
        ) as? GeminiLiveClient)
        XCTAssertEqual(google.customVocabulary, ["vocabulary"])
    }
}
