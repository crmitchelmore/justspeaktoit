import Foundation
import SpeakCore

/// Live use of the host's downloaded whisper.cpp models.
///
/// Live identifiers are the Mac's `local/streaming/whisperkit/...` values, so
/// a selection, profile or History record names the same model on every
/// platform. Only pinned catalogue models the host executes are offered; the
/// batch model's verified file and runtime do the work.
public enum DesktopLocalStreaming {
    public static func liveModelID(for model: WhisperCppModel) -> String {
        LocalModelIdentity.whisperLiveModelID(forBatchModelID: model.catalogueID)
    }

    /// Picker options in catalogue order, one per executable batch model.
    public static func options(host: LocalModelHostSupport) -> [ModelCatalog.Option] {
        DesktopLocalTranscription.models(host: host).map { model in
            ModelCatalog.Option(
                id: liveModelID(for: model),
                displayName: model.displayName + " (on-device, live)",
                description: model.summary,
                latencyTier: .fast,
                tags: [.privacy]
            )
        }
    }

    /// The batch catalogue identifier a live identifier streams with.
    public static func batchModelID(forLiveModelID identifier: String) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return LocalModelIdentity.whisperBatchModelID(fromLiveModelID: trimmed)
    }

    public static func model(forLiveID identifier: String, host: LocalModelHostSupport) -> WhisperCppModel? {
        guard let batch = batchModelID(forLiveModelID: identifier) else { return nil }
        return DesktopLocalTranscription.model(for: batch, host: host)
    }

    /// History keeps the friendly name even if a host stops offering it.
    public static func displayName(for identifier: String) -> String? {
        guard let batch = batchModelID(forLiveModelID: identifier),
              let model = WhisperCppModels.model(forCatalogueID: batch) else { return nil }
        return model.displayName + " (on-device, live)"
    }
}

/// Streams a downloaded Whisper model by re-recognising a bounded window of
/// recent speech in process.
///
/// Capture only converts and appends samples; recognition runs on one worker
/// task. While speech continues the window is re-recognised about once a
/// second and reported as interim text. A pause, or a window reaching its
/// limit, commits the window as a standalone final. Finishing recognises what
/// remains and returns the whole session. Silence never reaches the model, so
/// a silent recording stays empty. At most three windows wait behind recognition;
/// overflowing that backlog terminates live recognition with an explicit error.
public final class DesktopLocalStreamingClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable { // swiftlint:disable:this type_body_length line_length
    public struct Tuning: Sendable, Equatable {
        public var sampleRate: Int
        /// Audio after speech starts between interim passes.
        public var interimInterval: TimeInterval
        /// Quiet after speech that commits the window.
        public var commitSilence: TimeInterval
        /// Longest window recognised at once; longer speech commits early.
        public var maximumWindow: TimeInterval
        /// Quiet audio kept before speech so its first syllable is not clipped.
        public var preRoll: TimeInterval
        /// RMS of a 20 ms frame treated as speech. Windows whose peak stays
        /// below it are never recognised, matching `DesktopLocalAudio.isSilent`.
        public var speechThreshold: Float

        public init(
            sampleRate: Int = 16_000, interimInterval: TimeInterval = 1.0, commitSilence: TimeInterval = 0.6,
            maximumWindow: TimeInterval = 20, preRoll: TimeInterval = 0.3, speechThreshold: Float = 0.003
        ) {
            self.sampleRate = sampleRate
            self.interimInterval = interimInterval
            self.commitSilence = commitSilence
            self.maximumWindow = maximumWindow
            self.preRoll = preRoll
            self.speechThreshold = speechThreshold
        }
    }

    private enum Work {
        case interim([Float])
        case commit([Float])
    }

    private struct CloseAction {
        let task: Task<Void, Never>?
        let signal: AsyncStream<Void>.Continuation?
        let report: ((Error) -> Void)?
    }

    public let finalShape = TranscriptFinalShape.standaloneSegments

    private let recognizer: any DesktopLocalRecognizer
    private let model: WhisperCppModel
    private let modelFile: URL
    private let language: String?
    private let tuning: Tuning
    private let interimSamples: Int
    private let commitSamples: Int
    private let maximumSamples: Int
    private let maximumPendingSamples: Int
    private let preRollSamples: Int

