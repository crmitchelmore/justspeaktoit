import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// One contract over every shared live client that uses the common confinement
/// mechanics (`LiveClientStateQueue`/`QueueConfinedLiveClient`,
/// `LiveSingleFlightSending`, `LiveDeferredEffects`). Each case drives the real
/// client through the fake `StreamingWebSocketConnection` and a manual clock;
/// only the handshake that makes a session ready is provider-shaped. Terminal
/// semantics (which frame ends a stream, what counts as success) stay covered
/// by each provider's own suite: these assertions hold for every provider.
final class LiveClientMechanicsContractTests: XCTestCase {
    func testFinishBeforeStart_returnsNothingAndOpensNoSocket() async throws {
        for provider in try Self.providers() {
            let harness = provider.make()
            let result = await harness.client.finishAndWait()
            XCTAssertNil(result, provider.name)
            XCTAssertEqual(harness.factory.sockets.count, 0, provider.name)
        }
    }

    /// Audio leaves one frame at a time: nothing else is handed to the
    /// transport until the frame in flight completes, and every admitted frame
    /// is eventually sent in order.
    func testAudioIsSentOneFrameAtATime() async throws {
        for provider in try Self.providers() {
            let harness = provider.make()
            harness.start()
            try harness.becomeReady()
            let socket = harness.socket
            drainSends(socket)
            let before = socket.sent.count
            for fill in UInt8(1)...3 { harness.client.sendAudio(Data(repeating: fill, count: provider.chunkBytes)) }
            XCTAssertEqual(socket.sent.count, before + 1, "\(provider.name): one frame in flight")
            XCTAssertEqual(socket.pendingSends, 1, provider.name)
            socket.completeSend()
            XCTAssertEqual(socket.sent.count, before + 2, "\(provider.name): next frame after completion")
            XCTAssertEqual(socket.pendingSends, 1, provider.name)
            drainSends(socket)
            XCTAssertGreaterThanOrEqual(socket.sent.count, before + 3, provider.name)
            XCTAssertEqual(socket.pendingSends, 0, provider.name)
            harness.client.cancel()
        }
    }

    /// A finish requested from an already-cancelled task closes the session at
    /// once and returns instead of waiting for the provider.
    func testFinishFromACancelledTask_closesTheSessionAndReturns() async throws {
        for provider in try Self.providers() {
            let harness = provider.make()
            harness.start()
            try harness.becomeReady()
            drainSends(harness.socket)
            let client = harness.client
            let finish = Task { () -> String? in
                while !Task.isCancelled { await Task.yield() }
                return await client.finishAndWait()
            }
            finish.cancel()
            _ = await finish.value
            XCTAssertGreaterThanOrEqual(harness.socket.cancels, 1, provider.name)
        }
    }

    /// Cancelling the task that waits on a finish closes the session and
    /// resumes that waiter, without any provider frame.
    func testCancellingAWaitingFinish_closesTheSessionAndResumesTheWaiter() async throws {
        for provider in try Self.providers() {
            let harness = provider.make()
            harness.start()
            try harness.becomeReady()
            drainSends(harness.socket)
            harness.client.sendAudio(Data(repeating: 9, count: provider.chunkBytes))
            let armed = harness.clock.count
            let finish = FinishProbe(harness.client)
            await waitUntil("\(provider.name) finish registered") { harness.clock.count > armed }
            finish.task.cancel()
            await waitUntil("\(provider.name) cancelled finish returned") { finish.returned }
            XCTAssertGreaterThanOrEqual(harness.socket.cancels, 1, provider.name)
            await finish.settle(harness.client)
        }
    }

    /// Concurrent finish callers share one bounded outcome: when every armed
    /// deadline elapses without a provider answer, both return the same value.
    func testDeadlinesBoundEveryFinishWaiter() async throws {
        for provider in try Self.providers() {
            let harness = provider.make()
            harness.start()
            try harness.becomeReady()
            drainSends(harness.socket)
            harness.client.sendAudio(Data(repeating: 5, count: provider.chunkBytes))
            let armed = harness.clock.count
            let first = FinishProbe(harness.client)
            await waitUntil("\(provider.name) first finish registered") { harness.clock.count > armed }
            let second = FinishProbe(harness.client)
            // The second caller joins on the state queue; give it the chance to.
            for _ in 0..<20 { await Task.yield() }
            for _ in 0..<10 where !harness.clock.isIdle {
                drainSends(harness.socket)
                harness.clock.fireAll()
            }
            await waitUntil("\(provider.name) both finishes returned") { first.returned && second.returned }
            let results = await (first.settle(harness.client), second.settle(harness.client))
            XCTAssertEqual(results.0, results.1, provider.name)
            XCTAssertGreaterThanOrEqual(harness.socket.cancels, 1, provider.name)
        }
    }

