import Foundation

/// The audio a local streaming client has admitted but not yet recognised,
/// and the speech detection that decides when to recognise it. Owned by
/// `DesktopLocalStreamingClient` and only touched under its lock.
struct DesktopLocalSpeechWindow {
    enum Work {
        case interim([Float])
        case commit([Float])
    }

    private let frameSize: Int
    private let splitFrame: Int
    private let speechThreshold: Float
    private let interimSamples: Int
    private let commitSamples: Int
    private let maximumSamples: Int
    private let maximumPendingSamples: Int
    private let preRollSamples: Int

    private(set) var pending: [Float] = []
    private(set) var hasSpeech = false
    private var trailingSilence = 0
    private var frameEnergy: Float = 0
    private var frameCount = 0
    private var noiseFloor: Float = 0.001
    private var samplesSinceInterim = 0

    init(tuning: DesktopLocalStreamingClient.Tuning, maximumPendingSamples: Int) {
        let rate = Double(max(tuning.sampleRate, 1))
        frameSize = max(1, tuning.sampleRate / 50)
        splitFrame = max(1, tuning.sampleRate / 10)
        speechThreshold = tuning.speechThreshold
        interimSamples = max(1, Int(tuning.interimInterval * rate))
        commitSamples = max(1, Int(tuning.commitSilence * rate))
        maximumSamples = Self.windowSamples(for: tuning)
        self.maximumPendingSamples = maximumPendingSamples
        preRollSamples = max(0, Int(tuning.preRoll * rate))
    }

    /// The longest window recognised at once.
    static func windowSamples(for tuning: DesktopLocalStreamingClient.Tuning) -> Int {
        max(tuning.sampleRate, Int(tuning.maximumWindow * Double(max(tuning.sampleRate, 1))))
    }

    /// Admits `samples`. Returns nil when they would overflow the backlog,
    /// otherwise whether a recognition pass is now due. Before speech only
    /// the pre-roll is kept.
    mutating func admit(_ samples: [Float]) -> Bool? {
        guard samples.count <= maximumPendingSamples - pending.count else { return nil }
        pending.append(contentsOf: samples)
        detectSpeech(in: samples)
        guard hasSpeech else {
            if pending.count > preRollSamples { pending.removeFirst(pending.count - preRollSamples) }
            return false
        }
        samplesSinceInterim += samples.count
        return trailingSilence >= commitSamples || pending.count >= maximumSamples
            || samplesSinceInterim >= interimSamples
    }

    /// The next recognition pass while speech is open: a commit after enough
    /// quiet or at the window limit, otherwise an interim pass when one is due.
    mutating func nextWork() -> Work? {
        guard hasSpeech else { return nil }
        if trailingSilence >= commitSamples || pending.count >= maximumSamples {
            return .commit(takeWindow())
        }
        guard samplesSinceInterim >= interimSamples else { return nil }
        samplesSinceInterim = 0
        return .interim(pending)
    }

    /// Removes the next window to commit, splitting a window that reached its
    /// limit at its quietest recent moment.
    mutating func takeWindow() -> [Float] {
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

    mutating func discard() { pending.removeAll() }

    /// A 20 ms frame is speech when its RMS clears both the absolute threshold
    /// and a noise floor that falls at once to quiet frames and rises over
    /// about ten seconds, so steady room noise does not hold a window open.
    private mutating func detectSpeech(in samples: [Float]) {
        for sample in samples {
            frameEnergy += sample * sample
            frameCount += 1
            guard frameCount == frameSize else { continue }
            let rms = (frameEnergy / Float(frameSize)).squareRoot()
            frameEnergy = 0
            frameCount = 0
            if rms >= max(speechThreshold, noiseFloor * 3) {
                hasSpeech = true
                trailingSilence = 0
            } else {
                trailingSilence += frameSize
            }
            noiseFloor = rms < noiseFloor ? rms : noiseFloor + (rms - noiseFloor) * 0.002
        }
    }

    /// The end of the quietest 100 ms frame in the last quarter of the window,
    /// so a word is rarely cut in two.
    private func quietSplit(before limit: Int) -> Int {
        var best = limit
        var bestPeak = Float.greatestFiniteMagnitude
        var end = limit
        while end - splitFrame >= limit * 3 / 4 {
            var peak: Float = 0
            for index in (end - splitFrame)..<end { peak = max(peak, abs(pending[index])) }
            if peak < bestPeak {
                bestPeak = peak
                best = end
            }
            end -= splitFrame
        }
        return best
    }
}
