#if os(iOS)
import Foundation

// The writer close path (issues #705, #992). Split out of
// `AudioRecordingPersistence` unchanged, so the recorder file stays inside the
// length limit now that it carries the safety claim and the input level too.
extension AudioRecordingPersistence {
    /// Flips the fast-path flag and drains + closes the file on the I/O
    /// queue. `sync` so pending writes finish and the file header is
    /// finalised before callers read the file (size, playback, deletion).
    func closeWriter() {
        acquireStateLockForClose()
        isWriterOpen = false
        stateLock.unlock()
        ioQueue.sync { ioFile = nil }
    }

    /// Takes `stateLock` for the close path. A failed `try()` means an admitted
    /// write still holds the lock across its `ioQueue` submit — the exact state
    /// the lock scope exists to guarantee — so DEBUG builds report it before
    /// blocking. Release builds just take the lock.
    private func acquireStateLockForClose() {
        #if DEBUG
        if stateLock.try() { return }
        writerCloseContentionHook?()
        #endif
        stateLock.lock()
    }
}
#endif
