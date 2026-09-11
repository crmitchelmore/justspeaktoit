#if os(iOS)
import Foundation

/// Binds hands-free stop/cancel callbacks to the run their start actually acquired.
///
/// The recording session boundary itself is `IOSRecordingSession`: the
/// foreground coordinator and the headless service route on the same protocol,
/// so a test double stands in for either owner and neither can drift.
@MainActor
final class ForegroundCaptureHandle {
    var runID: UUID?
}

// MARK: - Settling cancellation (issue #943)

extension IOSTranscriptionSession {
    /// Cancellation stops capture immediately, but some providers drain queued
    /// work afterwards. An owner holds its claim until this returns, so a
    /// replacement can never overlap a microphone that is still being released.
    func awaitCancellationSettled() async {
        switch backend {
        case .apple(let transcriber): await transcriber.awaitCancellationSettled()
        case .shared(let transcriber): await transcriber.awaitCancellationSettled()
        case .batch, .openAI: break
        }
    }
}
#endif
