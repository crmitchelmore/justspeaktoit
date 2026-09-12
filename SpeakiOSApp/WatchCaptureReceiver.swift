import Foundation
import SpeakCore
import SpeakiOSLib
import UIKit
import WatchConnectivity

/// iPhone-side WatchConnectivity endpoint for Apple Watch audio captures.
///
/// Deliberately a thin shim (issue #674): it owns the `WCSession` and nothing
/// else. Delivered files are parked synchronously (the system reclaims the
/// inbox file when the delegate returns) into the durable
/// `WatchCaptureImportPipeline`, which journals every import, retries with
/// bounded attempts under an expiration-safe background task, acknowledges
/// the Watch only after the history write is durable, and replays
/// unconfirmed acknowledgements. Activation and foreground entry reconcile
/// pending work, so a suspended or killed import resumes instead of
/// stranding audio with the Watch stuck at "Delivered".
///
/// Activation is gated by `FeatureFlags.watchCaptureEnabled`; without the
/// watch app build flag this class stays dormant.
final class WatchCaptureReceiver: NSObject {
    static let shared = WatchCaptureReceiver()

    private let pipeline = WatchCaptureImportPipeline.shared

    private override init() {
        super.init()
        pipeline.sendAck = { ack in
            guard let userInfo = ack.userInfo() else { return }
            let session = WCSession.default
            guard session.activationState == .activated else { return }
            // Reconciliation may run repeatedly while the watch is offline.
            guard !session.outstandingUserInfoTransfers.contains(where: {
                WatchCaptureAck.from(userInfo: $0.userInfo) == ack
            }) else { return }
            session.transferUserInfo(userInfo)
        }
    }

    /// Kept for existing callers; the pipeline owns the directory.
    static var inboxDirectory: URL {
        WatchCaptureImportPipeline.inboxDirectory
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Reconciles parked imports and unconfirmed acknowledgements. Called on
    /// activation and whenever the app returns to the foreground.
    func reconcilePendingWork() {
        Task { @MainActor in
            await self.pipeline.processPendingImports()
        }
    }
}

enum WatchCaptureReceiverError: LocalizedError {
    case undecodableEnvelope

    var errorDescription: String? {
        switch self {
        case .undecodableEnvelope:
            return "Watch capture rejected: file transfer carried no decodable capture metadata."
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchCaptureReceiver: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            SpeakLogger.logError(error, context: "WatchCaptureReceiver.activation")
        }
        // A fresh activation is the recovery point for imports interrupted by
        // suspension or death, and for acknowledgements the Watch never got.
        if activationState == .activated {
            reconcilePendingWork()
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate after a watch switch so transfers keep flowing.
        session.activate()
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The system deletes `file.fileURL` when this method returns, so the
        // park must happen synchronously — everything after is async.
        guard let envelope = WatchCaptureEnvelope.from(metadata: file.metadata) else {
            // Without a decodable envelope there is no capture identity to
            // acknowledge, so importing would ack an id the watch never sent.
            // Reject the delivery (the system reclaims the inbox file) and let
            // the watch retry.
            SpeakLogger.logError(
                WatchCaptureReceiverError.undecodableEnvelope,
                context: "WatchCaptureReceiver.didReceiveFile"
            )
            return
        }

        guard pipeline.parkDeliveredFile(at: file.fileURL, envelope: envelope) else {
            return
        }
        reconcilePendingWork()
    }

    func session(
        _ session: WCSession,
        didFinish userInfoTransfer: WCSessionUserInfoTransfer,
        error: Error?
    ) {
        // Delivery confirmation for a queued acknowledgement: only a
        // confirmed transfer clears the retained record; failures stay for
        // the next replay, without retranscribing anything.
        guard let ack = WatchCaptureAck.from(userInfo: userInfoTransfer.userInfo) else { return }
        if let error {
            SpeakLogger.logError(error, context: "WatchCaptureReceiver.ackTransfer")
        }
        pipeline.handleAckTransferFinished(captureID: ack.id, delivered: error == nil)
    }
}
