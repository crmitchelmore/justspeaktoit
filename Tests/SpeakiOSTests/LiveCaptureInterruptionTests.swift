#if os(iOS)
import AVFoundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

@MainActor
final class LiveCaptureInterruptionTests: XCTestCase {
    func testAppleAndOpenAI_interruptionStopsInputButLeavesFinalisationToOwner() async throws {
        guard #available(iOS 26, *) else { throw XCTSkip("Apple SpeechAnalyzer requires iOS 26") }
        for kind in ["apple", "openai"] {
            let backend = makeBackend(kind)
            var notices = 0
            let interrupted = expectation(description: "\(kind) interrupted")
            backend.observe { error in
                XCTAssertTrue((error as? iOSTranscriptionError)?.isControlledInterruption == true)
                notices += 1
                interrupted.fulfill()
            }
            InterruptionSession.post(.began) // idle: no capture subscription
            try await backend.start()
            InterruptionSession.post(.ended)
            await settle()
            XCTAssertEqual(notices, 0)
            InterruptionSession.post(.began)
            InterruptionSession.post(.began)
            InterruptionSession.post(.ended)
            await fulfillment(of: [interrupted], timeout: 2)
            await settle()
            XCTAssertEqual(notices, 1)
            XCTAssertNil(backend.error())
            XCTAssertTrue(backend.running(), "Finalisation remains owned until the owner calls stop")
            _ = await backend.stop()
            XCTAssertFalse(backend.running())
            InterruptionSession.post(.ended)
            await settle()
            XCTAssertFalse(backend.running())
        }
    }

    func testAppleAndOpenAI_cancelRetiresQueuedBeginBeforeFreshExplicitStart() async throws {
        guard #available(iOS 26, *) else { throw XCTSkip("Apple SpeechAnalyzer requires iOS 26") }
        for kind in ["apple", "openai"] {
            let backend = makeBackend(kind)
            var notices = 0
            backend.observe { _ in notices += 1 }
            try await backend.start()
            InterruptionSession.post(.began)
            backend.cancel()
            try await backend.start()
            await settle()
            XCTAssertEqual(notices, 0)
            XCTAssertTrue(backend.running())
            backend.cancel()
        }
    }

    private struct Backend {
        let start: () async throws -> Void
        let stop: () async -> TranscriptionResult
        let cancel: () -> Void
        let running: () -> Bool
        let error: () -> Error?
        let observe: (@escaping (Error) -> Void) -> Void
    }

    private func makeBackend(_ kind: String) -> Backend {
        let manager = AudioSessionManager()
        manager.permissionStatus = { true }
        manager.configureRecording = {}
        manager.deactivateRecording = {}
        if kind == "apple" {
            let transcriber = iOSLiveTranscriber(audioSessionManager: manager)
            transcriber.modelID = AppleLocalModels.speechTranscriberModelID
            transcriber.permissionCheck = { true }
            transcriber.analyzerStart = {}
            return Backend(start: { try await transcriber.start() }, stop: transcriber.stop,
                           cancel: transcriber.cancel, running: { transcriber.isRunning },
                           error: { transcriber.error }, observe: { transcriber.onError = $0 })
        }
        let transcriber = OpenAIRealtimeLiveTranscriber(audioSessionManager: manager)
        transcriber.configure(apiKey: "test-key")
        transcriber.startCaptureAudio = {}
        transcriber.connectRealtimeClient = { _ in }
        return Backend(start: transcriber.start, stop: transcriber.stop, cancel: transcriber.cancel,
                       running: { transcriber.isRunning }, error: { transcriber.error },
                       observe: { transcriber.onError = $0 })
    }

    private func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }
}
#endif
