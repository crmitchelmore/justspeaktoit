// The hands-free voice-activity gate: an on-device, energy-based detector that
// decides from raw PCM levels whether someone is speaking. Nothing is
// recognised or transcribed while armed: the gate sees only signal power.
//
// It replaces Apple's SpeechDetector, which cannot run on its own on macOS 27
// (#1553). It is pure Swift with no framework dependencies so it compiles and
// unit-tests on every platform; the Apple microphone adapter lives in
// Capture/Apple/HandsFreeVoiceActivitySession.swift.
import Foundation

/// How eagerly the hands-free voice-activity gate reports speech.
///
/// `high` triggers on quieter speech (and more background noise); `low` needs
/// speech to stand further above the room's noise floor.
public enum AppleSpeechDetectorSensitivity: String, CaseIterable, Sendable, Equatable {
    case low
    case medium
    case high
}

/// One voice-activity report from the hands-free gate.
public struct AppleSpeechActivityUpdate: Sendable, Equatable {
    public let speechDetected: Bool
    /// End of the analysed range, on the session's audio timeline.
    public let seconds: Double

    public init(speechDetected: Bool, seconds: Double) {
        self.speechDetected = speechDetected
        self.seconds = seconds
    }
}

/// Energy-based voice-activity detection with hysteresis, a minimum speech
/// duration and an adaptive noise-floor estimate.
///
/// Audio is split into short frames and each frame's RMS level (dBFS) is
/// compared with the estimated noise floor:
/// - speech starts only after the level has stayed above the *onset* threshold
///   for ``Configuration/minimumSpeechSeconds``, so clicks and taps are ignored;
/// - once speaking, the level must fall below the lower *release* threshold for
///   ``Configuration/releaseHangSeconds`` before speech ends (hysteresis), so
///   the quiet dips between syllables don't end it;
/// - the noise floor follows quiet passages down quickly and rises slowly, at a
///   capped rate, so a noisier room raises the thresholds without loud speech
///   lifting the floor enough to cut off a softer continuation.
///
/// The longer silence hold that ends an utterance stays in
/// ``HandsFreeVoiceActivityTracker``; this type only answers "is someone
/// speaking now?".
public struct HandsFreeEnergyVoiceActivityDetector: Sendable {
    public struct Configuration: Equatable, Sendable {
        /// dB above the noise floor a frame needs to start a speech candidate.
        public var onsetMarginDB: Double
        /// dB above the noise floor a frame needs to keep speech going. Lower
        /// than the onset margin, which is the hysteresis.
        public var releaseMarginDB: Double
        /// Speech never starts below this level, however quiet the room is.
        public var minimumOnsetLevelDB: Double
        /// How long the level must stay up before speech is reported.
        public var minimumSpeechSeconds: Double
        /// How long the level must stay down before speech ends.
        public var releaseHangSeconds: Double
        /// Audio used to seed the noise floor before speech can be reported.
        public var calibrationSeconds: Double
        /// Highest noise floor calibration may seed. Someone already speaking as
        /// the microphone opens would otherwise be learned as room noise and
        /// never trigger; a genuinely louder room is learned as the floor rises.
        public var maximumCalibratedNoiseFloorDB: Double
        /// Time constant for the noise floor rising while nobody speaks.
        public var noiseFloorRiseSeconds: Double
        /// Time constant for the noise floor rising during speech, so a steady
        /// new noise (a fan) eventually stops counting as speech.
        public var noiseFloorRiseWhileSpeakingSeconds: Double
        /// Time constant for the noise floor falling.
        public var noiseFloorFallSeconds: Double
        /// Fastest the noise floor may rise while nobody speaks, in dB/s.
        public var noiseFloorRiseLimitDBPerSecond: Double
        /// Fastest the noise floor may rise during speech, in dB/s.
        public var speechNoiseFloorRiseLimitDBPerSecond: Double
        public var frameSeconds: Double

        public init(
            onsetMarginDB: Double,
            releaseMarginDB: Double,
            minimumOnsetLevelDB: Double,
            minimumSpeechSeconds: Double = 0.12,
            releaseHangSeconds: Double = 0.25,
            calibrationSeconds: Double = 0.2,
            maximumCalibratedNoiseFloorDB: Double = -45,
            noiseFloorRiseSeconds: Double = 4,
            noiseFloorRiseWhileSpeakingSeconds: Double = 8,
            noiseFloorFallSeconds: Double = 0.15,
            noiseFloorRiseLimitDBPerSecond: Double = 3,
            speechNoiseFloorRiseLimitDBPerSecond: Double = 1,
            frameSeconds: Double = 0.02
        ) {
            self.onsetMarginDB = onsetMarginDB
            self.releaseMarginDB = releaseMarginDB
            self.minimumOnsetLevelDB = minimumOnsetLevelDB
            self.minimumSpeechSeconds = minimumSpeechSeconds
            self.releaseHangSeconds = releaseHangSeconds
            self.calibrationSeconds = calibrationSeconds
            self.maximumCalibratedNoiseFloorDB = maximumCalibratedNoiseFloorDB
            self.noiseFloorRiseSeconds = noiseFloorRiseSeconds
            self.noiseFloorRiseWhileSpeakingSeconds = noiseFloorRiseWhileSpeakingSeconds
            self.noiseFloorFallSeconds = noiseFloorFallSeconds
            self.noiseFloorRiseLimitDBPerSecond = noiseFloorRiseLimitDBPerSecond
            self.speechNoiseFloorRiseLimitDBPerSecond = speechNoiseFloorRiseLimitDBPerSecond
            self.frameSeconds = frameSeconds
        }

