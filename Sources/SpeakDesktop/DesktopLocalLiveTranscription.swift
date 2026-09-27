import Foundation
import SpeakCore

/// Near-real-time on-device transcription: a sliding window over the
/// recording, re-decoded by a whole-utterance recogniser such as whisper.cpp.
///
/// Whisper has no incremental decoder, so the client keeps the audio after the
/// last confirmed segment and decodes that window again whenever at least one
/// step of new audio has arrived and the previous decode has finished (so a
/// slow machine decodes less often instead of falling behind). Each decode is
/// shown as the replaceable hypothesis. An energy voice-activity detector with
/// an adaptive noise floor skips windows without speech and confirms the
/// hypothesis at a pause, emitting it as a final segment and starting a new
/// window there. A window that reaches the maximum length without a pause is
/// cut at its quietest point. Stopping decodes the unconfirmed tail once; an
/// empty tail decode keeps the words already shown, as the Mac's WhisperKit
/// live path does.
///
/// Finals are standalone segments; `finishAndWait()` returns the whole
/// session's transcript, or nil when nothing was spoken.
public final class DesktopLocalLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    public struct Tuning: Sendable, Equatable {
        /// New audio needed before the window is decoded again.
        public var step: TimeInterval = 1.0
        /// Shortest window worth decoding while recording.
        public var minimumWindow: TimeInterval = 1.0
        /// Longest window before it is cut at its quietest point.
        public var maximumWindow: TimeInterval = 20
        /// Trailing silence after speech that confirms the hypothesis.
        public var pause: TimeInterval = 0.7
        /// Speech kept before the first speech frame of a window.
        public var preRoll: TimeInterval = 0.2
        /// RMS never treated as speech, about -48 dBFS.
        public var minimumSpeechLevel: Float = 0.004
        /// Speech must exceed the noise floor by this factor.
        public var noiseFloorFactor: Float = 2.5
        /// The adaptive threshold never rises above this RMS (about -36 dBFS),
        /// so steady speech cannot raise the floor until it hides itself.
        public var maximumSpeechThreshold: Float = 0.015

        public init() {}

