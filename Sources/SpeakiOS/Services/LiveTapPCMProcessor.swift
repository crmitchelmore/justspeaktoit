#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore

/// The iOS live capture path from the input tap to provider PCM, shared by
/// ``SharedClientLiveTranscriber`` and ``OpenAIRealtimeLiveTranscriber``.
///
/// The tap copies each buffer out of a ``LivePCMBufferPool`` and hops to one
/// serial queue, where the safety recording is written and
/// ``LivePCM16Conversion`` (the converter macOS uses) produces PCM16 mono for
/// the provider. After `installTap` the conversion is only touched on that
/// queue, so it needs no lock of its own.
final class LiveTapPCMProcessor: @unchecked Sendable {
    /// One run's capture context, fixed when its tap is installed.
    struct Run {
        let recorder: AudioRecordingPersistence
        let lossReport: RecordingLossReport
        let outputFormat: AVAudioFormat
        /// Called from the render thread for every admitted buffer; the
        /// caller's `FirstInputSignal` keeps it to one main-actor hop.
        let onInput: @Sendable () -> Void
        let send: @Sendable (Data) -> Void
        let onConversionFailure: LivePCMConversionFailureReport
    }

    let queue: DispatchQueue
    private let tapBufferPool: LivePCMBufferPool
    private let conversion = LivePCM16Conversion()

    init(queueLabel: String, poolLabel: String) {
        queue = DispatchQueue(label: queueLabel)
        // Four buffers in flight, as iOS has always allowed: past that backlog
        // a tap chunk is dropped and recorded as capture loss, never queued.
        tapBufferPool = LivePCMBufferPool(maximumBuffers: 4, maximumOutstanding: 4, label: poolLabel)
    }

    /// PCM16 mono at `sampleRate`, once a converter from `input` exists. The
    /// converter is retained for the run (never reset between chunks) and
    /// flushed by ``drainTail(send:)``.
    func prepareOutputFormat(from input: AVAudioFormat, sampleRate: Double) -> AVAudioFormat? {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true
        ), conversion.prepare(from: input, to: target) else { return nil }
        return target
    }

    /// Installs the 4096-frame capture tap for `run`. The caller removes it.
    func installTap(on inputNode: AVAudioInputNode, format: AVAudioFormat, run: Run) throws {
        try inputNode.installTapSafely(onBus: 0, bufferSize: 4096, format: format) { [self] buffer, _ in
            // Copy the buffer and hop off the real-time audio thread —
            // heavy work in the tap makes CoreAudio drop mic buffers.
            guard let copied = run.lossReport.copyCapture(buffer, using: tapBufferPool) else { return }
            run.onInput()
            queue.async { [self] in
                defer { tapBufferPool.recycle(copied) }
                run.recorder.writeBuffer(copied)
                convertAndSend(copied, run: run)
            }
        }
    }

    /// Converts one tap copy on `queue`; the run's first failure is reported
    /// and nothing unconverted reaches the provider.
    func convertAndSend(_ buffer: AVAudioPCMBuffer, run: Run) {
        do {
            let data = try conversion.pcm16(from: buffer, to: run.outputFormat)
            guard !data.isEmpty else { return }
            run.send(data)
        } catch {
            run.onConversionFailure(error)
        }
    }

    /// Lets buffers queued before the tap came off land first.
    func drainPendingWork() async {
        await queue.drainPendingWork()
    }

    /// Flushes the retained resampler's trailing frames down the same send path
    /// the live chunks use, strictly after the last queued chunk (issue #872).
    /// The converter is released either way, so the next run starts clean.
    func drainTail(send: (@Sendable (Data) -> Void)?) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                defer { continuation.resume() }
                guard let tail = conversion.drainPCM16(), let send else { return }
                send(tail)
            }
        }
    }

    /// Ends a run: drops the converter without flushing (cancelled audio is
    /// thrown away) and logs the run's one overload summary, if any.
    func finishRun() {
        queue.sync { conversion.reset() }
        tapBufferPool.removeAll()
    }
}
#endif
