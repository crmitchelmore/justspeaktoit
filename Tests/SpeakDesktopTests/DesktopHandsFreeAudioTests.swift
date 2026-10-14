import Foundation
import SpeakCore
import SpeakDesktop
import XCTest

private final class HandsFreeAudioLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [HandsFreeDictationMachine.Event] = []
    private var storedFailures: [String] = []
    private var storedPCM = Data()
    var events: [HandsFreeDictationMachine.Event] { lock.withLock { storedEvents } }
    var failures: [String] { lock.withLock { storedFailures } }
    var pcm: Data { lock.withLock { storedPCM } }
    func event(_ event: HandsFreeDictationMachine.Event) { lock.withLock { storedEvents.append(event) } }
    func failure(_ text: String) { lock.withLock { storedFailures.append(text) } }
    func append(_ data: Data) { lock.withLock { storedPCM.append(data) } }
}

final class DesktopHandsFreeAudioTests: XCTestCase {
    private func frame(_ value: Int16, count: Int = 1_600, to audio: DesktopHandsFreeAudio) {
        [Int16](repeating: value, count: count).withUnsafeBufferPointer {
            audio.receive($0.baseAddress!, count: $0.count)
        }
    }

    func testListening_IsRAMBoundedAndFirstPhonemeIsIncluded() throws {
        let log = HandsFreeAudioLog()
        let audio = DesktopHandsFreeAudio(
            sampleRate: 16_000, threshold: 0.05, hold: 0.5, onEvent: log.event, onFailure: log.failure
        )
        audio.resumeListening()
        for _ in 0..<100 { frame(0, to: audio) }
        XCTAssertEqual(audio.bufferedBytes, 16_000)
        XCTAssertTrue(log.events.isEmpty)
        XCTAssertTrue(log.pcm.isEmpty)
        frame(2_000, to: audio)
        frame(3_000, to: audio)
        try audio.attach(log.append)
        XCTAssertEqual(log.events, [.speechDetected])
        XCTAssertEqual(log.pcm.count, 19_200)
        XCTAssertEqual(audio.bufferedBytes, 0)
        for _ in 0..<8 { frame(0, to: audio) }
        XCTAssertEqual(log.events, [.speechDetected, .silenceElapsed])
        audio.suspend()
        let received = log.pcm.count
        frame(2_000, to: audio)
        XCTAssertEqual(log.pcm.count, received)
        audio.resumeListening()
        frame(2_000, to: audio)
        XCTAssertEqual(log.events, [.speechDetected, .silenceElapsed, .speechDetected])
    }

    func testStartupOverflow_FailsExplicitlyAndCannotAttachOrReplay() {
        let log = HandsFreeAudioLog()
        let audio = DesktopHandsFreeAudio(
            sampleRate: 16_000, threshold: 0.05, hold: 0.5, onEvent: log.event, onFailure: log.failure
        )
        audio.resumeListening()
        frame(2_000, to: audio)
        for _ in 0..<40 { frame(2_000, to: audio) }
        XCTAssertEqual(log.failures.count, 1)
        XCTAssertEqual(audio.bufferedBytes, 0)
        XCTAssertThrowsError(try audio.attach(log.append))
        audio.resumeListening()
        frame(2_000, to: audio)
        XCTAssertEqual(log.events, [.speechDetected])
        XCTAssertTrue(log.pcm.isEmpty)
    }

    func testPortableMachine_PreservesOwnershipAndDoesNotRearmOnFailure() {
        var machine = HandsFreeDictationMachine()
        XCTAssertEqual(machine.handle(.userArmed), [.startDetector])
        _ = machine.handle(.detectorStarted)
        XCTAssertEqual(machine.handle(.speechDetected), [.startCapture])
        XCTAssertEqual(
            machine.handle(.captureStartRejected(.captureFailed)), [.stopDetector, .reportFailure(.captureFailed)]
        )
        XCTAssertEqual(machine.state, .off)
        XCTAssertEqual(machine.handle(.captureFinished), [])
        _ = machine.handle(.userArmed)
        _ = machine.handle(.detectorStarted)
        _ = machine.handle(.speechDetected)
        XCTAssertEqual(machine.handle(.silenceElapsed), [.stopCapture])
        XCTAssertEqual(machine.handle(.userDisarmed), [.cancelCapture, .stopDetector])
        XCTAssertEqual(machine.handle(.captureFinished), [])
    }

    func testManualSilence_InitialQuietEqualityResetAndOneStop() {
        var monitor = DictationSilenceMonitor(threshold: 0.05, duration: 0.5)
        XCTAssertFalse(monitor.observe(level: 0, atSeconds: 0))
        XCTAssertFalse(monitor.observe(level: 0, atSeconds: 0.49))
        XCTAssertFalse(monitor.observe(level: 0.05, atSeconds: 0.5))
        XCTAssertFalse(monitor.observe(level: 0, atSeconds: 0.6))
        XCTAssertTrue(monitor.observe(level: 0, atSeconds: 1.1))
        XCTAssertFalse(monitor.observe(level: 0, atSeconds: 2))
    }

    func testPCMLevels_UseMacMeterScaleAndNegativeFullScaleDoesNotOverflow() {
        let quiet: [Int16] = [0, 0, 0]
        XCTAssertEqual(quiet.withUnsafeBufferPointer(DictationSilencePolicy.normalizedLevel), 0)
        let full: [Int16] = [.min, .max]
        XCTAssertEqual(full.withUnsafeBufferPointer(DictationSilencePolicy.normalizedLevel), 1, accuracy: 0.0001)
        let sample: [Int16] = [32, -32]
        let expected = max(0, (20 * log10(32.0 / 32768) + 60) / 60)
        XCTAssertEqual(
            sample.withUnsafeBufferPointer(DictationSilencePolicy.normalizedLevel), expected, accuracy: 0.0001
        )
    }
}
