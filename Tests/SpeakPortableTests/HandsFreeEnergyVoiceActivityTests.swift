import Foundation
import XCTest

@testable import SpeakCore

/// The hands-free energy voice-activity gate (#1553), driven with synthetic
/// PCM in 100 ms chunks the way the microphone tap delivers it.
final class HandsFreeEnergyVoiceActivityTests: XCTestCase {
    private let sampleRate = 16_000.0
    private let chunkSeconds = 0.1

    /// Deterministic white noise so the tests never flake.
    private struct Noise {
        var state: UInt32 = 12_345
        mutating func next(amplitude: Float) -> Float {
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Float(state >> 8) / Float(1 << 24) * 2 - 1) * amplitude
        }
    }

    private var noise = Noise()
    private var clock = 0.0

    /// Feeds `seconds` of audio and returns one report per chunk.
    private func feed(
        _ detector: inout HandsFreeEnergyVoiceActivityDetector,
        seconds: Double,
        noiseAmplitude: Float = 0.001,
        tone: (Double) -> Float = { _ in 0 }
    ) -> [AppleSpeechActivityUpdate] {
        var updates: [AppleSpeechActivityUpdate] = []
        let chunkLength = Int(sampleRate * chunkSeconds)
        var remaining = Int((seconds * sampleRate).rounded())
        while remaining > 0 {
            let count = min(chunkLength, remaining)
            var samples = [Float](repeating: 0, count: count)
            for index in 0..<count {
                let time = clock + Double(index) / sampleRate
                samples[index] = noise.next(amplitude: noiseAmplitude) + tone(time)
            }
            clock += Double(count) / sampleRate
            remaining -= count
            if let update = detector.process(samples: samples, sampleRate: sampleRate) {
                updates.append(update)
            }
        }
        return updates
    }

    private func voice(amplitude: Float) -> (Double) -> Float {
        // A 180 Hz voice with a 4 Hz syllable envelope that dips to 20%.
        { time in
            let envelope = 0.6 + 0.4 * sin(2 * Double.pi * 4 * time)
            return amplitude * Float(envelope * sin(2 * Double.pi * 180 * time))
        }
    }

    func testSilence_StaysArmedWithoutReportingSpeech() {
        var detector = HandsFreeEnergyVoiceActivityDetector()
        let updates = feed(&detector, seconds: 30)

        XCTAssertFalse(updates.isEmpty)
        XCTAssertFalse(updates.contains { $0.speechDetected }, "Room noise must never count as speech")
        XCTAssertEqual(updates.last?.seconds ?? 0, 30, accuracy: 0.05)
    }

    func testSpeech_TriggersWithinTheStartBudgetAndEndsAfterSilence() {
        var detector = HandsFreeEnergyVoiceActivityDetector()
        _ = feed(&detector, seconds: 1)
        let speech = feed(&detector, seconds: 1.5, tone: voice(amplitude: 0.1))
        let after = feed(&detector, seconds: 1)

        let firstSpeech = speech.first { $0.speechDetected }
        XCTAssertNotNil(firstSpeech)
        XCTAssertLessThanOrEqual(
            (firstSpeech?.seconds ?? .infinity) - 1,
            HandsFreeDictationPolicy.speechStartBudgetSeconds,
            "Speech must be reported within the start budget"
        )
        XCTAssertTrue(speech.dropFirst(3).allSatisfy { $0.speechDetected }, "Syllable dips must not end speech")
        XCTAssertFalse(after.last?.speechDetected ?? true, "Speech ends once the room is quiet again")
    }

    func testSpeechAsTheMicrophoneOpens_StillTriggers() {
        var detector = HandsFreeEnergyVoiceActivityDetector()
        // Steady speech with no syllable dips, so calibration never sees the room.
        let steadyVoice = { (time: Double) -> Float in 0.1 * Float(sin(2 * Double.pi * 180 * time)) }
        let updates = feed(&detector, seconds: 1, tone: steadyVoice)

        let firstSpeech = updates.first { $0.speechDetected }
        XCTAssertNotNil(firstSpeech, "Speech already under way when arming must not be learned as room noise")
        XCTAssertLessThanOrEqual(
            firstSpeech?.seconds ?? .infinity,
            detector.configuration.calibrationSeconds + HandsFreeDictationPolicy.speechStartBudgetSeconds,
            "Speech is reported within the start budget once calibration ends"
        )
    }

    func testShortClicks_DoNotTriggerSpeech() {
        var detector = HandsFreeEnergyVoiceActivityDetector()
        _ = feed(&detector, seconds: 1)
        var updates: [AppleSpeechActivityUpdate] = []
        for clickSeconds in [0.005, 0.02, 0.06] {
            let start = clock
            updates += feed(&detector, seconds: 1) { time in
                time - start < clickSeconds ? 0.8 : 0
            }
        }

        XCTAssertFalse(updates.contains { $0.speechDetected }, "Clicks shorter than the minimum speech are ignored")
    }

    func testHysteresis_AMidLevelSustainsSpeechButCannotStartIt() {
        var detector = HandsFreeEnergyVoiceActivityDetector()
        _ = feed(&detector, seconds: 1)
        // About -55 dBFS with the room noise: above release, below onset.
        let midLevel = { (time: Double) -> Float in 0.0023 * Float(sin(2 * Double.pi * 180 * time)) }

        XCTAssertFalse(
            feed(&detector, seconds: 1, tone: midLevel).contains { $0.speechDetected },
            "A level below the onset threshold never starts speech"
        )

        _ = feed(&detector, seconds: 0.2)
        XCTAssertTrue(feed(&detector, seconds: 0.5, tone: voice(amplitude: 0.1)).last?.speechDetected ?? false)
        XCTAssertTrue(
            feed(&detector, seconds: 1, tone: midLevel).allSatisfy { $0.speechDetected },
            "Once speaking, the same level keeps speech going"
        )
        XCTAssertFalse(feed(&detector, seconds: 0.5).last?.speechDetected ?? true)
    }

    func testNoiseFloor_AdaptsSoASteadyLouderRoomStopsCountingAsSpeech() {
        var detector = HandsFreeEnergyVoiceActivityDetector()
        _ = feed(&detector, seconds: 2)
        let quietFloor = detector.estimatedNoiseFloorDB ?? 0

        // A fan 20 dB louder switches on and stays on.
        let fan = feed(&detector, seconds: 20, noiseAmplitude: 0.01)

        XCTAssertFalse(fan.suffix(10).contains { $0.speechDetected }, "Steady noise becomes the new floor")
        XCTAssertGreaterThan((detector.estimatedNoiseFloorDB ?? 0) - quietFloor, 15)

        _ = feed(&detector, seconds: 0.5, noiseAmplitude: 0.01)
        XCTAssertTrue(
            feed(&detector, seconds: 0.6, noiseAmplitude: 0.01, tone: voice(amplitude: 0.2))
                .contains { $0.speechDetected },
            "Speech above the louder floor still triggers"
        )
    }

    func testResetSpeech_KeepsTheLearnedFloorButEndsTheUtterance() {
        var detector = HandsFreeEnergyVoiceActivityDetector()
        _ = feed(&detector, seconds: 1)
        _ = feed(&detector, seconds: 0.5, tone: voice(amplitude: 0.1))
        let floor = detector.estimatedNoiseFloorDB

        detector.resetSpeech()

        XCTAssertEqual(detector.estimatedNoiseFloorDB, floor)
        XCTAssertFalse(feed(&detector, seconds: 0.1).last?.speechDetected ?? true)
    }

    func testInvalidInput_IsIgnored() {
        var detector = HandsFreeEnergyVoiceActivityDetector()
        XCTAssertNil(detector.process(samples: [Float](repeating: 0.5, count: 1_000), sampleRate: 0))
        XCTAssertNil(detector.process(samples: [Float](), sampleRate: sampleRate))
        XCTAssertNil(detector.estimatedNoiseFloorDB)
    }

    func testSensitivity_OrdersOnsetMargins() {
        let low = HandsFreeEnergyVoiceActivityDetector.Configuration(sensitivity: .low)
        let medium = HandsFreeEnergyVoiceActivityDetector.Configuration(sensitivity: .medium)
        let high = HandsFreeEnergyVoiceActivityDetector.Configuration(sensitivity: .high)

        XCTAssertGreaterThan(low.onsetMarginDB, medium.onsetMarginDB)
        XCTAssertGreaterThan(medium.onsetMarginDB, high.onsetMarginDB)
        for configuration in [low, medium, high] {
            XCTAssertLessThan(configuration.releaseMarginDB, configuration.onsetMarginDB, "Hysteresis")
        }
    }

    // MARK: - Audio format validation

    func testUsableAudioFormat_RejectsTheEmptyFormatMacOS27Reports() {
        XCTAssertFalse(AppleLocalModels.isUsableAudioFormat(sampleRate: 0, channelCount: 0))
        XCTAssertFalse(AppleLocalModels.isUsableAudioFormat(sampleRate: 16_000, channelCount: 0))
        XCTAssertFalse(AppleLocalModels.isUsableAudioFormat(sampleRate: 0, channelCount: 1))
        XCTAssertFalse(AppleLocalModels.isUsableAudioFormat(sampleRate: .nan, channelCount: 1))
        XCTAssertTrue(AppleLocalModels.isUsableAudioFormat(sampleRate: 16_000, channelCount: 1))
    }
}
