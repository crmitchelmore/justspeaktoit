#if os(iOS)
import Foundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

@MainActor
final class TranscriberStartupCancellationTests: XCTestCase {
    private struct Backend {
        let start: @MainActor () async throws -> Void
        let cancel: @MainActor () -> Void
        let error: @MainActor () -> Error?
    }

    func testAllBackends_cancelDuringPermissionWithoutWaitingForLateReply() async throws {
        for kind in ["apple", "openai", "shared", "batch"] {
            let manager = AudioSessionManager()
            manager.permissionStatus = { false }
            let requested = expectation(description: "\(kind) permission wait")
            let settled = expectation(description: "\(kind) cancelled")
            var reply: (@Sendable (Bool) -> Void)?
            var configurations = 0
            manager.permissionRequest = { callback in
                reply = callback
                requested.fulfill()
            }
            manager.configureRecording = { configurations += 1 }
            manager.deactivateRecording = {}
            let backend = try makeBackend(kind, manager: manager)
            let start = Task { @MainActor in
                do {
                    try await backend.start()
                    XCTFail("\(kind) ignored cancellation")
                } catch { XCTAssertTrue(error is CancellationError, "\(kind): \(error)") }
                settled.fulfill()
            }
            await fulfillment(of: [requested], timeout: 2)
            backend.cancel()
            backend.cancel()
            await fulfillment(of: [settled], timeout: 2)
            reply?(true)
            reply?(false)
            await start.value
            XCTAssertEqual(configurations, 0, kind)
            XCTAssertFalse(manager.isConfigured, kind)
            XCTAssertNil(backend.error(), kind)
        }
    }

    func testAllBackends_cancelDuringConfigurationReleasesOnceAndKeepsCancellationType() async throws {
        for kind in ["apple", "openai", "shared", "batch"] {
            let manager = AudioSessionManager()
            manager.permissionStatus = { true }
            let configuring = expectation(description: "\(kind) configuring")
            let settled = expectation(description: "\(kind) settled")
            var releases = 0
            manager.configureRecording = {
                _ = await CancellablePermissionRequest.request { _ in configuring.fulfill() }
                try Task.checkCancellation()
            }
            manager.deactivateRecording = { releases += 1 }
            let backend = try makeBackend(kind, manager: manager, skipSpeechPermission: true)
            let start = Task { @MainActor in
                do {
                    try await backend.start()
                    XCTFail("\(kind) configured after cancellation")
                } catch { XCTAssertTrue(error is CancellationError, "\(kind): \(error)") }
                settled.fulfill()
            }
            await fulfillment(of: [configuring], timeout: 2)
            backend.cancel() // parent start task deliberately stays uncancelled
            backend.cancel()
            await fulfillment(of: [settled], timeout: 2)
            await start.value
            XCTAssertEqual(releases, 1, kind)
            XCTAssertFalse(manager.isConfigured, kind)
            XCTAssertNil(backend.error(), kind)
        }
    }

    func testAppleAnalyzerCancellation_doesNotFallBackToLegacyRecognizer() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("SpeechAnalyzer requires iOS 26") }
        let manager = AudioSessionManager()
        manager.configureRecording = {}
        var releases = 0
        manager.deactivateRecording = { releases += 1 }
        let transcriber = iOSLiveTranscriber(audioSessionManager: manager)
        transcriber.permissionCheck = { true }
        transcriber.modelID = AppleLocalModels.speechTranscriberModelID
        transcriber.analyzerStart = { throw CancellationError() }

        do {
            try await transcriber.start(preRollBuffers: [], analyzerFallbackAllowed: true)
            XCTFail("cancellation unexpectedly fell back")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(transcriber.isRunning)
        XCTAssertEqual(releases, 1)
        XCTAssertNil(transcriber.error)
    }

    private func makeBackend(
        _ kind: String,
        manager: AudioSessionManager,
        skipSpeechPermission: Bool = false
    ) throws -> Backend {
        switch kind {
        case "apple":
            let transcriber = iOSLiveTranscriber(audioSessionManager: manager)
            if skipSpeechPermission { transcriber.permissionCheck = { true } }
            return Backend(start: { try await transcriber.start() }, cancel: transcriber.cancel,
                           error: { transcriber.error })
        case "openai":
            let transcriber = OpenAIRealtimeLiveTranscriber(audioSessionManager: manager)
            transcriber.configure(apiKey: "test-key")
            return Backend(start: transcriber.start, cancel: transcriber.cancel, error: { transcriber.error })
        case "shared":
            let route = try XCTUnwrap(LiveTranscriptionRouting.route(for: "deepgram/nova-3-streaming"))
            let transcriber = SharedClientLiveTranscriber(
                route: route, apiKey: "test-key", audioSessionManager: manager
            )
            return Backend(start: transcriber.start, cancel: transcriber.cancel, error: { transcriber.error })
        default:
            let transcriber = IOSBatchTranscriber(
                audioSessionManager: manager, model: "openai/gpt-4o-mini-transcribe", apiKey: "test-key"
            )
            return Backend(start: transcriber.start, cancel: transcriber.cancel, error: { nil })
        }
    }
}
#endif
