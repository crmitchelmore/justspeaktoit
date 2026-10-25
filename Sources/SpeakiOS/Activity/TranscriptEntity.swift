#if os(iOS)
import AppIntents
import Foundation
import SpeakCore
import UIKit

/// Text is populated only by the authenticated action. Passive rehydration
/// deliberately returns identity/metadata without exposing saved dictation.
struct TranscriptEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Transcript" }
    static var defaultQuery: TranscriptEntityQuery { .init() }

    let id: UUID
    @Property(title: "Raw Text") var rawText: String?
    @Property(title: "Polished Text") var polishedText: String?
    @Property(title: "Created At") var createdAt: Date
    @Property(title: "Duration in Seconds") var durationSeconds: Double?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "Transcript",
            subtitle: "\(self.createdAt.formatted(date: .abbreviated, time: .shortened))"
        )
    }

    /// A conservative app-owned UTF-8 budget, well below the framework's
    /// documented 10 MB entity limit. Reserve space for fixed metadata/wrappers.
    static let maximumPayloadBytes = 64 * 1024
    static let metadataReserveBytes = 1024

    init(item: iOSHistoryItem, includeText: Bool) throws {
        guard item.createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw TranscriptEntityError.historyUnavailable
        }
        self.id = item.id
        self.createdAt = item.createdAt
        self.durationSeconds = item.duration.isFinite && item.duration >= 0 ? item.duration : nil
        let raw = includeText ? item.transcription : nil
        let polished = includeText ? item.postProcessedTranscription.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        } : nil
        let textBudget = Self.maximumPayloadBytes - Self.metadataReserveBytes
        let rawBytes = raw?.utf8.count ?? 0
        let polishedBytes = polished?.utf8.count ?? 0
        guard rawBytes <= textBudget, polishedBytes <= textBudget - rawBytes else {
            throw TranscriptEntityError.tooLarge
        }
        self.rawText = raw
        self.polishedText = polished
    }
}

enum TranscriptEntityError: LocalizedError, Equatable {
    case historyUnavailable
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .historyUnavailable:
            return "Transcript history is unavailable. Unlock your device and try again, or open History in the app."
        case .tooLarge:
            return "Transcript too large for structured output; use Get Last Transcription."
        }
    }
}

/// The injected snapshot has the same MainActor ownership as local History.
/// It is read once per action/query; no mutable latest-transcript state is used.
struct TranscriptEntityHistory: Sendable {
    typealias Snapshot = @MainActor @Sendable () throws -> [iOSHistoryItem]
    private let snapshot: Snapshot

    init(snapshot: @escaping Snapshot = Self.localSnapshot) { self.snapshot = snapshot }

    @MainActor
    static func localSnapshot() throws -> [iOSHistoryItem] {
        guard UIApplication.shared.isProtectedDataAvailable else {
            throw TranscriptEntityError.historyUnavailable
        }
        let history = iOSHistoryManager.shared
        history.ensureLoaded()
        guard history.isStorageReady else { throw TranscriptEntityError.historyUnavailable }
        return history.items
    }

    @MainActor
    func latest() throws -> TranscriptEntity {
        let items = try self.snapshot()
        guard let item = items.first(where: {
            AutomationIntentSupport.bestTranscript(
                raw: $0.transcription, polished: $0.postProcessedTranscription
            ) != nil
        }) else { throw AutomationIntentError.noTranscriptionYet }
        return try TranscriptEntity(item: item, includeText: true)
    }

    @MainActor
    func metadata(for identifiers: [UUID]) throws -> [TranscriptEntity] {
        // No identifiers means no reason even to load private History.
        guard !identifiers.isEmpty else { return [] }
        let items = try self.snapshot()
        var seen = Set<UUID>()
        return try identifiers.compactMap { id in
            guard seen.insert(id).inserted, let item = items.first(where: { $0.id == id }) else { return nil }
            return try TranscriptEntity(item: item, includeText: false)
        }
    }
}

struct TranscriptEntityQuery: EntityQuery {
    private let history: TranscriptEntityHistory

    init() { self.history = .init() }
    init(snapshot: @escaping TranscriptEntityHistory.Snapshot) { self.history = .init(snapshot: snapshot) }

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [TranscriptEntity] {
        try self.history.metadata(for: identifiers)
    }

    func suggestedEntities() async throws -> [TranscriptEntity] { [] }
}
#endif
