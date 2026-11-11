import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

@MainActor
final class SessionCaptureRuntimeTests: XCTestCase {
    private let captureStarted = Date(timeIntervalSince1970: 1_000)

    private final class Recorder {
        var cues: [ActiveSession] = []
        var levels: [Float] = []
        var audioLiveCount = 0
        var silenceStops = 0
        var reading: (level: Float, peakDecibels: Float)?
        var silenceSettings = SilenceAutoStop.Settings.off
        var eligible = true
    }

    private func makeRuntime(_ recorder: Recorder) -> SessionCaptureRuntime {
        SessionCaptureRuntime(
            context: SessionCaptureRuntime.Context(
                meterReading: { recorder.reading },
                silenceSettings: { recorder.silenceSettings },
                isRecording: { true },
                silenceStopEligible: { recorder.eligible },
                updateAudioLevel: { recorder.levels.append($0) },
                markAudioLive: { recorder.audioLiveCount += 1 },
                playCue: { recorder.cues.append($0) },
                silenceElapsed: { recorder.silenceStops += 1 }
            ),
            hudOcclusion: HUDOcclusionObserver(notificationCenter: NotificationCenter(), isAppVisible: { true }),
            schedulesTimer: false
        )
    }

    private func makeSession() -> ActiveSession {
        ActiveSession(gesture: .uiButton, hotKeyDescription: "Fn")
    }

    func testCue_isHeldUntilAudioArrivesForTheArmedSession() {
        let recorder = Recorder()
        let runtime = makeRuntime(recorder)
        let session = makeSession()
        runtime.begin(session, captureStarted: captureStarted)

        runtime.requestStartCue(for: session)
        XCTAssertTrue(recorder.cues.isEmpty, "The cue waits for real audio")

        recorder.reading = (level: 0, peakDecibels: -160)
        runtime.tick(now: captureStarted.addingTimeInterval(0.5))
        XCTAssertTrue(recorder.cues.isEmpty, "A silent input is not arrival before the fallback delay")

        recorder.reading = (level: 0.4, peakDecibels: -20)
        runtime.tick(now: captureStarted.addingTimeInterval(0.6))
        XCTAssertEqual(recorder.cues.map(ObjectIdentifier.init), [ObjectIdentifier(session)])
        XCTAssertEqual(recorder.audioLiveCount, 1)
        XCTAssertTrue(session.events.contains { $0.description.hasPrefix("Audio arrival — ") })

        runtime.tick(now: captureStarted.addingTimeInterval(0.7))
        XCTAssertEqual(recorder.cues.count, 1, "Arrival and the cue happen once per recording")
        XCTAssertEqual(recorder.audioLiveCount, 1)
    }

    func testCue_forAnotherSessionPlaysWithoutTouchingTheGate() {
        let recorder = Recorder()
        let runtime = makeRuntime(recorder)
        let armed = makeSession()
        let other = makeSession()
        runtime.begin(armed, captureStarted: captureStarted)

        runtime.requestStartCue(for: other)
        XCTAssertEqual(recorder.cues.map(ObjectIdentifier.init), [ObjectIdentifier(other)])

        recorder.reading = (level: 0.4, peakDecibels: -20)
        runtime.tick(now: captureStarted.addingTimeInterval(0.1))
        XCTAssertEqual(recorder.cues.count, 1, "The armed session never asked for its cue")
        XCTAssertEqual(recorder.audioLiveCount, 1)
    }

    func testStop_disarmsTheGateAndZeroesTheLevel() {
        let recorder = Recorder()
        let runtime = makeRuntime(recorder)
        let session = makeSession()
        runtime.begin(session, captureStarted: captureStarted)
        XCTAssertTrue(runtime.isMonitoring)

        runtime.stop()
        XCTAssertFalse(runtime.isMonitoring)
        XCTAssertEqual(recorder.levels.last, 0)

        runtime.requestStartCue(for: session)
        XCTAssertEqual(recorder.cues.count, 1, "Without a gate the cue plays straight away")
    }

    func testSilence_stopsOnceAndOnlyForEligibleSessions() {
        let recorder = Recorder()
        recorder.silenceSettings = SilenceAutoStop.Settings(enabled: true, threshold: 0.1, duration: 2)
        recorder.reading = (level: 0.01, peakDecibels: -60)
        let runtime = makeRuntime(recorder)
        runtime.begin(makeSession(), captureStarted: captureStarted)

        recorder.eligible = false
        runtime.tick(now: captureStarted)
        runtime.tick(now: captureStarted.addingTimeInterval(3))
        XCTAssertEqual(recorder.silenceStops, 0, "Hands-free captures own their own stop")

        recorder.eligible = true
        runtime.tick(now: captureStarted.addingTimeInterval(4))
        runtime.tick(now: captureStarted.addingTimeInterval(6.5))
        XCTAssertEqual(recorder.silenceStops, 1)
        runtime.tick(now: captureStarted.addingTimeInterval(7))
        XCTAssertEqual(recorder.silenceStops, 1, "Firing forgets the silence")
    }

    func testEnding_admitsOneStopAtATime() {
        let runtime = makeRuntime(Recorder())

        XCTAssertTrue(runtime.beginEnding())
        XCTAssertTrue(runtime.isEnding)
        XCTAssertFalse(runtime.beginEnding(), "A second stop is refused while one runs")
        runtime.finishEnding()
        XCTAssertFalse(runtime.isEnding)
        XCTAssertTrue(runtime.beginEnding())
    }
}
