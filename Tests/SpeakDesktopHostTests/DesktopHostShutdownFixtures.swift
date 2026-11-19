import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

/// Opens only when told, whatever cancellation says, like a request or a
/// native call that never checks for it.
final class StubbornLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var arrived: Int { lock.withLock { arrivals } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let passes = lock.withLock { () -> Bool in
                arrivals += 1
                if !opened { waiters.append(continuation) }
                return opened
            }
            if passes { continuation.resume() }
        }
    }

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume() }
    }
}

/// A capture whose stop blocks its thread until released, like an audio
/// device or file system that stalls.
final class StallingCapture: DesktopRecordingCapture, @unchecked Sendable {
    private let synthetic: SyntheticCapture
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stops = 0

    init(context: DesktopCaptureContext) { synthetic = SyntheticCapture(context: context) }

    var stopCalls: Int { lock.withLock { stops } }
    func release() { gate.signal() }

    func start() throws { try synthetic.start() }
    func stop() throws {
        lock.withLock { stops += 1 }
        gate.wait()
    }
    func destroy() {}
}

/// A live provider session that reports one transcript and records when it
/// ends. With `blocksCancellation`, cancelling blocks its thread until
/// `releaseCancellation()`, like a provider stuck tearing down its socket.
final class RecordingLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    let finalShape = TranscriptFinalShape.standaloneSegments
    let finalisationBudget: TimeInterval? = nil
    private let lock = NSLock()
    private let cancellationGate = DispatchSemaphore(value: 0)
    private let blocksCancellation: Bool
    private var ended = false
    var isEnded: Bool { lock.withLock { ended } }

    init(blocksCancellation: Bool = false) { self.blocksCancellation = blocksCancellation }

    func releaseCancellation() { cancellationGate.signal() }

    func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        onTranscript("Words spoken before closing", true)
    }
    func sendAudio(_ audioData: Data) {}
    func stop() { lock.withLock { ended = true } }
    func cancel() {
        if blocksCancellation { cancellationGate.wait() }
        stop()
    }
    func finishAndWait() async -> String? {
        stop()
        return nil
    }
}

/// Transcription that ignores cancellation and answers once its latch opens.
final class StubbornEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakePlatform
    let latch = StubbornLatch()
    private let lock = NSLock()
    private var performed: [String] = []
    private var stalling: StallingCapture?
    private var stallsNextCapture = false
    private var live: RecordingLiveClient?
    /// Served to the next live recording, when set.
    var liveClient: RecordingLiveClient? {
        get { lock.withLock { live } }
        set { lock.withLock { live = newValue } }
    }
    var outputs: [String] { lock.withLock { performed } }
    /// The last capture made after `stallNextCapture()`.
    var stalledCapture: StallingCapture? { lock.withLock { stalling } }
    func stallNextCapture() { lock.withLock { stallsNextCapture = true } }

    func apiKey(name: String) throws -> String { FakeLog.shared.key(name) }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture {
        lock.withLock { () -> any DesktopRecordingCapture in
            guard stallsNextCapture else { return SyntheticCapture(context: context) }
            stallsNextCapture = false
            let capture = StallingCapture(context: context)
            stalling = capture
            return capture
        }
    }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? { liveClient }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult {
        await latch.wait()
        return TranscriptionResult(
            text: "Late transcript", segments: [], confidence: nil, duration: request.duration,
            modelIdentifier: request.model, cost: nil, rawPayload: nil, debugInfo: nil
        )
    }
    func perform(_ job: FakeJob, text: String) -> DesktopTextOutputResult {
        lock.withLock { performed.append(text) }
        return DesktopTextOutputResult(.confirmedInsertion, status: "Delivered.")
    }
    func writeSettings(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }
}

/// The report `close()` returned, once it has.
final class ClosedReport: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DesktopHostShutdownReport?
    var value: DesktopHostShutdownReport? { lock.withLock { stored } }
    func set(_ report: DesktopHostShutdownReport) { lock.withLock { stored = report } }
}
