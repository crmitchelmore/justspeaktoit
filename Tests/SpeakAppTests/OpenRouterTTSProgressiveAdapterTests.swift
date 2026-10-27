import Foundation
import SpeakTestSupport
import XCTest

@testable import SpeakApp
@testable import SpeakCore

@MainActor
final class OpenRouterTTSProgressiveAdapterTests: XCTestCase {
    func testActualAdapterPreservesFinalFileSelectionMetadataAndUnknownCost() async throws {
        let fixture = try OpenRouterTTSCommissioningFixture()
        defer { fixture.cleanup() }
        let bytes = try mp3()
        StubURLProtocol.respond { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                             headerFields: ["Content-Type": "audio/mpeg"])!, bytes)
        }
        let recorder = OpenRouterMacPCMRecorder()
        let response = try await bounded {
            try await fixture.client.synthesizeProgressively(
                text: "Synthetic speech", voice: fixture.selection.id
            ) { await recorder.accept($0) }
        }
        XCTAssertTrue(response.pcmProduced)
        XCTAssertFalse(response.completedFileRequired)
        XCTAssertEqual(response.result.provider, .openrouter)
        XCTAssertEqual(response.result.voice, fixture.selection.id)
        XCTAssertEqual(response.result.characterCount, "Synthetic speech".count)
        XCTAssertNil(response.result.cost)
        XCTAssertTrue(response.result.duration.isFinite)
        XCTAssertGreaterThan(response.result.duration, 0)
        XCTAssertEqual(try Data(contentsOf: response.result.audioURL), bytes)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        let chunks = await recorder.chunks
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= 4800 && $0.count % 2 == 0 })
        let attributes = try FileManager.default.attributesOfItem(atPath: response.result.audioURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testActualAdapterConsumerCancellationDoesNotRetainOrRetryTheFile() async throws {
        let fixture = try OpenRouterTTSCommissioningFixture()
        defer { fixture.cleanup() }
        let bytes = try mp3()
        StubURLProtocol.respond { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                             headerFields: ["Content-Type": "audio/mpeg"])!, bytes)
        }
        do {
            _ = try await bounded {
                try await fixture.client.synthesizeProgressively(
                    text: "Synthetic speech", voice: fixture.selection.id
                ) { _ in throw CancellationError() }
            }
            XCTFail("The native adapter must not transfer a cancelled consumer's result")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
    }

    func testActualAdapterMapsHeaderFailureBeforePCMWithoutRawBody() async throws {
        let fixture = try OpenRouterTTSCommissioningFixture()
        defer { fixture.cleanup() }
        StubURLProtocol.handler = { request in
            .status(402, Data("synthetic private body".utf8), url: request.url!,
                    headers: ["Content-Type": "audio/mpeg"])
        }
        let recorder = OpenRouterMacPCMRecorder()
        do {
            _ = try await bounded {
                try await fixture.client.synthesizeProgressively(
                    text: "Synthetic speech", voice: fixture.selection.id
                ) { await recorder.accept($0) }
            }
            XCTFail("HTTP402 must remain a failed speech request")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("credits are exhausted"))
            XCTAssertFalse(error.localizedDescription.contains("synthetic private body"))
        }
        let chunks = await recorder.chunks
        XCTAssertTrue(chunks.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
    }

    private func bounded(
        _ operation: @escaping @MainActor () async throws -> OpenRouterTTSProgressiveResult
    ) async throws -> OpenRouterTTSProgressiveResult {
        let settled = expectation(description: "Actual adapter settles")
        var outcome: Result<OpenRouterTTSProgressiveResult, Error>?
        let task = Task { @MainActor in
            do { outcome = .success(try await operation()) } catch { outcome = .failure(error) }
            settled.fulfill()
        }
        defer { task.cancel() }
        await fulfillment(of: [settled], timeout: 2)
        return try XCTUnwrap(outcome, "Actual adapter did not settle within the expectation bound").get()
    }

    private func mp3() throws -> Data {
        // Reuse the checked-in synthetic fixture; no copied/generated resource
        // or recorded speech is introduced by the platform adapter tests.
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: tests.appendingPathComponent("SpeakCoreTests/Fixtures/openrouter-tone-mp3.mp3"))
    }
}

private actor OpenRouterMacPCMRecorder {
    private(set) var chunks: [Data] = []
    func accept(_ bytes: Data) { chunks.append(bytes) }
}