    private let lock = NSLock()
    private var pending: [Float] = []
    private var hasSpeech = false
    private var trailingSilence = 0
    private var frameEnergy: Float = 0
    private var frameCount = 0
    private var noiseFloor: Float = 0.001
    private var samplesSinceInterim = 0
    private var showingInterim = false
    private var finals: [String] = []
    private var onTranscript: ((String, Bool) -> Void)?
    private var onError: ((Error) -> Void)?
    private var wake: AsyncStream<Void>.Continuation?
    private var worker: Task<Void, Never>?
    private var finishing = false
    private var closed = false

    public init(
        recognizer: any DesktopLocalRecognizer, model: WhisperCppModel, modelFile: URL, language: String?,
        tuning: Tuning = Tuning()
    ) {
        self.recognizer = recognizer
        self.model = model
        self.modelFile = modelFile
        self.language = DesktopLocalTranscription.whisperLanguage(language)
        self.tuning = tuning
        let rate = Double(max(tuning.sampleRate, 1))
        interimSamples = max(1, Int(tuning.interimInterval * rate))
        commitSamples = max(1, Int(tuning.commitSilence * rate))
        let windowSamples = max(tuning.sampleRate, Int(tuning.maximumWindow * rate))
        maximumSamples = windowSamples
        maximumPendingSamples = windowSamples * 3
        preRollSamples = max(0, Int(tuning.preRoll * rate))
    }

    deinit {
        wake?.finish()
        worker?.cancel()
    }

