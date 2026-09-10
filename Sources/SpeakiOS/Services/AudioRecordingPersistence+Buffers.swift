#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore

// Buffer-copy fallback and the once-per-session issue report (issue #705).
//
// Split out of `AudioRecordingPersistence` unchanged, so the recorder file
// stays readable now that it also carries the safety claim (issue #992).
extension AudioRecordingPersistence {
    /// Controlled fallback allocation for a pool-exhausted frame within the
    /// admission budget.
    nonisolated static func fallbackCopy(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            guard let sourceData = source[index].mData,
                  let destinationData = destination[index].mData else { continue }
            memcpy(destinationData, sourceData, Int(source[index].mDataByteSize))
            destination[index].mDataByteSize = source[index].mDataByteSize
        }
        return copy
    }

    /// Surfaces the first drop/failure of the session to the owning session,
    /// exactly once, without blocking the audio thread.
    nonisolated func reportIssueIfNeeded(_ controller: RecordingPersistenceAdmissionController) {
        // Latch and handler are read under one lock hold so two threads can
        // never both observe an unset latch (see `issueLock`).
        let handler = issueLock.withLock { () -> (@Sendable (RecordingPersistenceDiagnostics) -> Void)? in
            guard !didReportIssue else { return nil }
            didReportIssue = true
            return storedIssueHandler
        }
        guard let handler else { return }
        let diagnostics = controller.diagnostics
        DispatchQueue.global(qos: .utility).async {
            handler(diagnostics)
        }
    }
}
#endif