        public static let `default` = Tuning()
    }

    public static let sampleRate = 16_000
    static let frameSamples = 480 // 30 ms

    public let finalShape = TranscriptFinalShape.standaloneSegments
    public var finishFlushesBufferedAudio: Bool { true }

    private let model: WhisperCppModel
    private let modelFile: URL
    private let language: String?
    private let recognizer: DesktopLocalRecognizer
    private let tuning: Tuning

    private let lock = NSLock()
    /// Samples from absolute index `bufferStart`; everything before is confirmed.
    private var buffer: [Float] = []
    private var bufferStart = 0
    private var decodedThrough = 0
    private var hypothesis = ""
    private var committed = TranscriptAccumulator(shape: .standaloneSegments)
    private var noise = NoiseFloor()
    private var onTranscript: ((String, Bool) -> Void)?
    private var onError: ((Error) -> Void)?
    private var worker: Task<Void, Never>?
    private var wake: AsyncStream<Void>.Continuation?
    private var finishing = false
    private var stopped = false
    private var failed = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var working = false
    private var workerDone = false
    private var slowest: TimeInterval = 0
    private var decodes = 0
    /// The longest decode so far, for diagnostics and the CI qualification.
    public var slowestDecode: TimeInterval { lock.withLock { slowest } }
    public var decodeCount: Int { lock.withLock { decodes } }

    public init(
        model: WhisperCppModel, modelFile: URL, language: String?, recognizer: DesktopLocalRecognizer,
        tuning: Tuning = .default
    ) {
        self.model = model
        self.modelFile = modelFile
        self.language = DesktopLocalTranscription.whisperLanguage(language)
        self.recognizer = recognizer
        self.tuning = tuning
    }

    deinit { worker?.cancel() }

    public func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let begin = lock.withLock { () -> Bool in
            guard worker == nil, !stopped else { return false }
            self.onTranscript = onTranscript
            self.onError = onError
            wake = continuation
            return true
        }
        guard begin else { return }
        let task = Task { [weak self] in
            for await _ in stream {
                guard let self, await self.decodeIfDue() else { break }
            }
            self?.workerEnded()
        }
        lock.withLock { worker = task }
    }

    /// Linear16 mono little-endian PCM at 16 kHz. Called on the capture
    /// writer thread; it only converts, appends and wakes the worker.
    public func sendAudio(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        var samples = [Float](repeating: 0, count: audioData.count / 2)
        audioData.withUnsafeBytes { raw in
            for index in samples.indices {
                let value = Int16(bitPattern: UInt16(raw[index * 2]) | UInt16(raw[index * 2 + 1]) << 8)
                samples[index] = Float(value) / 32_768
            }
        }
        append(samples)
    }

    /// Appends float samples in [-1, 1]; the entry point for tests and hosts
    /// that already hold floats.
    public func append(_ samples: [Float]) {
        let wake = lock.withLock { () -> AsyncStream<Void>.Continuation? in
            guard !stopped, !finishing else { return nil }
            buffer.append(contentsOf: samples)
            return self.wake
        }
        wake?.yield()
    }

    public func stop() { cancel() }

    public func cancel() {
        let (task, wake, waiters) = lock.withLock { () -> (Task<Void, Never>?, AsyncStream<Void>.Continuation?, [CheckedContinuation<Void, Never>]) in
            stopped = true
            let waiters = idleWaiters
            idleWaiters = []
            return (worker, self.wake, waiters)
        }
        task?.cancel()
        wake?.finish()
        waiters.forEach { $0.resume() }
    }

    public func finishAndWait() async -> String? {
        let (task, wake) = lock.withLock { () -> (Task<Void, Never>?, AsyncStream<Void>.Continuation?) in
            finishing = true
            return (worker, self.wake)
        }
        wake?.finish()
        await task?.value
        let tail = lock.withLock { () -> [Float]? in
            guard !stopped, !failed else { return nil }
            return Array(buffer[max(0, decodedWindowStart() - bufferStart)...])
        }
        if let tail, containsSpeech(tail), Double(tail.count) >= 0.3 * Double(Self.sampleRate) {
            let shown = lock.withLock { hypothesis }
            var text = (try? await decode(tail)) ?? ""
            if text.isEmpty { text = shown }
            lock.withLock {
                committed.append(final: text)
                hypothesis = ""
            }
        } else if tail != nil {
            // A pause already confirmed everything, or only silence remains;
            // a hypothesis still shown is kept rather than dropped.
            lock.withLock {
                committed.append(final: hypothesis)
                hypothesis = ""
            }
        }
        return lock.withLock {
            stopped = true
            return committed.transcriptOrNil
        }
    }

    private func workerEnded() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            workerDone = true
            let waiters = idleWaiters
            idleWaiters = []
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    /// Resumes once the worker has handled all audio appended so far.
    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if stopped || finishing || workerDone || (!working && !isDue()) { return true }
                idleWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    // MARK: - Worker

    /// The first sample of the unconfirmed window. Caller holds the lock.
    private func decodedWindowStart() -> Int { bufferStart }

    private func isDue() -> Bool {
        let end = bufferStart + buffer.count
        let newAudio = end - max(decodedThrough, bufferStart)
        return newAudio >= Int(tuning.step * Double(Self.sampleRate))
            && buffer.count >= Int(tuning.minimumWindow * Double(Self.sampleRate))
    }

    /// Decodes the window when enough new audio arrived. Returns false once
    /// the worker must stop.
    private func decodeIfDue() async -> Bool {
        let window = lock.withLock { () -> (samples: [Float], start: Int)? in
            guard !stopped, !finishing, isDue() else { return nil }
            working = true
            decodedThrough = bufferStart + buffer.count
            return (buffer, bufferStart)
        }
        defer { finishWork() }
        guard let window else { return !lock.withLock { stopped } }
        let speech = speechFrames(window.samples)
        guard let firstSpeech = speech.firstIndex(of: true) else {
            // No speech: keep only a short pre-roll so the window stays small.
            confirm(through: window.start + max(0, window.samples.count - preRollSamples), text: nil)
            return true
        }
        let lastSpeech = speech.lastIndex(of: true) ?? firstSpeech
        let trailingSilence = Double((speech.count - 1 - lastSpeech) * Self.frameSamples) / Double(Self.sampleRate)
        let leading = max(0, firstSpeech * Self.frameSamples - preRollSamples)
        let maximum = Int(tuning.maximumWindow * Double(Self.sampleRate))
        do {
            if trailingSilence >= tuning.pause {
                let text = try await decode(Array(window.samples[leading...]))
                confirm(through: window.start + window.samples.count - preRollSamples, text: text)
            } else if window.samples.count >= maximum {
                let cut = quietestFrame(in: window.samples, from: max(leading, window.samples.count / 2))
                let text = try await decode(Array(window.samples[leading..<cut]))
                confirm(through: window.start + cut, text: text)
            } else {
                let text = try await decode(Array(window.samples[leading...]))
                show(text)
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            report(error)
            return false
        }
    }

    private var preRollSamples: Int { Int(tuning.preRoll * Double(Self.sampleRate)) }

    private func finishWork() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            working = false
            guard !isDue() || stopped || finishing else { return [] }
            let waiters = idleWaiters
            idleWaiters = []
            return waiters
        }
        waiters.forEach { $0.resume() }
        // Audio that arrived during the decode may already make the next one due.
        let wake = lock.withLock { isDue() && !stopped && !finishing ? self.wake : nil }
        wake?.yield()
    }

    private func decode(_ samples: [Float]) async throws -> String {
        try Task.checkCancellation()
        let started = Date()
        let raw = try await recognizer.transcribe(
            samples: samples, modelFile: modelFile, model: model, language: language
        )
        let elapsed = Date().timeIntervalSince(started)
        lock.withLock {
            slowest = max(slowest, elapsed)
            decodes += 1
        }
        return DesktopLocalTranscription.cleanTranscript(raw)
    }

    private func show(_ text: String) {
        let callback = lock.withLock { () -> ((String, Bool) -> Void)? in
            guard !stopped, text != hypothesis else { return nil }
            hypothesis = text
            return onTranscript
        }
        callback?(text, false)
    }

    /// Confirms `text` (when any) and drops the audio before `absolute`.
    private func confirm(through absolute: Int, text: String?) {
        let callback = lock.withLock { () -> ((String, Bool) -> Void)? in
            guard !stopped else { return nil }
            let drop = min(max(0, absolute - bufferStart), buffer.count)
            buffer.removeFirst(drop)
            bufferStart += drop
            decodedThrough = max(decodedThrough, bufferStart)
            hypothesis = ""
            guard let text, !text.isEmpty else { return nil }
            committed.append(final: text)
            return onTranscript
        }
        if let text, !text.isEmpty { callback?(text, true) }
    }

    private func report(_ error: Error) {
        let callback = lock.withLock { () -> ((Error) -> Void)? in
            guard !stopped, !failed else { return nil }
            failed = true
            return onError
        }
        callback?(error)
    }

    // MARK: - Voice activity

    /// Speech flags per 30 ms frame against an adaptive noise floor.
    func speechFrames(_ samples: [Float]) -> [Bool] {
        let levels = Self.frameLevels(samples)
        let threshold = lock.withLock { () -> Float in
            levels.forEach { noise.observe($0) }
            let adaptive = min(noise.level * tuning.noiseFloorFactor, tuning.maximumSpeechThreshold)
            return max(tuning.minimumSpeechLevel, adaptive)
        }
        // A short hangover bridges the gaps between syllables.
        var flags = levels.map { $0 > threshold }
        var hold = 0
        for index in flags.indices {
            if flags[index] { hold = 5 } else if hold > 0 { flags[index] = true; hold -= 1 }
        }
        return flags
    }

    private func containsSpeech(_ samples: [Float]) -> Bool { speechFrames(samples).contains(true) }

    static func frameLevels(_ samples: [Float]) -> [Float] {
        stride(from: 0, to: samples.count, by: frameSamples).map { start in
            let end = min(start + frameSamples, samples.count)
            var sum: Float = 0
            for index in start..<end { sum += samples[index] * samples[index] }
            return (sum / Float(max(1, end - start))).squareRoot()
        }
    }

    /// The end of the quietest frame at or after `from`, never inside the
    /// last half second, as a sample index into `samples`.
    private func quietestFrame(in samples: [Float], from: Int) -> Int {
        let levels = Self.frameLevels(samples)
        let first = from / Self.frameSamples
        let last = max(first, levels.count - 1 - Int(0.5 * Double(Self.sampleRate)) / Self.frameSamples)
        guard first < levels.count else { return samples.count }
        let index = (first...min(last, levels.count - 1)).min { levels[$0] < levels[$1] } ?? first
        return min(samples.count, (index + 1) * Self.frameSamples)
    }
}

/// A slowly adapting estimate of background level: the 15th percentile of
/// the most recent ten seconds of frame levels.
struct NoiseFloor: Sendable {
    private var recent: [Float] = []
    private var next = 0
    private static let capacity = 333

    var level: Float {
        guard !recent.isEmpty else { return 0 }
        let sorted = recent.sorted()
        return sorted[min(sorted.count - 1, sorted.count * 15 / 100)]
    }

    mutating func observe(_ value: Float) {
        if recent.count < Self.capacity {
            recent.append(value)
        } else {
            recent[next] = value
            next = (next + 1) % Self.capacity
        }
    }
}