    public func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        lock.withLock {
            guard worker == nil, !closed, !finishing else { return }
            self.onTranscript = onTranscript
            self.onError = onError
            let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            wake = continuation
            worker = Task.detached(priority: .userInitiated) { [self] in await self.run(stream) }
        }
    }

    /// Linear16 mono PCM at `Tuning.sampleRate`. Never recognises here.
    public func sendAudio(_ audioData: Data) {
        let count = audioData.count / 2
        guard count > 0 else { return }
        guard lock.withLock({ worker != nil && !closed && !finishing }) else { return }
        guard count <= maximumPendingSamples else {
            close(error: DesktopLocalTranscriptionError.streamingBacklogExceeded)
            return
        }
        var samples = [Float]()
        samples.reserveCapacity(count)
        audioData.withUnsafeBytes { raw in
            for index in 0..<count {
                let bits = UInt16(raw[index * 2]) | UInt16(raw[index * 2 + 1]) << 8
                samples.append(Float(Int16(bitPattern: bits)) / 32_768)
            }
        }
        let admission: (signal: AsyncStream<Void>.Continuation?, overflow: Bool) = lock.withLock {
            guard worker != nil, !closed, !finishing else { return (nil, false) }
            guard count <= maximumPendingSamples - pending.count else { return (nil, true) }
            pending.append(contentsOf: samples)
            detectSpeech(in: samples)
            guard hasSpeech else {
                if pending.count > preRollSamples { pending.removeFirst(pending.count - preRollSamples) }
                return (nil, false)
            }
            samplesSinceInterim += count
            let due = trailingSilence >= commitSamples || pending.count >= maximumSamples
                || samplesSinceInterim >= interimSamples
            return (due ? wake : nil, false)
        }
        if admission.overflow {
            close(error: DesktopLocalTranscriptionError.streamingBacklogExceeded)
        } else {
            admission.signal?.yield(())
        }
    }

    /// Caller holds the lock. A 20 ms frame is speech when its RMS clears both
    /// the absolute threshold and a noise floor that falls at once to quiet
    /// frames and rises over about ten seconds, so steady room noise does not
    /// hold a window open.
    private func detectSpeech(in samples: [Float]) {
        let frameSize = max(1, tuning.sampleRate / 50)
        for sample in samples {
            frameEnergy += sample * sample
            frameCount += 1
            guard frameCount == frameSize else { continue }
            let rms = (frameEnergy / Float(frameSize)).squareRoot()
            frameEnergy = 0
            frameCount = 0
            if rms >= max(tuning.speechThreshold, noiseFloor * 3) {
                hasSpeech = true
                trailingSilence = 0
            } else {
                trailingSilence += frameSize
            }
            noiseFloor = rms < noiseFloor ? rms : noiseFloor + (rms - noiseFloor) * 0.002
        }
    }

    public var finishFlushesBufferedAudio: Bool { true }

    public func finishAndWait() async -> String? {
        let task: Task<Void, Never>? = lock.withLock {
            guard !closed else { return nil }
            finishing = true
            wake?.finish()
            wake = nil
            return worker
        }
        await task?.value
        return lock.withLock { finals.isEmpty ? nil : finals.joined(separator: " ") }
    }

    public func stop() { close() }

    public func cancel() { close() }

    private func close(error: Error? = nil) {
        let completion: CloseAction? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            pending.removeAll()
            let current = CloseAction(task: worker, signal: wake, report: onError)
            onTranscript = nil
            onError = nil
            wake = nil
            return current
        }
        guard let completion else { return }
        completion.signal?.finish()
        completion.task?.cancel()
        if let error { completion.report?(error) }
    }

    // MARK: - Worker

    private func run(_ stream: AsyncStream<Void>) async {
        do {
            for await _ in stream {
                while let work = lock.withLock({ nextWork() }) {
                    try Task.checkCancellation()
                    try await perform(work)
                }
            }
            try Task.checkCancellation()
            try await drain()
        } catch is CancellationError {
            return
        } catch {
            close(error: error)
        }
    }

    /// Caller holds the lock.
    private func nextWork() -> Work? {
        guard hasSpeech, !closed, !finishing else { return nil }
        if trailingSilence >= commitSamples || pending.count >= maximumSamples {
            return .commit(takeWindow())
        }
        guard samplesSinceInterim >= interimSamples else { return nil }
        samplesSinceInterim = 0
        return .interim(pending)
    }

    /// Caller holds the lock. Removes the next window to commit, splitting a
    /// window that reached its limit at its quietest recent moment.
    private func takeWindow() -> [Float] {
        let count = pending.count > maximumSamples ? quietSplit(before: maximumSamples) : pending.count
        let window = Array(pending.prefix(count))
        pending.removeFirst(count)
        if pending.isEmpty {
            hasSpeech = false
            trailingSilence = 0
        } else {
            trailingSilence = min(trailingSilence, pending.count)
        }
        samplesSinceInterim = pending.count
        return window
    }

    /// Caller holds the lock. The end of the quietest 100 ms frame in the last
    /// quarter of the window, so a word is rarely cut in two.
    private func quietSplit(before limit: Int) -> Int {
        let frame = max(1, tuning.sampleRate / 10)
        var best = limit
        var bestPeak = Float.greatestFiniteMagnitude
        var end = limit
        while end - frame >= limit * 3 / 4 {
            var peak: Float = 0
            for index in (end - frame)..<end { peak = max(peak, abs(pending[index])) }
            if peak < bestPeak {
                bestPeak = peak
                best = end
            }
            end -= frame
        }
        return best
    }

    private func perform(_ work: Work) async throws {
        switch work {
        case .interim(let samples):
            let text = try await recognise(samples)
            let callback: ((String, Bool) -> Void)? = lock.withLock {
                guard !closed, !finishing, !text.isEmpty else { return nil }
                showingInterim = true
                return onTranscript
            }
            callback?(text, false)
        case .commit(let samples):
            let text = try await recognise(samples)
            let callback: ((String, Bool) -> Void)? = lock.withLock {
                guard !closed else { return nil }
                if !text.isEmpty { finals.append(text) }
                // An empty final still clears an interim the window showed.
                guard !text.isEmpty || showingInterim else { return nil }
                showingInterim = false
                return onTranscript
            }
            callback?(text, true)
        }
    }

    /// Recognises the rest after finishing. These finals are returned by
    /// `finishAndWait()` rather than delivered as callbacks.
    private func drain() async throws {
        while true {
            let window: [Float]? = lock.withLock {
                guard !closed, !pending.isEmpty, hasSpeech else {
                    pending.removeAll()
                    return nil
                }
                return takeWindow()
            }
            guard let window else { return }
            try Task.checkCancellation()
            let text = try await recognise(window)
            lock.withLock {
                if !closed, !text.isEmpty { finals.append(text) }
            }
        }
    }

    private func recognise(_ samples: [Float]) async throws -> String {
        guard !DesktopLocalAudio.isSilent(samples, threshold: tuning.speechThreshold) else { return "" }
        var input = samples
        // whisper.cpp drops input shorter than a second; quiet padding is inert.
        if input.count < tuning.sampleRate {
            input.append(contentsOf: repeatElement(Float(0), count: tuning.sampleRate - input.count))
        }
        // swiftlint:disable:next line_length
        let raw = try await recognizer.transcribe(samples: input, modelFile: modelFile, model: model, language: language)
        try Task.checkCancellation()
        return DesktopLocalTranscription.cleanTranscript(raw)
    }
}
