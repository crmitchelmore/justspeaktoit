#if os(iOS)
import Foundation

extension DispatchQueue {
    /// Waits for the work already queued on this serial audio-processing queue
    /// to finish.
    ///
    /// The capture taps copy each buffer and hand it to a serial queue rather
    /// than doing conversion and network sends on the real-time audio thread.
    /// `removeTap` therefore only stops *new* buffers arriving — whatever is
    /// already queued is still in flight. Every stop/restart boundary awaits
    /// this before finalising the session (`CloseStream`, `endAudio()`,
    /// `session.finish()`, committing the input buffer, closing the recorder),
    /// so the last words spoken land in the result instead of being dropped or
    /// arriving after the session closed.
    ///
    /// Async rather than `sync` on purpose: these call sites run on the main
    /// actor, which must not block.
    func drainPendingWork() async {
        await withCheckedContinuation { continuation in
            // Serial queue: this hop runs strictly after every item enqueued
            // before it.
            self.async { continuation.resume() }
        }
    }
}
#endif
