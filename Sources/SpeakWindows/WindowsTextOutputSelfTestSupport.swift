import Foundation
import SpeakCore
import SpeakDesktop
import SpeakWindowsPlatform

// Synthetic effects for the executable's text output self-test only. None of
// them reaches a microphone, credential store, network, clipboard or field.

struct SelfTestOutput: Equatable {
    let clipboard: Bool
    let text: String
    /// Nil while the output is held.
    var delivered: Bool?
}

final class SyntheticEffects: WindowsControllerEffects, @unchecked Sendable {
    static let batchText = "Synthetic batch transcript"
    static let liveText = "Synthetic live transcript"
    static let samples: [Int16] = (0..<1_600).map { Int16(($0 % 32) * 256 - 4_000) }
    let transcription = SelfTestGate(open: true)
    let liveFinish = SelfTestGate(open: true)
    let delivery = SelfTestSwitch()
    private let lock = NSLock()
    private var outputs: [SelfTestOutput] = []
    private var clipboard: WindowsClipboardOutput?
    private var failWrite = false
    private var requests: [WindowsTranscriptionRequest] = []
    private var scripted: [Result<String, WindowsNativeError>] = []

    var lastOutput: SelfTestOutput? { lock.withLock { outputs.last } }
    var completedOutputs: Int { lock.withLock { outputs.filter { $0.delivered != nil }.count } }
    var heldOutputs: Int { lock.withLock { outputs.filter { $0.delivered == nil }.count } }
    var lastClipboard: WindowsClipboardOutput? { lock.withLock { clipboard } }
    /// Every batch request that reached transcription, oldest first.
    var transcriptionRequests: [WindowsTranscriptionRequest] { lock.withLock { requests } }

    func failNextSettingsWrite() { lock.withLock { failWrite = true } }

    /// The next transcription returns `text` instead of `batchText`.
    func scriptNextTranscription(_ text: String) { lock.withLock { scripted.append(.success(text)) } }

    /// The next transcription fails with `message`, as a provider or runtime would.
    func failNextTranscription(_ message: String) {
        lock.withLock { scripted.append(.failure(WindowsNativeError(message: message))) }
    }

    func releaseAll() {
        transcription.open()
        liveFinish.open()
        delivery.open()
    }

    static func wave() throws -> Data {
        let pcm = samples.withUnsafeBytes { Data($0) }
        guard let wave = PCMWaveWriter.wavData(pcm: pcm, sampleRate: 16_000) else {
            throw selfTestFailure("the import fixture could not be written")
        }
        return wave
    }

    func apiKey(name: String) throws -> String { "synthetic-self-test-credential" }

    func makeCapture(
        context: WindowsCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any WindowsRecordingCapture { SyntheticCapture(context: context) }

    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? { SyntheticLiveClient(finish: liveFinish) }

    func transcribe(
        _ request: WindowsTranscriptionRequest, with controller: WindowsAppController
    ) async throws -> TranscriptionResult {
        await transcription.pass()
        try Task.checkCancellation()
        let outcome = lock.withLock { () -> Result<String, WindowsNativeError> in
            requests.append(request)
            return scripted.isEmpty ? .success(Self.batchText) : scripted.removeFirst()
        }
        let text = try outcome.get()
        return TranscriptionResult(
            text: text, segments: [], confidence: nil, duration: request.duration,
            modelIdentifier: request.model, cost: nil, rawPayload: nil, debugInfo: nil
        )
    }

    /// Holds the output like a slow target application until released or
    /// cancelled. Never touches the clipboard or a field.
    func perform(_ job: WindowsOutputJob, text: String) -> String {
        let index = lock.withLock { () -> Int in
            var copies = false
            if case .clipboard(let output) = job {
                clipboard = output
                copies = true
            }
            outputs.append(SelfTestOutput(clipboard: copies, text: text, delivered: nil))
            return outputs.count - 1
        }
        let deadline = Date().addingTimeInterval(10)
        while !Task.isCancelled, !delivery.isOpen, Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
        let delivered = !Task.isCancelled && delivery.isOpen
        lock.withLock { outputs[index].delivered = delivered }
        return delivered ? "Synthetic output delivered." : "Synthetic output cancelled."
    }

    func writeSettings(_ data: Data, to url: URL) throws {
        let fail = lock.withLock { () -> Bool in
            let fail = failWrite
            failWrite = false
            return fail
        }
        if fail { throw selfTestFailure("synthetic settings write failure") }
        try data.write(to: url, options: .atomic)
    }
}

/// Signal-bearing PCM through the production capture callback, so the
/// recording file and any live session receive it as they would from WASAPI.
final class SyntheticCapture: WindowsRecordingCapture {
    private let context: WindowsCaptureContext

    init(context: WindowsCaptureContext) { self.context = context }

    func start() throws {
        SyntheticEffects.samples.withUnsafeBufferPointer {
            captureAudio($0.baseAddress, $0.count, Unmanaged.passUnretained(context).toOpaque())
        }
    }

    func stop() throws {}

    func destroy() {}
}

final class SyntheticLiveClient: FinalizingStreamingTranscriptionClient {
    let finalShape = TranscriptFinalShape.standaloneSegments
    private let finish: SelfTestGate

    init(finish: SelfTestGate) { self.finish = finish }

    func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {}

    func sendAudio(_ audioData: Data) {}

    func stop() {}

    func finishAndWait() async -> String? {
        await finish.pass()
        return SyntheticEffects.liveText
    }
}

/// Suspends asynchronous callers while closed and counts arrivals.
final class SelfTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen: Bool
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(open: Bool = false) { isOpen = open }

    var arrivals: Int { lock.withLock { count } }

    func pass() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let proceed = lock.withLock { () -> Bool in
                count += 1
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if proceed { continuation.resume() }
        }
    }

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        pending.forEach { $0.resume() }
    }

    func close() { lock.withLock { isOpen = false } }
}

final class SelfTestSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isOpen: Bool { lock.withLock { value } }

    func open() { lock.withLock { value = true } }

    func close() { lock.withLock { value = false } }
}

func selfTestFailure(_ message: String) -> WindowsNativeError {
    WindowsNativeError(message: "Text output self-test: \(message).")
}
