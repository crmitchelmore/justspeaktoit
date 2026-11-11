#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore

/// The Apple Speech capture path from the input tap to the recogniser.
///
/// The tap copies each buffer out of a bounded pool and hops to one serial
/// queue, where the run's `process` closure writes the safety recording and
/// feeds the legacy request or the SpeechAnalyzer session. Nothing heavy runs
/// on the real-time thread, and nothing on the queue ever waits on the main
/// actor, so ``drainSynchronously()`` cannot deadlock.
final class AppleSpeechCaptureTap {
    private let queue = DispatchQueue(label: "com.speak.ios.applespeech.audioProcessing")
    /// Pool for tap-buffer copies so the hot path never allocates.
    private let pool = LivePCMBufferPool(maximumBuffers: 4, maximumOutstanding: 4, label: "apple-speech")

    /// Installs the tap on `input` in its current output format.
    /// `onFirstInput` runs on the render thread for every non-empty buffer; the
    /// caller's `FirstInputSignal` keeps it to one main-actor hop. `process`
    /// runs on the serial queue.
    @MainActor
    func install(
        on input: LiveCaptureInput,
        bufferSize: AVAudioFrameCount,
        lossReport: RecordingLossReport,
        onFirstInput: @escaping () -> Void,
        process: @escaping (AVAudioPCMBuffer) -> Void
    ) throws {
        let pool = pool
        let queue = queue
        try input.installTap { node in
            let format = node.outputFormat(forBus: 0)
            try node.installTapSafely(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
                // Copy the buffer and hop off the real-time audio thread —
                // heavy work in the tap makes CoreAudio drop mic buffers.
                guard let copied = lossReport.copyCapture(buffer, using: pool) else { return }
                if copied.frameLength > 0 { onFirstInput() }
                queue.async {
                    defer { pool.recycle(copied) }
                    process(copied)
                }
            }
        }
    }

    /// Lets every buffer already queued reach its recogniser and the recorder.
    func drainPendingWork() async {
        await queue.drainPendingWork()
    }

    /// The same drain, kept atomic on the main actor for cancellation and
    /// mid-session recognition restarts.
    func drainSynchronously() {
        queue.sync {}
    }
}
#endif
