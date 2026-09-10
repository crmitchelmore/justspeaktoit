#if os(iOS)
import Foundation

// The safety recording a capture wrote, and who gets to discard it
// (issues #993, #992).
//
// The transcriber that produced the audio deliberately does not delete it: a
// transcript in hand is not a transcript delivered, and a result nobody used —
// an abandoned finalisation, a process killed before the History write — must
// leave its audio recoverable. Disposal therefore belongs to the owner of the
// result, and only after delivery has actually happened.
extension IOSTranscriptionSession {
    /// The safety claim this session's capture wrote its audio under, if any.
    /// Used to settle *this* capture's claim on delivery rather than every
    /// claim the process holds (issue #992).
    var safetyRecordingID: UUID? {
        switch backend {
        case .batch(let transcriber): return transcriber.safetyRecordingID
        case .apple(let transcriber): return transcriber.audioRecorder.lastClaim
        case .openAI(let transcriber): return transcriber.audioRecorder.lastClaim
        case .shared(let transcriber): return transcriber.audioRecorder.lastClaim
        }
    }

    /// The completed safety recording this session wrote, if it wrote one and
    /// it has not been discarded yet.
    var finishedRecordingURL: URL? {
        guard case .batch(let transcriber) = backend else { return nil }
        return transcriber.finishedRecordingURL
    }

    /// Discards the temporary recording of a non-retained batch capture, once
    /// its owner has finished delivering the transcript. A no-op for every
    /// other backend, and for a recording the user asked to keep.
    @discardableResult
    func discardTemporaryRecording() -> Bool {
        guard case .batch(let transcriber) = backend else { return false }
        return transcriber.discardRecordingIfNotRetained()
    }
}
#endif
