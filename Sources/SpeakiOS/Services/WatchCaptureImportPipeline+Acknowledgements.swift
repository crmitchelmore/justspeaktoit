#if os(iOS)
import Foundation
import os
import SpeakCore

extension WatchCaptureImportPipeline {
    /// Sends one acknowledgement to the Watch. Set by the receiver, which
    /// owns the WCSession; delivery confirmation comes back through
    /// `handleAckTransferFinished`.
    nonisolated public var sendAck: (@Sendable (WatchCaptureAck) -> Void)? {
        get { sendAckHandler.withLock { $0 } }
        set { sendAckHandler.withLock { $0 = newValue } }
    }

    /// Re-sends every acknowledgement whose delivery is unconfirmed.
    public func replayPendingAcks() {
        guard let sendAck else { return }
        for record in journal.pendingAcks() {
            sendAck(record.ack)
        }
    }

    /// Transport confirmation from the receiver's `didFinish` delegate: a
    /// confirmed delivery clears the retained acknowledgement; a failed one
    /// keeps it for the next replay, without retranscribing anything.
    nonisolated public func handleAckTransferFinished(captureID: UUID, delivered: Bool) {
        guard delivered else { return }
        journal.confirmAckDelivered(captureID: captureID)
    }
}
#endif
