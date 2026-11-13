#if os(iOS)
import CryptoKit
import Foundation
import SpeakCore

/// A History row that an offline capture filed with on-device text, and the
/// cloud batch model the user had selected for it (issue #999). Holds a
/// fingerprint of the text, never the transcript itself.
struct OfflineTranscriptUpgradeTicket: Codable, Equatable, Sendable {
    let historyID: UUID
    /// The safety recording's stable identity in the saved-recording library.
    let recordingID: UUID
    let targetModelID: String
    /// The row exactly as the capture filed it. Any later difference means
    /// something else (sync, post-processing, a person) touched it.
    let onDeviceFingerprint: String
    let filedUpdatedAt: Date
    var attempts: Int = 0
}

/// Pure rules for offline transcript upgrades.
enum OfflineTranscriptUpgradePolicy {
    static let maxAttempts = 3
    static let maxPendingTickets = 50

    /// The batch model an offline capture may later be upgraded with: the
    /// intended cloud model or its file-transcription counterpart, when iOS can
    /// run it over a saved file. Streaming-only and on-device models are never
    /// eligible.
    static func targetModel(forIntended modelID: String) -> String? {
        guard !AppleLocalModels.isSpeechAnalyzerModel(modelID),
              modelID != AppleLocalModels.legacySpeechModelID else { return nil }
        let suffix = "-streaming"
        let candidates = modelID.hasSuffix(suffix) ? [modelID, String(modelID.dropLast(suffix.count))] : [modelID]
        return candidates.first { id in AppSettings.supportedBatchModels.contains { $0.id == id } }
    }

    static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether the History row is still exactly what the offline capture filed.
    /// Anything else is treated as an edit and never overwritten. History
    /// stores dates as whole-second ISO 8601, so the timestamp is compared to
    /// the second.
    static func isUntouched(_ item: iOSHistoryItem, fingerprint: String, filedAt: Date) -> Bool {
        item.postProcessedTranscription == nil
            && abs(item.updatedAt.timeIntervalSince(filedAt)) < 1
            && self.fingerprint(item.transcription) == fingerprint
    }

    static func isUntouched(_ item: iOSHistoryItem, since ticket: OfflineTranscriptUpgradeTicket) -> Bool {
        self.isUntouched(item, fingerprint: ticket.onDeviceFingerprint, filedAt: ticket.filedUpdatedAt)
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
        ).withSessionDetails(
            // The on-device transcription timings no longer describe this text.
            modelUsages: [ApplicationModelUsage(modelIdentifier: model, phase: .transcriptionBatch)],
            phaseTimestamps: item.phaseTimestamps.map {
                ApplicationPhaseTimestamps(recordingStarted: $0.recordingStarted, recordingEnded: $0.recordingEnded)
            },
            trigger: item.trigger
        )
    }
}

