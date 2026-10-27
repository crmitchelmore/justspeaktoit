#if canImport(AudioToolbox) && !SPEAK_PORTABLE_CORE
import Foundation
import SpeakTestSupport
import XCTest

@testable import SpeakCore

final class OpenRouterAudioDownloadObservationTests: XCTestCase {
    private var directory: URL!
    private var session: URLSession!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        session = StubURLProtocol.makeSession()
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        StubURLProtocol.reset()
        try FileManager.default.removeItem(at: directory)
    }

    func testObserverReceivesBoundedOrderedChunksWhileFinalFileRetainsAllBytes() async throws {
        let payload = Data((0..<5005).map { UInt8(truncatingIfNeeded: $0) })
        let recorder = SpeechByteRecorder()
        install(payload)
        let destination = directory.appendingPathComponent("speech.mp3")
        let result = try await OpenRouterAudioDownload.perform(
            request: URLRequest(url: URL(string: "https://stub.invalid/speech")!),
            session: session, destination: destination, limit: 8192, speech: true,
            onBytes: { await recorder.append($0) }
        )
        let chunks = await recorder.snapshot()
        XCTAssertEqual(chunks.map(\.count), [1024, 1024, 1024, 1024, 909])
        XCTAssertEqual(chunks.reduce(into: Data()) { $0.append($1) }, payload)
        XCTAssertEqual(try Data(contentsOf: result), payload)
        let attributes = try FileManager.default.attributesOfItem(atPath: result.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
    }

    func testHTTPMIMEAndLengthFailuresDoNotReachObserverOrCreateFile() async throws {
        for (status, type, length) in [(401, "audio/mpeg", 1), (200, "audio/pcm", 1), (200, "audio/mpeg", 2048)] {
            let recorder = SpeechByteRecorder()
            install(Data([1]), status: status, type: type, length: length)
            let destination = directory.appendingPathComponent(UUID().uuidString)
            do {
                _ = try await OpenRouterAudioDownload.perform(
                    request: URLRequest(url: URL(string: "https://stub.invalid/speech")!),
                    session: session, destination: destination, limit: 1024, speech: true,
                    onBytes: { await recorder.append($0) }
                )
                XCTFail("Header refusal must occur before any observer or file delivery")
            } catch {
                XCTAssertTrue(error is OpenRouterAudioError)
            }
            let chunks = await recorder.snapshot()
            XCTAssertTrue(chunks.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testConsumerCancellationRefusesLaterChunksInsteadOfContinuingDownload() async throws {
        let recorder = SpeechByteRecorder()
        install(Data(repeating: 7, count: 8192))
        do {
            _ = try await OpenRouterAudioDownload.perform(
                request: URLRequest(url: URL(string: "https://stub.invalid/speech")!),
                session: session, destination: directory.appendingPathComponent("speech.mp3"),
                limit: 8192, speech: true,
                onBytes: { bytes in
                    await recorder.append(bytes)
                    throw CancellationError()
                }
            )
            XCTFail("A rejected consumer must not yield a successful file result")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let chunks = await recorder.snapshot()
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.count, 1024)
    }

    private func install(_ payload: Data, status: Int = 200, type: String = "audio/mpeg", length: Int? = nil) {
        StubURLProtocol.respond { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": type, "Content-Length": String(length ?? payload.count)]
            )!
            return (response, payload)
        }
    }
}

private actor SpeechByteRecorder {
    private var chunks: [Data] = []

    func append(_ bytes: Data) { chunks.append(bytes) }
    func snapshot() -> [Data] { chunks }
}
#endif
