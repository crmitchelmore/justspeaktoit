#if canImport(AudioToolbox) && !SPEAK_PORTABLE_CORE
import Foundation
import XCTest

@testable import SpeakCore

final class OpenRouterProgressiveSpeechTests: XCTestCase {
    private var directory: URL!
    private var session: URLSession!
    private var fixtureID: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fixtureID = UUID().uuidString
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProgressiveSpeechTestProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Speech-Fixture": fixtureID!]
        session = URLSession(configuration: configuration)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        ProgressiveSpeechTestProtocol.remove(fixtureID)
        try FileManager.default.removeItem(at: directory)
    }

    func testSuccessfulResponseUsesOneRequestAndRetainsTheExactPrivateFinalMP3() async throws {
        let bytes = try mp3()
        let fixture = install(bytes)
        let recorder = ProgressiveSpeechRecorder()
        let result = try await client().synthesizeProgressively(text: "Hello", model: "provider/tts", voice: nil) {
            _ = await recorder.accept($0)
        }
        XCTAssertTrue(result.pcmProduced)
        XCTAssertFalse(result.completedFileRequired)
        XCTAssertNil(result.speech.cost)
        XCTAssertEqual(try Data(contentsOf: result.speech.audioURL), bytes)
        XCTAssertEqual(fixture.requestCount, 1)
        let chunks = await recorder.chunks
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= 4800 && $0.count % 2 == 0 })
        let attributes = try FileManager.default.attributesOfItem(atPath: result.speech.audioURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testAcceptedPCMArrivesBeforeHeldFinalByteAndFinalResultWaitsForEOF() async throws {
        let fixture = install(try mp3(), holdLastByte: true)
        let accepted = expectation(description: "PCM accepted before final response byte")
        let settled = expectation(description: "Owned synthesis settled")
        let recorder = ProgressiveSpeechRecorder()
        let audio = client()
        let task = Task {
            do {
                let result = try await audio.synthesizeProgressively(
                    text: "Hello", model: "provider/tts", voice: nil
                ) {
                    if await recorder.accept($0) { accepted.fulfill() }
                }
                await recorder.finish(.success(result))
            } catch { await recorder.finish(.failure(error)) }
            settled.fulfill()
        }
        defer { task.cancel(); fixture.release() }
        await fulfillment(of: [accepted], timeout: 2)
        let premature = await recorder.result
        XCTAssertNil(premature, "The final file result must not precede the actual response EOF")
        fixture.release()
        await fulfillment(of: [settled], timeout: 2)
        guard let outcome = await recorder.result else {
            task.cancel()
            session.invalidateAndCancel()
            return
        }
        let result = try outcome.get()
        XCTAssertTrue(result.pcmProduced)
        XCTAssertFalse(result.completedFileRequired)
        XCTAssertEqual(try Data(contentsOf: result.speech.audioURL), try mp3())
        XCTAssertEqual(fixture.requestCount, 1)
    }

    func testCancellationOfHeldResponseStopsTransportAndDeletesUnpublishedFile() async throws {
        let accepted = expectation(description: "PCM accepted")
        let stopped = expectation(description: "Owned protocol stopped")
        let settled = expectation(description: "Cancelled operation settled")
        let fixture = install(try mp3(), holdLastByte: true, onStop: { stopped.fulfill() })
        let recorder = ProgressiveSpeechRecorder()
        let audio = client()
        let task = Task {
            do {
                let result = try await audio.synthesizeProgressively(
                    text: "Hello", model: "provider/tts", voice: nil
                ) {
                    if await recorder.accept($0) { accepted.fulfill() }
                }
                await recorder.finish(.success(result))
            } catch { await recorder.finish(.failure(error)) }
            settled.fulfill()
        }
        defer { task.cancel(); fixture.release() }
        await fulfillment(of: [accepted], timeout: 2)
        task.cancel()
        await fulfillment(of: [stopped, settled], timeout: 2)
        guard let outcome = await recorder.result else {
            XCTFail("Owned cancelled task did not settle within its expectation bound")
            session.invalidateAndCancel()
            return
        }
        if case .failure(let error) = outcome { XCTAssertTrue(error is CancellationError) } else {
            XCTFail("Cancellation must not become a successful or completed-file result")
        }
        XCTAssertEqual(fixture.requestCount, 1)
        XCTAssertTrue(try files().isEmpty)
    }

    func testKnownTruncationFailsAfterPCMWithoutReplayOrRetainedFile() async throws {
        let fixture = install(Data(try mp3().dropLast()))
        let recorder = ProgressiveSpeechRecorder()
        do {
            _ = try await client().synthesizeProgressively(text: "Hello", model: "provider/tts", voice: nil) {
                _ = await recorder.accept($0)
            }
            XCTFail("Known truncated frames must never request completed-file fallback")
        } catch { XCTAssertEqual(error as? OpenRouterAudioError, .invalidResponse) }
        let accepted = await recorder.chunks
        XCTAssertFalse(accepted.isEmpty, "This fixture must exercise failure after actual consumer acceptance")
        XCTAssertEqual(fixture.requestCount, 1)
        XCTAssertTrue(try files().isEmpty)
    }

    func testConsumerReplacementRefusesSuccessAndRemovesFinalFile() async throws {
        let fixture = install(try mp3())
        do {
            _ = try await client().synthesizeProgressively(text: "Hello", model: "provider/tts", voice: nil) { _ in
                throw CancellationError()
            }
            XCTFail("A replaced consumer cannot silently acknowledge PCM")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.requestCount, 1)
        XCTAssertTrue(try files().isEmpty)
    }

    func testRejectedHeadersNeverDeliverPCMOrRetry() async throws {
        for (status, mime) in [(400, "audio/mpeg"), (200, "audio/pcm")] {
            let fixture = install(Data("private error body".utf8), status: status, mime: mime)
            let recorder = ProgressiveSpeechRecorder()
            do {
                _ = try await client().synthesizeProgressively(text: "Hello", model: "provider/tts", voice: nil) {
                    _ = await recorder.accept($0)
                }
                XCTFail("HTTP or format refusal must fail before decoding")
            } catch {
                XCTAssertEqual(error as? OpenRouterAudioError, status == 400 ? .httpStatus(400) : .invalidResponse)
                XCTAssertFalse(error.localizedDescription.contains("private error body"))
            }
            let chunks = await recorder.chunks
            XCTAssertTrue(chunks.isEmpty)
            XCTAssertEqual(fixture.requestCount, 1)
            XCTAssertTrue(try files().isEmpty)
        }
    }

    private func client() -> OpenRouterAudioClient {
        OpenRouterAudioClient(apiKeyProvider: { "synthetic-test-key" }, session: session, temporaryDirectory: directory)
    }

    private func mp3() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "openrouter-tone-mp3", withExtension: "mp3", subdirectory: "Fixtures"
        ))
        return try Data(contentsOf: url)
    }

    private func files() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    private func install(
        _ bytes: Data, status: Int = 200, mime: String = "audio/mpeg", holdLastByte: Bool = false,
        onStop: (@Sendable () -> Void)? = nil
    ) -> ProgressiveSpeechResponse {
        let fixture = ProgressiveSpeechResponse(
            bytes: bytes, status: status, mime: mime, holdLastByte: holdLastByte, onStop: onStop
        )
        ProgressiveSpeechTestProtocol.install(fixture, id: fixtureID)
        return fixture
    }
}

private actor ProgressiveSpeechRecorder {
    private(set) var chunks: [Data] = []
    private(set) var result: Result<OpenRouterProgressiveSpeechResult, Error>?

    func accept(_ bytes: Data) -> Bool {
        chunks.append(bytes)
        return chunks.count == 1
    }

    func finish(_ outcome: Result<OpenRouterProgressiveSpeechResult, Error>) { result = outcome }
}
#endif
