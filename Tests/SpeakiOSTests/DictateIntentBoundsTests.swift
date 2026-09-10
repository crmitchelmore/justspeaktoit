import XCTest
@testable import SpeakCore
@testable import SpeakiOSLib

/// AppIntents requires compile-time constant literals for a parameter's
/// `default:` and `inclusiveRange:`, so `DictateIntent` cannot spell the
/// `CaptureEndPointingPolicy` constants there and has to repeat the numbers.
///
/// This is the guard on that repetition. If somebody changes a budget in the
/// policy and not in the intent, the Shortcuts editor would go on offering the
/// old range — silently, because the intent clamps whatever it is given and the
/// user would only see a picker that stops at the wrong number. These
/// assertions turn that into a build failure instead.
final class DictateIntentBoundsTests: XCTestCase {
    func testPauseLengthLiteralsMatchThePolicy() {
        XCTAssertEqual(CaptureEndPointingPolicy.defaultSilenceWindowSeconds, 3)
        XCTAssertEqual(CaptureEndPointingPolicy.silenceWindowRange.lowerBound, 2)
        XCTAssertEqual(CaptureEndPointingPolicy.silenceWindowRange.upperBound, 8)
    }

    func testMaximumLengthLiteralsMatchThePolicy() {
        XCTAssertEqual(CaptureEndPointingPolicy.defaultIntentMaximumDurationSeconds, 25)
        XCTAssertEqual(CaptureEndPointingPolicy.intentMaximumDurationRange.lowerBound, 5)
        XCTAssertEqual(CaptureEndPointingPolicy.intentMaximumDurationRange.upperBound, 60)
    }

    /// The picker's range has to be a range the clamp will actually honour,
    /// or the editor offers values the intent then silently changes.
    func testEveryValueThePickerOffersSurvivesTheClamp() {
        for seconds in stride(from: 2.0, through: 8.0, by: 1.0) {
            XCTAssertEqual(CaptureEndPointingPolicy.silenceWindow(configured: seconds), seconds)
        }
        for seconds in stride(from: 5.0, through: 60.0, by: 5.0) {
            XCTAssertEqual(CaptureEndPointingPolicy.intentMaximumDuration(configured: seconds), seconds)
        }
    }

    /// A Shortcut can pass a variable instead of using the picker, so out of
    /// range values reach `perform()` and must be clamped, never honoured.
    func testValuesOutsideThePickerAreClampedRatherThanHonoured() {
        XCTAssertEqual(CaptureEndPointingPolicy.silenceWindow(configured: 0), 2)
        XCTAssertEqual(CaptureEndPointingPolicy.intentMaximumDuration(configured: 3_600), 60)
        XCTAssertEqual(CaptureEndPointingPolicy.intentMaximumDuration(configured: -5), 5)
    }
}

#if os(iOS)
import AVFoundation

/// The metered level is written on whichever thread delivered the buffer and
/// read from the main actor. It has to be one coherent observation, and it has
/// to say *which* buffer it came from, so a level that stopped being refreshed
/// cannot be counted as fresh silence in the middle of an utterance.
@MainActor
final class InputLevelSampleTests: XCTestCase {
    func testResetReturnsToSilenceAtSequenceZero() {
        let recorder = AudioRecordingPersistence()
        recorder.publishInputLevel(-6)
        recorder.resetInputLevel()
        let sample = recorder.inputLevelSample
        XCTAssertEqual(sample.levelDBFS, AudioLevelMeter.silenceFloorDBFS)
        XCTAssertEqual(sample.sequence, 0)
    }

    func testEachPublishedLevelIsANewObservation() {
        let recorder = AudioRecordingPersistence()
        recorder.resetInputLevel()
        recorder.publishInputLevel(-20)
        let first = recorder.inputLevelSample
        recorder.publishInputLevel(-20)
        let second = recorder.inputLevelSample
        XCTAssertEqual(first.levelDBFS, second.levelDBFS)
        XCTAssertNotEqual(
            first.sequence,
            second.sequence,
            "the same level from a new buffer is still a new observation"
        )
        XCTAssertEqual(
            recorder.inputLevelSample.sequence,
            second.sequence,
            "a re-read is not a new observation"
        )
    }

    /// Concurrent writers plus a concurrent reader, which is exactly how this
    /// value is used: written from whichever thread delivered the buffer, read
    /// from the main actor. Under an unsynchronised `Float` this is undefined;
    /// with the leaf lock every read is one published pair, no sample is lost
    /// and the sequence never goes backwards.
    func testConcurrentMeteringPublishesCoherentSamples() {
        let recorder = AudioRecordingPersistence()
        recorder.resetInputLevel()
        let writesPerWorker = 500
        let workers = 4
        let group = DispatchGroup()
        for worker in 0..<workers {
            DispatchQueue.global().async(group: group) { [recorder] in
                for index in 0..<writesPerWorker {
                    recorder.publishInputLevel(Float(-60 + (worker + index) % 60))
                }
            }
        }
        DispatchQueue.global().async(group: group) { [recorder] in
            for _ in 0..<writesPerWorker {
                let sample = recorder.inputLevelSample
                XCTAssertGreaterThanOrEqual(sample.levelDBFS, -60)
                XCTAssertLessThanOrEqual(sample.sequence, UInt64(writesPerWorker * workers))
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(recorder.inputLevelSample.sequence, UInt64(writesPerWorker * workers))
    }
}

/// A Dictate wait may only be satisfied by its own capture's result.
@MainActor
final class CaptureRunCompletionTests: XCTestCase {
    func testAnUnknownRunHasNoCompletedTranscript() {
        let service = TranscriptionRecordingService.shared
        XCTAssertNil(service.completedTranscript(forRun: UUID()))
    }

    /// `isActive` goes false at `stopping`; a waiter needs the wider question
    /// so it does not read a result that has not been committed yet.
    func testSettlingIsWiderThanActive() {
        let service = TranscriptionRecordingService.shared
        XCTAssertEqual(service.state, .idle)
        XCTAssertFalse(service.isSettling)
        XCTAssertFalse(service.isActive)
    }
}
#endif