        public init(sensitivity: AppleSpeechDetectorSensitivity) {
            switch sensitivity {
            case .low:
                self.init(onsetMarginDB: 15, releaseMarginDB: 9, minimumOnsetLevelDB: -50, minimumSpeechSeconds: 0.16)
            case .medium:
                self.init(onsetMarginDB: 11, releaseMarginDB: 6, minimumOnsetLevelDB: -55)
            case .high:
                self.init(onsetMarginDB: 8, releaseMarginDB: 4, minimumOnsetLevelDB: -62, minimumSpeechSeconds: 0.08)
            }
        }
    }

    /// Below this a frame counts as digital silence.
    static let silenceLevelDB: Double = -100

    public let configuration: Configuration

    private var isSpeaking = false
    private var candidateSeconds: Double = 0
    private var belowReleaseSeconds: Double = 0
    private var noiseFloorDB: Double?
    private var calibratedSeconds: Double = 0
    private var timelineSeconds: Double = 0
    private var pendingSumOfSquares: Double = 0
    private var pendingCount = 0

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public init(sensitivity: AppleSpeechDetectorSensitivity = .medium) {
        self.init(configuration: Configuration(sensitivity: sensitivity))
    }

    /// The current noise-floor estimate in dBFS, or `nil` before any audio.
    public var estimatedNoiseFloorDB: Double? { noiseFloorDB }

    /// Feeds mono samples in the range -1...1 and returns one report covering
    /// them, or `nil` when they didn't complete a frame. `speechDetected` is
    /// true when speech was active at any point in the samples, so a brief
    /// utterance inside one large buffer is never lost.
    public mutating func process<Samples: Collection>(
        samples: Samples,
        sampleRate: Double
    ) -> AppleSpeechActivityUpdate? where Samples.Element == Float {
        guard sampleRate > 0, sampleRate.isFinite else { return nil }
        let frameLength = max(1, Int((sampleRate * configuration.frameSeconds).rounded()))
        let frameDuration = Double(frameLength) / sampleRate
        var completedFrame = false
        var speechSeen = false
        for sample in samples {
            let value = sample.isFinite ? Double(sample) : 0
            pendingSumOfSquares += value * value
            pendingCount += 1
            guard pendingCount >= frameLength else { continue }
            let meanSquare = pendingSumOfSquares / Double(pendingCount)
            pendingSumOfSquares = 0
            pendingCount = 0
            observeFrame(levelDB: Self.levelDB(meanSquare: meanSquare), duration: frameDuration)
            completedFrame = true
            speechSeen = speechSeen || isSpeaking
        }
        guard completedFrame else { return nil }
        return AppleSpeechActivityUpdate(speechDetected: speechSeen, seconds: timelineSeconds)
    }

    /// Forgets the utterance in progress but keeps the learned noise floor and
    /// timeline, e.g. when the session re-arms after a capture.
    public mutating func resetSpeech() {
        isSpeaking = false
        candidateSeconds = 0
        belowReleaseSeconds = 0
    }

    static func levelDB(meanSquare: Double) -> Double {
        guard meanSquare > 0 else { return silenceLevelDB }
        return max(silenceLevelDB, 10 * log10(meanSquare))
    }

    private mutating func observeFrame(levelDB: Double, duration: Double) {
        timelineSeconds += duration
        guard let floor = noiseFloorDB else {
            noiseFloorDB = min(levelDB, configuration.maximumCalibratedNoiseFloorDB)
            calibratedSeconds = duration
            return
        }
        if calibratedSeconds < configuration.calibrationSeconds {
            // Seed the floor from the quietest opening frames before any speech
            // can be reported, so the room's own noise never counts as speech.
            noiseFloorDB = min(floor, levelDB)
            calibratedSeconds += duration
            return
        }

        let onset = max(floor + configuration.onsetMarginDB, configuration.minimumOnsetLevelDB)
        let release = max(
            floor + configuration.releaseMarginDB,
            configuration.minimumOnsetLevelDB - (configuration.onsetMarginDB - configuration.releaseMarginDB)
        )

        if isSpeaking {
            if levelDB < release {
                belowReleaseSeconds += duration
                if belowReleaseSeconds >= configuration.releaseHangSeconds {
                    isSpeaking = false
                    belowReleaseSeconds = 0
                }
            } else {
                belowReleaseSeconds = 0
            }
        } else if levelDB >= onset || (candidateSeconds > 0 && levelDB >= release) {
            candidateSeconds += duration
            if candidateSeconds >= configuration.minimumSpeechSeconds {
                isSpeaking = true
                candidateSeconds = 0
                belowReleaseSeconds = 0
            }
        } else {
            candidateSeconds = 0
        }

        updateNoiseFloor(floor, levelDB: levelDB, duration: duration)
    }

    private mutating func updateNoiseFloor(_ floor: Double, levelDB: Double, duration: Double) {
        let timeConstant: Double
        let maximumRise: Double
        if levelDB < floor {
            timeConstant = configuration.noiseFloorFallSeconds
            maximumRise = 0
        } else if isSpeaking || candidateSeconds > 0 {
            timeConstant = configuration.noiseFloorRiseWhileSpeakingSeconds
            maximumRise = configuration.speechNoiseFloorRiseLimitDBPerSecond * duration
        } else {
            timeConstant = configuration.noiseFloorRiseSeconds
            maximumRise = configuration.noiseFloorRiseLimitDBPerSecond * duration
        }
        let weight = 1 - exp(-duration / max(timeConstant, duration))
        let step = (levelDB - floor) * weight
        noiseFloorDB = floor + (step > 0 ? min(step, maximumRise) : step)
    }
}