    // MARK: - Providers

    struct Provider {
        let name: String
        let chunkBytes: Int
        let make: () -> Harness
    }

    final class Harness: @unchecked Sendable {
        let factory: AssemblyAISocketFactory
        let clock: ContractClock
        let events = AssemblyAITestEvents()
        let client: any FinalizingStreamingTranscriptionClient
        private let ready: (AssemblyAITestSocket) throws -> Void

        var socket: AssemblyAITestSocket { factory.sockets[0] }

        private init(
            factory: AssemblyAISocketFactory, clock: ContractClock,
            client: any FinalizingStreamingTranscriptionClient,
            ready: @escaping (AssemblyAITestSocket) throws -> Void
        ) {
            self.factory = factory
            self.clock = clock
            self.client = client
            self.ready = ready
        }

        static func make(
            _ build: (AssemblyAISocketFactory, ContractClock) -> any FinalizingStreamingTranscriptionClient,
            ready: @escaping (AssemblyAITestSocket) throws -> Void
        ) -> Harness {
            let factory = AssemblyAISocketFactory(), clock = ContractClock()
            return Harness(factory: factory, clock: clock, client: build(factory, clock), ready: ready)
        }

        func start() {
            client.start(onTranscript: { [events] in events.transcript($0, final: $1) },
                         onError: { [events] in events.fail($0) })
        }

        func becomeReady() throws { try ready(socket) }
    }

