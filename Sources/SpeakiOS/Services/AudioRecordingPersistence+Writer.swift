#if os(iOS)
import Foundation
import os
import SpeakCore

/// The write side's lock-owned state (issues #705, #943).
///
/// `writeBuffer` reads `isOpen`, admits the frame and submits it to `ioQueue`
/// in one lock hold, so every admitted write is queued ahead of
/// `closeWriter`'s `ioQueue.sync` barrier and lands in the file it was
/// admitted for — or not at all.
struct WriterState: Sendable {
    /// Fast-path flag read by `writeBuffer` before copying.
    var isOpen = false
    /// Bounded admission (issue #705): short I/O stalls are absorbed by
    /// fallback allocations up to a duration budget sized from the sample
    /// format; sustained overflow drops frames and records the gap instead of
    /// silently presenting a complete recording. Replaced per session.
    var admission = RecordingPersistenceAdmissionController()
}

// The writer close path (issues #705, #992), kept beside the state it closes.
extension AudioRecordingPersistence {
    /// Flips the fast-path flag and drains + closes the file on the I/O
    /// queue. `sync` so pending writes finish and the file header is
    /// finalised before callers read the file (size, playback, deletion).
    func closeWriter() {
        markWriterClosed()
        ioQueue.sync { ioFile = nil }
    }

    /// Clears `isOpen` under `writerState`. A lock that is not available
    /// means an admitted write still holds it across its `ioQueue` submit —
    /// the exact state the lock scope exists to guarantee — so DEBUG builds
    /// report it before blocking. Release builds just take the lock.
    private func markWriterClosed() {
        #if DEBUG
        if writerState.withLockIfAvailable({ $0.isOpen = false }) != nil { return }
        writerCloseContentionHook?()
        #endif
        writerState.withLock { $0.isOpen = false }
    }
}
#endif
