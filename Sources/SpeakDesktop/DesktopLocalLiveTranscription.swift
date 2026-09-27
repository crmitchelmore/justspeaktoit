import Foundation
import SpeakCore

/// Near-real-time on-device dictation for desktop hosts that run whisper.cpp.
///
/// whisper.cpp has no streaming decoder, so live text comes from re-decoding a
/// sliding window of recent audio, as upstream's `stream` example does, with
/// an energy voice-activity detector deciding when a phrase is complete:
///
/// - Audio since the last committed phrase is decoded about once a second and
///   shown as a replaceable hypothesis.
/// - When the speaker pauses (`commitSilence`), the decode of that phrase is
///   committed as a final segment and the window restarts after it.
/// - A window with no speech is never decoded, because Whisper invents text for
///   silence; only a short pre-roll is kept.
/// - A phrase longer than `maximumWindow` is cut at its quietest point near the
///   end and committed, so one pass never exceeds Whisper's 30-second input.
/// - Stopping decodes everything after the last commit once more, so the final
///   words are decoded in full context rather than from a partial pass.
///
/// This mirrors the macOS WhisperKit live path's contract (confirmed text is
/// never revised; the stop-time tail decode is authoritative for the rest).
/// Only models `WhisperCppModels` live-qualifies are offered.
public enum DesktopLocalLiveTranscription {
    /// Live picker entries reuse the catalogue identifier with this suffix, so
    /// Batch and Live keep separate picker slots. Hosts store the plain
    /// catalogue identifier in History (`catalogueID(forSelection:)`).
    public static let selectionSuffix = "#live"

    public static func selectionID(for catalogueID: String) -> String { catalogueID + selectionSuffix }

    /// The catalogue identifier behind a live selection, or `nil` for any
    /// other identifier.
    public static func catalogueID(forSelection identifier: String) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasSuffix(selectionSuffix) else { return nil }
        let base = String(trimmed.dropLast(selectionSuffix.count))
        return base.isEmpty ? nil : base
    }

    public static func isLiveSelection(_ identifier: String) -> Bool { catalogueID(forSelection: identifier) != nil }

    /// Live-qualified catalogue models the host runs, in catalogue order.
    public static func models(host: LocalModelHostSupport) -> [WhisperCppModel] {
        DesktopLocalTranscription.models(host: host).filter(\.supportsLiveStreaming)
    }

    public static func options(host: LocalModelHostSupport) -> [ModelCatalog.Option] {
        models(host: host).map { model in
            ModelCatalog.Option(
                id: selectionID(for: model.catalogueID),
                displayName: model.displayName + " (on-device, live)",
                description: model.summary + " Live text appears as you speak.",
                latencyTier: .fast,
                tags: [.privacy, .fast]
            )
        }
    }

    public static func model(forSelection identifier: String, host: LocalModelHostSupport) -> WhisperCppModel? {
        guard let base = catalogueID(forSelection: identifier) else { return nil }
        return models(host: host).first { $0.catalogueID == base.lowercased() }
    }
}

/// Tunables for `DesktopLocalLiveClient`, in seconds unless noted.
public struct DesktopLocalLiveConfiguration: Sendable, Equatable {
    public var sampleRate: Int = 16_000
    /// New audio needed before the next hypothesis pass.
    public var step: Double = 1.0
    /// Speech needed in a window before it is decoded at all.
    public var minimumSpeech: Double = 0.25
    /// A pause this long after speech commits the phrase.
    public var commitSilence: Double = 0.7
    /// Longest window decoded as one phrase before it is cut and committed.
    public var maximumWindow: Double = 20
    /// Audio kept before speech when a silent window is discarded.
    public var preRoll: Double = 0.3
    /// whisper.cpp ignores input shorter than one second; windows are padded
    /// with silence to at least this length.
    public var minimumDecode: Double = 1.1
    /// Poll interval of the decode loop.
    public var poll: Double = 0.05

    public init() {}
}

/// An energy voice-activity detector over 30 ms frames. Its noise floor is the
/// 5th percentile of the last ten seconds of frames, so pauses between words
/// keep it at room level during long speech, and a noisy room raises it.
public struct DesktopEnergyVAD: Sendable, Equatable {
    public static let frameSeconds = 0.03
    static let history = 333
    /// About -49 dBFS: below this nothing counts as speech.
    public var absoluteThreshold: Float = 0.0035
    public var floorMultiplier: Float = 2.5
    private var recent: [Float] = []
    public private(set) var noiseFloor: Float = 0.0002

    public init() {}

    public var threshold: Float { max(absoluteThreshold, noiseFloor * floorMultiplier) }

