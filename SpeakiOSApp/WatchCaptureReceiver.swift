import Foundation
import SpeakCore
import SpeakiOSLib
import UIKit
import WatchConnectivity

/// iPhone-side endpoint for Apple Watch audio captures.
///
/// The watch records audio locally and hands it off via a WatchConnectivity
/// file transfer (which queues while the phone is out of range and launches
/// this app in the background on delivery). This receiver:
///
/// 1. moves the delivered file out of WatchConnectivity's inbox synchronously
///    (the system deletes it when the delegate callback returns),
/// 2. transcribes it with the user's configured batch model,
/// 3. saves the transcript to history (which syncs to the Mac via the
///    existing CloudKit machinery), optionally kicking off the user's
///    auto-polish, and
/// 4. queues an acknowledgement back to the watch so it can mark the capture
///    as done (`transferUserInfo` also queues while unreachable).
///
/// Activation is gated by `FeatureFlags.watchCaptureEnabled`; without the
/// watch app build flag this class stays dormant.
final class WatchCaptureReceiver: NSObject {
    static let shared = WatchCaptureReceiver()

    private override init() {
        super.init()
    }

    /// Directory where delivered captures are parked until transcription
    /// succeeds. Files for failed transcriptions are retained here so a
    /// future retry path can pick them up.
    static var inboxDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WatchCaptures", isDirectory: true)
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - Import pipeline

    /// Transcribes a delivered capture, saves it to history, and queues an
    /// acknowledgement back to the watch.
    @MainActor
    private func importCapture(at url: URL, envelope: WatchCaptureEnvelope) async {
        // Keep the (likely background-launched) process alive long enough for
        // the upload + history write to commit.
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "WatchCaptureImport")
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }

        let settings = AppSettings.shared
        // API keys load from the keychain asynchronously after init; a cold
        // background launch must wait for them before resolving the model.
        await settings.ensureKeysLoaded()
        let model = settings.batchTranscriptionModel

        do {
            let result = try await IOSBatchTranscriber.transcribeFile(
                at: url,
                model: model,
                apiKey: settings.batchAPIKey,
                language: settings.preferredModelLanguage
            )
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw IOSBatchTranscriptionError.emptyTranscript
            }

            let item = iOSHistoryItem(
                createdAt: envelope.createdAt,
                transcription: result.text,
                model: model,
                duration: result.duration > 0 ? result.duration : envelope.duration,
                wordCount: result.text.split(separator: " ").count,
                originPlatform: "watchos"
            )
            iOSHistoryManager.shared.add(item)
            SpeakLogger.logTranscription(
                event: "Watch capture transcribed",
                model: model,
                wordCount: item.wordCount
            )

            sendAck(WatchCaptureAck(id: envelope.id, outcome: .transcribed))
            try? FileManager.default.removeItem(at: url)

            if settings.autoPostProcess && settings.hasOpenRouterKey {
                await iOSHistoryManager.shared.reprocess(item)
            }
        } catch {
            SpeakLogger.logError(error, context: "WatchCaptureReceiver.importCapture")
            // Retain the audio file for a future retry; tell the watch so the
            // capture surfaces as failed instead of silently pending forever.
            sendAck(WatchCaptureAck(
                id: envelope.id,
                outcome: .failed,
                message: error.localizedDescription
            ))
        }
    }

    private func sendAck(_ ack: WatchCaptureAck) {
        guard let userInfo = ack.userInfo() else { return }
        WCSession.default.transferUserInfo(userInfo)
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
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate after a watch switch so transfers keep flowing.
        session.activate()
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The system deletes `file.fileURL` when this method returns, so the
        // move must happen synchronously — everything after is async.
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

        let destination = Self.inboxDirectory
            .appendingPathComponent(envelope.id.uuidString)
            .appendingPathExtension(envelope.fileExtension)
        do {
            try FileManager.default.createDirectory(
                at: Self.inboxDirectory,
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: file.fileURL, to: destination)
        } catch {
            SpeakLogger.logError(error, context: "WatchCaptureReceiver.didReceiveFile")
            return
        }

        Task { @MainActor in
            await self.importCapture(at: destination, envelope: envelope)
        }
    }
}
