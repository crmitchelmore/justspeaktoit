#if os(iOS)
import Foundation
import SpeakCore

/// A History row that an offline capture filed with on-device text, and the
/// cloud batch model the user had selected for it (issue #999).
struct OfflineTranscriptUpgradeTicket: Codable, Equatable, Sendable {
    let historyID: UUID
    /// The safety recording's stable identity in the saved-recording library.
    let recordingID: UUID
    let targetModelID: String
    /// The row exactly as the capture filed it. Any later difference means
    /// something else (sync, post-processing, a person) touched it.
    let onDeviceText: String
    let filedUpdatedAt: Date
    var attempts: Int = 0
}

/// Pure rules for offline transcript upgrades.
enum OfflineTranscriptUpgradePolicy {
    static let maxAttempts = 3
    static let maxPendingTickets = 50

    /// The model an offline capture may later be upgraded with: the intended
    /// cloud model, and only when iOS can run it over a saved file. Streaming-
    /// only models and on-device models are never eligible.
    static func targetModel(forIntended modelID: String) -> String? {
        guard !AppleLocalModels.isSpeechAnalyzerModel(modelID),
              modelID != AppleLocalModels.legacySpeechModelID,
              AppSettings.supportedBatchModels.contains(where: { $0.id == modelID }) else { return nil }
        return modelID
    }

    /// Whether the History row is still exactly what the offline capture filed.
    /// Anything else is treated as an edit and never overwritten. History
    /// stores dates as whole-second ISO 8601, so the timestamp is compared to
    /// the second.
    static func isUntouched(_ item: iOSHistoryItem, since ticket: OfflineTranscriptUpgradeTicket) -> Bool {
        item.transcription == ticket.onDeviceText
            && item.postProcessedTranscription == nil
            && abs(item.updatedAt.timeIntervalSince(ticket.filedUpdatedAt)) < 1
    }

    /// The same row with the cloud transcript in place of the on-device one.
    static func upgraded(_ item: iOSHistoryItem, text: String, model: String, now: Date) -> iOSHistoryItem {
        iOSHistoryItem(
            id: item.id,
            createdAt: item.createdAt,
            updatedAt: now,
            transcription: text,
            model: model,
            duration: item.duration,
            wordCount: text.split(whereSeparator: \.isWhitespace).count,
            originPlatform: item.originPlatform,
            errorMessage: item.errorMessage
        )
    }
}

/// Persisted pending upgrades. Bookkeeping only: never holds audio or keys.
@MainActor
final class OfflineTranscriptUpgradeStore {
    static let shared = OfflineTranscriptUpgradeStore()
    static let defaultsKey = "offlineTranscriptUpgradeTickets"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func tickets() -> [OfflineTranscriptUpgradeTicket] {
        guard let data = self.defaults.data(forKey: Self.defaultsKey),
              let tickets = try? JSONDecoder().decode([OfflineTranscriptUpgradeTicket].self, from: data)
        else { return [] }
        return tickets
    }

    func save(_ ticket: OfflineTranscriptUpgradeTicket) {
        var tickets = self.tickets().filter { $0.historyID != ticket.historyID }
        tickets.append(ticket)
        self.write(Array(tickets.suffix(OfflineTranscriptUpgradePolicy.maxPendingTickets)))
    }

    func remove(historyID: UUID) {
        self.write(self.tickets().filter { $0.historyID != historyID })
    }