    /// Frame RMS values for `samples`, dropping a trailing partial frame.
    public static func frameEnergies(_ samples: ArraySlice<Float>, sampleRate: Int) -> [Float] {
        let size = max(1, Int(Double(sampleRate) * frameSeconds))
        var energies: [Float] = []
        energies.reserveCapacity(samples.count / size)
        var start = samples.startIndex
        while start + size <= samples.endIndex {
            var sum: Float = 0
            for value in samples[start..<(start + size)] { sum += value * value }
            energies.append((sum / Float(size)).squareRoot())
            start += size
        }
        return energies
    }

    /// Adds frames heard for the first time and updates the floor.
    public mutating func observe(_ energies: [Float]) {
        guard !energies.isEmpty else { return }
        recent.append(contentsOf: energies)
        if recent.count > Self.history { recent.removeFirst(recent.count - Self.history) }
        let sorted = recent.sorted()
        // The 5th percentile, capped so a floor measured during unbroken
        // speech can never rise above ordinary speech levels (-34 dBFS).
        noiseFloor = min(0.01, max(0.0002, sorted[sorted.count / 20]))
    }

    public func isSpeech(_ energy: Float) -> Bool { energy >= threshold }
}

/// The live client for one on-device recording. Conforms to the shared
/// streaming contract, so `DesktopLiveSession` drives it exactly like a
/// provider: committed phrases are standalone finals, the current window is
/// the interim, and `finishAndWait()` returns the whole transcript.
public final class DesktopLocalLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    /// Decodes 16 kHz mono float samples; throws `CancellationError` when cancelled.
    public typealias Recognize = @Sendable ([Float]) async throws -> String

    public let finalShape = TranscriptFinalShape.standaloneSegments
    public var finishFlushesBufferedAudio: Bool { true }

    private let configuration: DesktopLocalLiveConfiguration
    private let recognize: Recognize
    private let lock = NSLock()
    // Guarded by lock.
    private var samples: [Float] = []
    /// Index in `samples` where the uncommitted window starts.
    private var windowStart = 0
    private var decodedEnd = 0
    private var committed: [String] = []
    private var onTranscript: ((String, Bool) -> Void)?
    private var onError: ((Error) -> Void)?
    private var finishing = false
    private var cancelled = false
    private var worker: Task<Void, Never>?
    private var vad = DesktopEnergyVAD()
    private var observedThrough = 0
    /// Passes run so far and their total decode time, for qualification receipts.
    private var passes = 0
    private var decodeSeconds = 0.0
    private var longestPass = 0.0

    public init(configuration: DesktopLocalLiveConfiguration = .init(), recognize: @escaping Recognize) {
        self.configuration = configuration
        self.recognize = recognize
    }

    deinit { worker?.cancel() }

    public func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        lock.withLock {
            guard worker == nil, !cancelled else { return }
            self.onTranscript = onTranscript
            self.onError = onError
            worker = Task.detached { [weak self] in await self?.run() }
        }
    }

    /// Linear16 little-endian mono PCM at `configuration.sampleRate`.
    public func sendAudio(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        var converted = [Float](repeating: 0, count: audioData.count / 2)
        audioData.withUnsafeBytes { raw in
            for index in converted.indices {
                let value = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                converted[index] = Float(value) / 32_768
            }
        }
        lock.withLock {
            guard !finishing, !cancelled else { return }
            samples.append(contentsOf: converted)
        }
    }

    public func stop() { cancel() }

    public func cancel() {
        let task: Task<Void, Never>? = lock.withLock {
            cancelled = true
            onTranscript = nil
            onError = nil
            return worker
        }
        task?.cancel()
    }

    public func finishAndWait() async -> String? {
        let task: Task<Void, Never>? = lock.withLock {
            finishing = true
            return worker
        }
        await task?.value
        return lock.withLock {
            let text = committed.joined(separator: " ")
            return text.isEmpty ? nil : text
        }
    }

    /// Pass count, mean and longest decode time so far.
    public var statistics: (passes: Int, meanSeconds: Double, longestSeconds: Double) {
        lock.withLock { (passes, passes == 0 ? 0 : decodeSeconds / Double(passes), longestPass) }
    }

    // MARK: - Decode loop

    private enum Next {
        case wait
        case finish(ArraySlice<Float>)
        case decode(ArraySlice<Float>, end: Int)
    }

    private func run() async {
        while !Task.isCancelled {
            switch nextWork() {
            case .wait:
                do { try await Task.sleep(nanoseconds: UInt64(configuration.poll * 1_000_000_000)) } catch { return }
            case .finish(let window):
                if hasSpeech(window) {
                    if let text = await decode(window) { commit(text, through: nil) }
                }
                return
            case .decode(let window, let end):
                guard await pass(window, end: end) else { return }
            }
        }
    }

    private func nextWork() -> Next {
        lock.withLock {
            let rate = configuration.sampleRate
            if finishing { return .finish(samples[windowStart...]) }
            guard samples.count - decodedEnd >= Int(configuration.step * Double(rate)) else { return .wait }
            decodedEnd = samples.count
            return .decode(samples[windowStart..<samples.count], end: samples.count)
        }
    }

    /// One hypothesis pass; false once the client should stop.
    private func pass(_ window: ArraySlice<Float>, end: Int) async -> Bool {
        let rate = configuration.sampleRate
        let energies = DesktopEnergyVAD.frameEnergies(window, sampleRate: rate)
        let vad = lock.withLock { () -> DesktopEnergyVAD in
            // Each frame counts towards the floor once, however many passes see it.
            let frame = max(1, Int(Double(rate) * DesktopEnergyVAD.frameSeconds))
            let unseen = max(0, min(energies.count, (end - max(observedThrough, window.startIndex)) / frame))
            self.vad.observe(Array(energies.suffix(unseen)))
            observedThrough = max(observedThrough, end)
            return self.vad
        }
        let speechFrames = energies.filter(vad.isSpeech).count
        guard Double(speechFrames) * DesktopEnergyVAD.frameSeconds >= configuration.minimumSpeech else {
            // Nothing to say yet: keep only a short pre-roll before any speech.
            lock.withLock {
                windowStart = max(windowStart, end - Int(configuration.preRoll * Double(rate)))
                compact()
            }
            return true
        }
        let trailingSilence = Double(energies.reversed().prefix { !vad.isSpeech($0) }.count)
            * DesktopEnergyVAD.frameSeconds
        let duration = Double(window.count) / Double(rate)
        if trailingSilence >= configuration.commitSilence {
            guard let text = await decode(window) else { return !isStopped }
            commit(text, through: end)
            return true
        }
        if duration >= configuration.maximumWindow {
            let cut = quietestCut(window, energies: energies)
            guard let text = await decode(window[window.startIndex..<cut]) else { return !isStopped }
            commit(text, through: cut)
            return true
        }
        guard let text = await decode(window) else { return !isStopped }
        interim(text)
        return true
    }

    /// The end of the quietest frame in the last quarter of a long window.
    private func quietestCut(_ window: ArraySlice<Float>, energies: [Float]) -> Int {
        let frame = max(1, Int(Double(configuration.sampleRate) * DesktopEnergyVAD.frameSeconds))
        let from = energies.count * 3 / 4
        guard from < energies.count else { return window.endIndex }
        var best = from
        for index in from..<energies.count where energies[index] < energies[best] { best = index }
        return min(window.endIndex, window.startIndex + (best + 1) * frame)
    }

    private func hasSpeech(_ window: ArraySlice<Float>) -> Bool {
        let energies = DesktopEnergyVAD.frameEnergies(window, sampleRate: configuration.sampleRate)
        let vad = lock.withLock { self.vad }
        let speech = Double(energies.filter(vad.isSpeech).count) * DesktopEnergyVAD.frameSeconds
        return speech >= configuration.minimumSpeech
    }

    private var isStopped: Bool { lock.withLock { cancelled } }

    /// Decodes a window, padded to whisper.cpp's minimum input; nil after a
    /// cancellation or a reported failure.
    private func decode(_ window: ArraySlice<Float>) async -> String? {
        var input = Array(window)
        let minimum = Int(configuration.minimumDecode * Double(configuration.sampleRate))
        if input.count < minimum { input.append(contentsOf: repeatElement(0, count: minimum - input.count)) }
        let started = Date()
        do {
            let raw = try await recognize(input)
            let elapsed = Date().timeIntervalSince(started)
            lock.withLock {
                passes += 1
                decodeSeconds += elapsed
                longestPass = max(longestPass, elapsed)
            }
            return DesktopLocalTranscription.cleanTranscript(raw)
        } catch {
            let report: ((Error) -> Void)? = lock.withLock { cancelled || error is CancellationError ? nil : onError }
            report?(error)
            lock.withLock { cancelled = true }
            return nil
        }
    }

    private func interim(_ text: String) {
        let callback = lock.withLock { cancelled || finishing ? nil : onTranscript }
        callback?(text, false)
    }

    /// Commits a phrase and restarts the window at `through` (nil: nothing left).
    private func commit(_ text: String, through end: Int?) {
        let callback: ((String, Bool) -> Void)? = lock.withLock {
            guard !cancelled else { return nil }
            if !text.isEmpty { committed.append(text) }
            windowStart = end ?? samples.count
            decodedEnd = max(decodedEnd, windowStart)
            compact()
            return onTranscript
        }
        if !text.isEmpty { callback?(text, true) } else { callback?("", false) }
    }

    /// Drops committed audio once enough has accumulated. Caller holds lock.
    private func compact() {
        guard windowStart > configuration.sampleRate * 30 else { return }
        samples.removeFirst(windowStart)
        decodedEnd -= windowStart
        observedThrough = max(0, observedThrough - windowStart)
        windowStart = 0
    }
}
