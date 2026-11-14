import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore
@testable import SpeakDesktop

final class Reson8ModelTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testModelIDsResolveOnlyOfferedReson8Engines() {
        XCTAssertEqual(Reson8Model.allCases.map(\.batchID), ["reson8/rumble-2", "reson8/resonant-1"])
        XCTAssertEqual(
            Reson8Model.allCases.map(\.liveID), ["reson8/rumble-2-streaming", "reson8/resonant-1-streaming"]
        )
        for model in Reson8Model.allCases {
            XCTAssertEqual(Reson8Model(modelID: model.batchID), model)
            XCTAssertEqual(Reson8Model(modelID: " \(model.liveID)\n"), model)
        }
        for unknown in ["reson8/rumble-2-flash", "reson8/rumble-2-flash-streaming", "reson8/", "rumble-2"] {
            XCTAssertNil(Reson8Model(modelID: unknown), unknown)
        }
    }

    func testLiveRequestWireModelAndLanguageAllowListFollowTheSelectedModel() throws {
        for (model, wire) in [(Reson8Model.resonant1, "resonant-1"), (.rumble2, "rumble-2")] {
            let items = try queryItems(Reson8LiveClient.request(
                apiKey: "synthetic", model: model, language: "pl_PL", sampleRate: 16_000
            ))
            XCTAssertEqual(items.filter { $0.name == "model" }, [URLQueryItem(name: "model", value: wire)])
            XCTAssertTrue(items.contains(URLQueryItem(name: "language", value: "pl")))
        }
        let japanese = try queryItems(Reson8LiveClient.request(
            apiKey: "synthetic", model: .rumble2, language: "ja_JP", sampleRate: 16_000
        ))
        XCTAssertTrue(japanese.contains(URLQueryItem(name: "language", value: "ja")))
        XCTAssertThrowsError(try Reson8LiveClient.request(
            apiKey: "synthetic", model: .resonant1, language: "ja_JP", sampleRate: 16_000
        )) { XCTAssertEqual($0 as? FileSpeechError, .unsupportedLanguage("Reson8 Resonant-1", "ja")) }
    }

    func testBatchWireModelLanguagesAndHistoryIDFollowTheSelectedModel() async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data([0, 1, 2, 3]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let client = FileSpeechBatchClient(provider: .reson8)
        for (model, wire) in [(Reson8Model.resonant1, "resonant-1"), (.rumble2, "rumble-2")] {
            let items = try queryItems(client.makeRequest(
                audioURL: audio, apiKey: "synthetic", language: "pl_PL", model: model.batchID
            ))
            XCTAssertEqual(items.filter { $0.name == "model" }, [URLQueryItem(name: "model", value: wire)])
            XCTAssertTrue(items.contains(URLQueryItem(name: "language", value: "pl")))
        }
        XCTAssertThrowsError(try client.makeRequest(
            audioURL: audio, apiKey: "synthetic", language: "ja_JP", model: Reson8Model.resonant1.batchID
        )) { XCTAssertEqual($0 as? FileSpeechError, .unsupportedLanguage("Reson8 Resonant-1", "ja")) }
        StubURLProtocol.handler = { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(items.filter { $0.name == "model" }, [URLQueryItem(name: "model", value: "rumble-2")])
            XCTAssertTrue(items.contains(URLQueryItem(name: "language", value: "ja")))
            return .ok(Data(#"{"text":"こんにちは","duration_ms":1000}"#.utf8), url: request.url!)
        }
        let result = try await DesktopTranscription.transcribe(
            audioURL: audio, model: Reson8Model.rumble2.batchID, apiKey: "synthetic", duration: 60,
            language: "ja_JP", session: StubURLProtocol.makeSession()
        )
        XCTAssertEqual(result.text, "こんにちは")
        XCTAssertEqual(result.modelIdentifier, "reson8/rumble-2")
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
    }

    private func queryItems(_ request: URLRequest) throws -> [URLQueryItem] {
        let url = try XCTUnwrap(request.url)
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }
}