/// Persisted pending upgrades. Bookkeeping only: never holds audio, keys or text.
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
        self.remove(historyIDs: [historyID])
    }

    /// Called for every durable History deletion, whatever the setting or network.
    func remove(historyIDs: Set<UUID>) {
        let tickets = self.tickets()
        guard tickets.contains(where: { historyIDs.contains($0.historyID) }) else { return }
        self.write(tickets.filter { !historyIDs.contains($0.historyID) })
    }

    func removeAll() {
        self.defaults.removeObject(forKey: Self.defaultsKey)
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
        /// Replaces the row only if History's own worker still holds it untouched.
        var replaceIfUntouched: @MainActor (iOSHistoryItem, OfflineTranscriptUpgradeTicket) async -> Bool
        /// Every saved recording by identity, or `nil` when the library could not be read.
        var recordingURLs: @MainActor () async -> [UUID: URL]?
        /// `shouldProceed` is checked once credentials are ready, immediately before upload.
        var transcribe: @MainActor (URL, String, @escaping @MainActor () -> Bool) async throws -> String
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
                replaceIfUntouched: { item, ticket in
                    await iOSHistoryManager.shared.replaceIfUntouchedAndWait(
                        item, fingerprint: ticket.onDeviceFingerprint, filedAt: ticket.filedUpdatedAt
                    )
                },
                recordingURLs: {
                    let directory = AudioRecordingPersistence.recordingsDirectory
                    return await Task.detached { Self.listRecordingURLs(in: directory) }.value
                },
                transcribe: { url, model, shouldProceed in
                    try await CaptureRecoveryCoordinator.transcribe(
                        url: url, model: model, shouldProceed: shouldProceed
                    )
                }
            )
        }

        /// One directory read per run, off the main actor. A failed read is not absence.
        nonisolated static func listRecordingURLs(in directory: URL) -> [UUID: URL]? {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            ) else { return nil }
            return Dictionary(
                files.map { (AudioRecordingPersistence.stableRecordingID(for: $0), $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }

    static let shared = OfflineTranscriptUpgrader(store: .shared, dependencies: .live())

    private let store: OfflineTranscriptUpgradeStore
    private let dependencies: Dependencies
    private var isRunning = false
    private var rerunRequested = false
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

    /// Records an offline capture for a later upgrade, and starts it straight
    /// away if the network has already returned. A no-op unless the user opted
    /// in and the intended model can transcribe a saved file.
    @discardableResult
    func tag(item: iOSHistoryItem, recordingID: UUID, intendedModelID: String) -> Task<Void, Never>? {
        guard self.dependencies.isEnabled(),
              let target = OfflineTranscriptUpgradePolicy.targetModel(forIntended: intendedModelID) else { return nil }
        self.store.save(OfflineTranscriptUpgradeTicket(
            historyID: item.id,
            recordingID: recordingID,
            targetModelID: target,
            onDeviceFingerprint: OfflineTranscriptUpgradePolicy.fingerprint(item.transcription),
            filedUpdatedAt: item.updatedAt
        ))
        guard self.dependencies.connectivity() == .available else { return nil }
        return Task { await self.run() }
    }

    private var canProceed: Bool {
        self.dependencies.isEnabled() && self.dependencies.connectivity() == .available
    }

    /// Upgrades every pending row it can, one at a time. Safe to call
    /// repeatedly; a call during a run makes that run take another pass.
    func run() async {
        guard !self.isRunning else {
            self.rerunRequested = true
            return
        }
        self.isRunning = true
        defer { self.isRunning = false }
        repeat {
            self.rerunRequested = false
            guard self.canProceed, !self.store.tickets().isEmpty else { return }
            // Without a loaded History a missing row is not evidence of deletion.
            guard await self.dependencies.prepareHistory(),
                  let recordings = await self.dependencies.recordingURLs() else { return }
            for ticket in self.store.tickets() {
                guard self.canProceed else { return }
                await self.upgrade(ticket, recordings: recordings)
            }
        } while self.rerunRequested
    }

    private func isStillWanted(_ ticket: OfflineTranscriptUpgradeTicket) -> Bool {
        guard self.canProceed, let item = self.dependencies.historyItem(ticket.historyID) else { return false }
        return OfflineTranscriptUpgradePolicy.isUntouched(item, since: ticket)
    }

    private func upgrade(_ ticket: OfflineTranscriptUpgradeTicket, recordings: [UUID: URL]) async {
        guard ticket.attempts < OfflineTranscriptUpgradePolicy.maxAttempts,
              let item = self.dependencies.historyItem(ticket.historyID),
              OfflineTranscriptUpgradePolicy.isUntouched(item, since: ticket),
              let url = recordings[ticket.recordingID] else {
            // Deleted, edited, already upgraded, out of retries or audio gone.
            // The saved recording, if any, stays for manual re-transcription.
            self.store.remove(historyID: ticket.historyID)
            return
        }
        let text: String?
        do {
            text = try await CaptureDeadline.result(
                of: {
                    try await self.dependencies.transcribe(url, ticket.targetModelID) { self.isStillWanted(ticket) }
                },
                orNilAfter: self.dependencies.deadlineSeconds
            )
        } catch is CancellationError {
            // Consent, network or the row changed while keys loaded: nothing was sent.
            if !self.isStillWanted(ticket), self.canProceed { self.store.remove(historyID: ticket.historyID) }
            return
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
        let upgraded = OfflineTranscriptUpgradePolicy.upgraded(
            item, text: trimmed, model: ticket.targetModelID, now: self.dependencies.now()
        )
        if await self.dependencies.replaceIfUntouched(upgraded, ticket) {
            self.store.remove(historyID: ticket.historyID)
        } else if let current = self.dependencies.historyItem(ticket.historyID),
                  OfflineTranscriptUpgradePolicy.isUntouched(current, since: ticket) {
            // Still untouched, so the write itself failed: worth another attempt.
            self.recordFailure(ticket)
        } else {
            self.store.remove(historyID: ticket.historyID)
        }
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
