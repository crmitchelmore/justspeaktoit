#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore

/// Runs the microphone self-test on device (issue #997).
///
/// **Why this does not go through `TranscriptionRecordingService`.** Every
/// side effect the issue warns about — a History row, an overwritten
/// clipboard, an unrequested Live Activity, a delivery to a destination, a
/// published App Group `isRecording` flag — is produced by that service. This
/// runner never calls it, never constructs a transcriber, never resolves a
/// provider and never touches `UIPasteboard`, `iOSHistoryManager`,
/// `TranscriptionActivityManager` or `SharedTranscriptionState`. The absence
/// of those effects is therefore structural rather than a set of suppression
/// flags a future edit could forget to pass.
///
/// **Why it does not need the user to speak.** A live input tap delivers
/// buffers in a silent room exactly as it does in a loud one, because a buffer
/// of silence is still a buffer — the same fact
/// ``CaptureWatchdogPolicy/firstInputDeadlineSeconds`` rests on. The test
/// therefore proves the microphone is delivering audio to this app without
/// asking anybody to talk, which matters because the failure being diagnosed
/// is a silent one.
///
/// **Why the microphone cannot be left hot.** Teardown runs from a `defer`
/// that covers every exit — success, thrown error, cancellation and the
/// overall deadline — and it removes the tap, stops the engine and hands the
/// audio session back.
@MainActor
public final class CaptureSelfTestRunner {
    private let audioSessionManager: AudioSessionManager
    private let logger = SpeakLogger.logger(category: "CaptureSelfTest")

    public init(audioSessionManager: AudioSessionManager? = nil) {
        self.audioSessionManager = audioSessionManager ?? AudioSessionManager()
    }

    /// Opens the microphone, counts real input buffers and closes it again.
    public func run(
        policy: CaptureSelfTestPolicy.Type = CaptureSelfTestPolicy.self
    ) async -> CaptureSelfTestResult {
        var run = CaptureSelfTestRun()
        let began = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(began) * 1000) }

        guard self.audioSessionManager.hasMicrophonePermission() else {
            run.fail(at: .permission, atMilliseconds: elapsed())
            return run.result()
        }
        run.note(.permission, atMilliseconds: elapsed())

        let engine = AVAudioEngine()
        var tapInstalled = false
        var sessionConfigured = false
        // Every exit closes the microphone. This is the only teardown path and
        // it cannot be skipped.
        defer {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
            if sessionConfigured { self.audioSessionManager.deactivate() }
        }

        // The elapsed clock starts above, so the documented ceiling has to
        // cover configuration too: an audio session that blocks would otherwise
        // leave `run()` pending indefinitely and hold the deferred teardown
        // with it. The deadline only bounds the *wait* — a configuration that
        // returns late still sets `sessionConfigured`, so anything it acquired
        // is handed back by the teardown below.
        let configured = await Self.configure(
            audioSessionManager: self.audioSessionManager,
            within: policy.overallDeadlineSeconds - Date().timeIntervalSince(began),
            markConfigured: { sessionConfigured = true }
        )
        guard configured else {
            run.fail(at: .audioSession, atMilliseconds: elapsed())
            return run.result()
        }
        run.note(.audioSession, atMilliseconds: elapsed())

        let (signal, counter) = Self.installCountingTap(on: engine)
        tapInstalled = true

        guard Self.start(engine) else {
            run.fail(at: .engine, atMilliseconds: elapsed())
            return run.result()
        }
        run.note(.engine, atMilliseconds: elapsed())

        let cancelled = await Self.waitForInput(
            signal: signal,
            run: run,
            began: began,
            window: policy.inputWindowSeconds
        )
        if cancelled {
            run.cancel(atMilliseconds: elapsed())
            return run.result()
        }

        for _ in 0..<counter.value {
            run.noteInputBuffer(atMilliseconds: elapsed())
        }
        return self.report(run.finish(atMilliseconds: elapsed()))
    }

    /// Configures the audio session under the run's remaining budget.
    ///
    /// - Returns: `false` when configuration failed *or* the budget elapsed
    ///   first. A late success still marks the session configured through
    ///   `markConfigured`, so the caller's teardown deactivates it.
    private static func configure(
        audioSessionManager: AudioSessionManager,
        within seconds: TimeInterval,
        markConfigured: @escaping @MainActor () -> Void
    ) async -> Bool {
        let outcome = try? await CaptureDeadline.result(
            of: { () async throws -> Bool in
                try await audioSessionManager.configureForRecording()
                markConfigured()
                return true
            },
            orNilAfter: max(0, seconds)
        )
        return outcome == true
    }

    private static func start(_ engine: AVAudioEngine) -> Bool {
        do {
            engine.prepare()
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    /// Logs the one content-free summary line, locally. Nothing is sent.
    private func report(_ result: CaptureSelfTestResult) -> CaptureSelfTestResult {
        let summary = "self-test outcome=\(result.outcome) "
            + "buffers=\(result.observedBuffers) ms=\(result.elapsedMilliseconds)"
        self.logger.info("\(summary, privacy: .public)")
        return result
    }

    /// Installs a tap that counts real input buffers and nothing else — it
    /// writes no file, converts nothing and sends nothing anywhere.
    ///
    /// The first-input signal is the same primitive the capture path uses
    /// (issue #983), so the test and the real thing agree on what counts as
    /// audio having arrived.
    private static func installCountingTap(
        on engine: AVAudioEngine
    ) -> (FirstInputSignal, SelfTestBufferCounter) {
        let signal = FirstInputSignal()
        let counter = SelfTestBufferCounter()
        let format = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard buffer.frameLength > 0 else { return }
            counter.increment()
            _ = signal.markObserved()
        }
        return (signal, counter)
    }

    /// Holds the microphone open only until a real buffer lands, the window
    /// closes, or the overall ceiling is reached. Nothing is recorded and
    /// nothing is written; the caller's `defer` closes the microphone whichever
    /// way this returns.
    ///
    /// - Returns: `true` when the wait was cancelled.
    private static func waitForInput(
        signal: FirstInputSignal,
        run: CaptureSelfTestRun,
        began: Date,
        window: TimeInterval
    ) async -> Bool {
        while !signal.hasObserved {
            let elapsed = Int(Date().timeIntervalSince(began) * 1000)
            if run.hasPassedDeadline(atMilliseconds: elapsed) { return false }
            if Date().timeIntervalSince(began) >= window { return false }
            try? await Task.sleep(nanoseconds: 25_000_000)
            if Task.isCancelled { return true }
        }
        return false
    }
}

/// Counts tap callbacks from the audio thread. A plain counter behind a lock,
/// because the tap is not on the main actor and the value is read once the
/// engine has stopped.
final class SelfTestBufferCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        self.lock.lock()
        self.count += 1
        self.lock.unlock()
    }

    var value: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.count
    }
}
#endif