    private func write(_ tickets: [OfflineTranscriptUpgradeTicket]) {
        guard let data = try? JSONEncoder().encode(tickets) else { return }
        self.defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// Re-transcribes offline captures with the intended cloud model once the
/// network is back, through the same file transcription path as manual
/// recovery, and replaces the History row in place (issue #999).
@MainActor
final class OfflineTranscriptUpgrader {
    struct Dependencies {
        var isEnabled: @MainActor () -> Bool
        var connectivity: @MainActor () -> CaptureConnectivitySnapshot
        var prepareHistory: @MainActor () async -> Bool
        var historyItem: @MainActor (UUID) -> iOSHistoryItem?
        var upsert: @MainActor (iOSHistoryItem) async -> Bool
        var recordingURL: @MainActor (UUID) -> URL?
        var transcribe: @MainActor (URL, String) async throws -> String
        var deadlineSeconds: TimeInterval = CaptureRecoveryPolicy.recoveryDeadlineSeconds
        var now: @MainActor () -> Date = { Date() }

        static func live() -> Self {
            Self(
                isEnabled: { AppSettings.shared.upgradeOfflineTranscriptsWhenOnline },
                connectivity: { CaptureNetworkPathMonitor.shared.snapshot },
                prepareHistory: {
                    await iOSHistoryManager.shared.loadIfNeededAndWait()
                    return iOSHistoryManager.shared.isStorageReady
                },
                historyItem: { id in iOSHistoryManager.shared.items.first { $0.id == id } },
                upsert: { await iOSHistoryManager.shared.upsertAndWait($0) },
                recordingURL: { id in
                    AudioRecordingPersistence.listRecordings().first { $0.id == id }?.url
                },
                transcribe: { url, model in try await CaptureRecoveryCoordinator.transcribe(url: url, model: model) }
            )
        }
    }

    static let shared = OfflineTranscriptUpgrader(store: .shared, dependencies: .live())

    private let store: OfflineTranscriptUpgradeStore
    private let dependencies: Dependencies
    private var isRunning = false
    private let logger = SpeakLogger.logger(category: "OfflineTranscriptUpgrade")

    init(store: OfflineTranscriptUpgradeStore, dependencies: Dependencies) {
        self.store = store
        self.dependencies = dependencies
    }

    /// Wakes the upgrader whenever the capture path monitor sees the network return.
    func startObservingNetwork() {
        CaptureNetworkPathMonitor.shared.onBecameAvailable = { [weak self] in
            Task { await self?.run() }
        }
    }

    /// Records an offline capture for a later upgrade. A no-op unless the user
    /// opted in and the intended model can transcribe a saved file.
    func tag(item: iOSHistoryItem, recordingID: UUID, intendedModelID: String) {
        guard self.dependencies.isEnabled(),
              let target = OfflineTranscriptUpgradePolicy.targetModel(forIntended: intendedModelID) else { return }
        self.store.save(OfflineTranscriptUpgradeTicket(
            historyID: item.id,
            recordingID: recordingID,
            targetModelID: target,
            onDeviceText: item.transcription,
            filedUpdatedAt: item.updatedAt
        ))
    }

    /// Upgrades every pending row it can, one at a time. Safe to call repeatedly.
    func run() async {
        guard !self.isRunning, self.dependencies.isEnabled(),
              self.dependencies.connectivity() == .available,
              !self.store.tickets().isEmpty else { return }
        self.isRunning = true
        defer { self.isRunning = false }
        // Without a loaded History a missing row is not evidence of deletion.
        guard await self.dependencies.prepareHistory() else { return }

        for ticket in self.store.tickets() {
            guard self.dependencies.isEnabled(), self.dependencies.connectivity() == .available else { return }
            await self.upgrade(ticket)
        }
    }

    private func upgrade(_ ticket: OfflineTranscriptUpgradeTicket) async {
        guard ticket.attempts < OfflineTranscriptUpgradePolicy.maxAttempts,
              let item = self.dependencies.historyItem(ticket.historyID),
              OfflineTranscriptUpgradePolicy.isUntouched(item, since: ticket),
              let url = self.dependencies.recordingURL(ticket.recordingID) else {
            // Deleted, edited, already upgraded, out of retries or audio gone.
            // The saved recording, if any, stays for manual re-transcription.
            self.store.remove(historyID: ticket.historyID)
            return
        }
        let text: String?
        do {
            text = try await CaptureDeadline.result(
                of: { try await self.dependencies.transcribe(url, ticket.targetModelID) },
                orNilAfter: self.dependencies.deadlineSeconds
            )
        } catch {
            self.logger.error(
                "Offline upgrade failed: \(RemoteFailureLabel.label(for: error, status: nil), privacy: .public)"
            )
            text = nil
        }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            self.recordFailure(ticket)
            return
        }
        // Re-read after the await: the row may have changed while the provider ran.
        guard let current = self.dependencies.historyItem(ticket.historyID),
              OfflineTranscriptUpgradePolicy.isUntouched(current, since: ticket) else {
            self.store.remove(historyID: ticket.historyID)
            return
        }
        let upgraded = OfflineTranscriptUpgradePolicy.upgraded(
            current, text: trimmed, model: ticket.targetModelID, now: self.dependencies.now()
        )
        guard await self.dependencies.upsert(upgraded) else {
            self.recordFailure(ticket)
            return
        }
        self.store.remove(historyID: ticket.historyID)
    }

    /// A failure while offline again is not the provider's fault and costs no retry.
    private func recordFailure(_ ticket: OfflineTranscriptUpgradeTicket) {
        guard self.dependencies.connectivity() == .available else { return }
        var next = ticket
        next.attempts += 1
        if next.attempts >= OfflineTranscriptUpgradePolicy.maxAttempts {
            self.store.remove(historyID: ticket.historyID)
        } else {
            self.store.save(next)
        }
    }
}
#endif