    // swiftlint:disable:next function_body_length
    static func providers() throws -> [Provider] {
        let alibabaCredentials = try AlibabaSpeechConfiguration(
            region: .singapore, workspace: "llm-example", apiKey: "synthetic"
        ).encodedCredentials()
        func schedule(_ clock: ContractClock) -> @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void {
            { clock.schedule($0, action: $1) }
        }
        return [
            Provider(name: "AssemblyAI", chunkBytes: 6_400) {
                .make({ factory, clock in AssemblyAILiveClient(
                    apiKey: "synthetic", makeConnection: { factory.make($0) }, schedule: schedule(clock))
                }, ready: { $0.open(); $0.begin() })
            },
            Provider(name: "Deepgram", chunkBytes: 6_400) {
                .make({ factory, clock in DeepgramLiveClient(
                    apiKey: "synthetic", makeConnection: { factory.make($0) }, schedule: schedule(clock))
                }, ready: { $0.open() })
            },
            Provider(name: "ElevenLabs", chunkBytes: 6_400) {
                .make({ factory, clock in ElevenLabsLiveClient(
                    apiKey: "synthetic", makeConnection: { factory.make($0) }, schedule: schedule(clock))
                }, ready: { $0.open(); $0.emit(#"{"message_type":"session_started"}"#) })
            },
            Provider(name: "OpenAIRealtime", chunkBytes: 9_600) {
                .make({ factory, clock in OpenAIRealtimeLiveClient(
                    apiKey: "synthetic", model: "gpt-live-transcribe", language: nil, prompt: nil,
                    sampleRate: 24_000, finalizeBudget: nil,
                    makeConnection: { factory.make($0) }, schedule: schedule(clock))
                }, ready: { $0.open(); $0.completeSend(); $0.acknowledge() })
            },
            Provider(name: "Soniox", chunkBytes: 6_400) {
                .make({ factory, clock in SonioxLiveClient(
                    apiKey: "synthetic", model: "stt-rt-v6", language: nil, sampleRate: 16_000,
                    makeConnection: { factory.make($0) }, schedule: schedule(clock))
                }, ready: { $0.open(); $0.completeSend() })
            },
            Provider(name: "Speechmatics", chunkBytes: 6_400) {
                .make({ factory, clock in SpeechmaticsLiveClient(
                    apiKey: "synthetic", model: "enhanced", language: nil, sampleRate: 16_000,
                    makeConnection: { factory.make($0) }, schedule: schedule(clock))
                }, ready: { $0.open(); $0.completeSend(); $0.recognitionStarted() })
            },
            Provider(name: "XAISpeechToText", chunkBytes: 9_600) {
                .make({ factory, clock in XAISpeechToTextLiveClient(
                    apiKey: "synthetic", language: nil, keywords: [], sampleRate: 24_000,
                    makeConnection: { factory.make($0) }, schedule: schedule(clock))
                }, ready: { $0.open(); $0.transcriptCreated() })
            },
            Provider(name: "AzureVoice", chunkBytes: 9_600) {
                .make({ factory, clock in AzureVoiceLiveClient(
                    credentials: AzureVoiceLiveFixture.credentials, endpoint: AzureVoiceLiveFixture.endpoint,
                    model: "azure-speech", language: nil, sampleRate: 24_000,
                    makeConnection: { factory.make($0) }, schedule: schedule(clock))
                }, ready: { $0.open(); $0.completeSend(); $0.acknowledge(sessionType: nil) })
            },
            Provider(name: "AlibabaFunASR", chunkBytes: 6_400) {
                .make({ factory, clock in AlibabaFunASRLiveClient(
                    credentials: alibabaCredentials, makeConnection: { factory.make($0) }, schedule: schedule(clock))
                }, ready: { socket in
                    socket.open()
                    socket.completeSend()
                    let control = try XCTUnwrap(socket.controls.first)
                    let object = try XCTUnwrap(
                        JSONSerialization.jsonObject(with: Data(control.utf8)) as? [String: Any])
                    let taskID = try XCTUnwrap((object["header"] as? [String: Any])?["task_id"] as? String)
                    socket.emit(#"{"header":{"event":"task-started","task_id":"\#(taskID)"}}"#)
                })
            },
            Provider(name: "MistralVoxtral", chunkBytes: 6_400) {
                .make({ factory, clock in MistralVoxtralLiveClient(
                    apiKey: "synthetic", sampleRate: 16_000,
                    makeConnection: { factory.make($0) }, schedule: schedule(clock))
                }, ready: { $0.open(); $0.sessionCreated(); $0.completeSend() })
            },
            Provider(name: "Cartesia", chunkBytes: 6_400) {
                .make({ factory, clock in CartesiaLiveClient(
                    apiKey: "synthetic", makeConnection: { factory.make($0) }, schedule: schedule(clock))
                }, ready: { $0.open() })
            },
            Provider(name: "RevAI", chunkBytes: 6_400) {
                .make({ factory, clock in RevAILiveClient(
                    accessToken: "synthetic", makeConnection: { factory.make($0) }, schedule: schedule(clock))
                }, ready: { $0.open(); $0.emit(#"{"type":"connected","id":"synthetic"}"#) })
            }
        ]
    }

    // MARK: - Support

    /// Completes every send the client has handed over, including sends that
    /// a completion releases.
    private func drainSends(_ socket: AssemblyAITestSocket) {
        for _ in 0..<1_000 where socket.pendingSends > 0 { socket.completeSend() }
    }

    private func waitUntil(_ description: String, _ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out: \(description)")
    }
}

/// A `finishAndWait()` call whose return is observable without awaiting it,
/// so a contract violation fails the test instead of hanging it.
final class FinishProbe: Sendable {
    private let outcome = Outcome()
    let task: Task<String?, Never>

    init(_ client: any FinalizingStreamingTranscriptionClient) {
        let outcome = outcome
        task = Task {
            let result = await client.finishAndWait()
            outcome.record(result)
            return result
        }
    }

    var returned: Bool { outcome.returned }

    /// The finish's result; a finish still waiting is released by cancelling
    /// the client first, so a failed contract never blocks the suite.
    func settle(_ client: any FinalizingStreamingTranscriptionClient) async -> String? {
        if !returned { client.cancel() }
        return await task.value
    }

    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String??
        var returned: Bool { lock.withLock { value != nil } }
        func record(_ result: String?) { lock.withLock { value = .some(result) } }
    }
}

/// A manual clock that records every deadline a client arms.
final class ContractClock: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [@Sendable () -> Void] = []

    /// Deadlines armed and not yet fired.
    var count: Int { lock.withLock { actions.count } }
    var isIdle: Bool { lock.withLock { actions.isEmpty } }

    func schedule(_ seconds: TimeInterval, action: @escaping @Sendable () -> Void) {
        lock.withLock { actions.append(action) }
    }

    /// Fires every armed deadline once; deadlines they arm wait for the next call.
    func fireAll() {
        let due = lock.withLock { let due = actions; actions = []; return due }
        due.forEach { $0() }
    }
}
