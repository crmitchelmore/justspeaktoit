import Foundation

public enum DesktopHistoryDeletionError: Error, Equatable, Sendable {
    case recordDeleted(UUID)
    case invalidJournal
    case invalidCloudAccount
    case audioOwnershipUnclear
    case changedAudioOwnership
}

extension DesktopHistoryDeletionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .recordDeleted:
            return "This recording was deleted. Its pending result cannot restore History."
        case .invalidJournal:
            return "History's deletion journal is unreadable or unsupported. Deleted recordings were not restored."
        case .audioOwnershipUnclear:
            return "History could not verify exclusive ownership of this audio. Its files were not removed."
        case .changedAudioOwnership:
            return "The deleted recording's audio ownership changed. Cleanup stopped without removing the new file."
        case .invalidCloudAccount:
            return "History deletion requires a verified, non-empty iCloud account identifier."
        }
    }
}

/// One immutable cloud-delete attempt. Its revision prevents a late response
/// from acknowledging a newer deletion request.
public struct DesktopHistoryPendingDeletion: Equatable, Sendable {
    public let id: UUID
    public let account: String
    public let revision: UUID
}

struct DesktopHistoryDeletionLedger: Codable {
    struct Intent: Codable {
        let id: UUID
        var revision: UUID
        let audioFilename: String
        let deleteAudio: Bool?
        let account: String?
        var localCleanupPending: Bool
        var cloudPending: Bool
    }

    var version = 1
    var intents: [UUID: Intent] = [:]

    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(".history-deletions")
    }

    static func load(from directory: URL) throws -> Self {
        let url = url(in: directory)
        guard try regularFileExists(at: url) else { return Self() }
        let ledger: Self
        do {
            ledger = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        } catch is DecodingError {
            throw DesktopHistoryDeletionError.invalidJournal
        }
        guard ledger.version == 1,
              ledger.intents.allSatisfy({ $0.key == $0.value.id }) else {
            throw DesktopHistoryDeletionError.invalidJournal
        }
        return ledger
    }

    func save(in directory: URL) throws {
        let url = Self.url(in: directory)
        _ = try Self.regularFileExists(at: url)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func regularFileExists(at url: URL) throws -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        }
    }
}

extension DesktopRecordingStore {
    public func isDeleted(id: UUID) -> Bool { deletionLedger.intents[id] != nil }

    func requireRetained(_ id: UUID) throws {
        guard !isDeleted(id: id) else { throw DesktopHistoryDeletionError.recordDeleted(id) }
    }

    func isDeletedMetadata(_ url: URL) -> Bool {
        Self.recordID(ofMetadataFile: url).map { isDeleted(id: $0) } ?? false
    }

    /// Journals intent before removing anything. An interrupted cleanup remains
    /// hidden, rejects late saves, and can be retried after relaunch.
    public func delete(id: UUID, deleteAudio: Bool = true, cloudAccount: String? = nil) throws {
        guard cloudAccount?.isEmpty != true else { throw DesktopHistoryDeletionError.invalidCloudAccount }
        if deletionLedger.intents[id] == nil {
            let files = try deletionMetadata(id: id)
            let record = try files.first.map { try loadRecord(at: $0) }
            let audioFilename = record?.audioFilename ?? ""
            for file in files {
                guard try loadRecord(at: file).audioFilename == audioFilename else {
                    throw DesktopHistoryDeletionError.changedAudioOwnership
                }
            }
            if deleteAudio { try validateDeletionAudio(id: id, audioFilename: audioFilename) }
            var next = deletionLedger
            next.intents[id] = DesktopHistoryDeletionLedger.Intent(
                id: id,
                revision: UUID(),
                audioFilename: audioFilename,
                deleteAudio: deleteAudio,
                account: cloudAccount,
                localCleanupPending: true,
                cloudPending: cloudAccount != nil
            )
            try next.save(in: directory)
            deletionLedger = next
        }
        try finishLocalDeletion(id: id)
    }

    public func resumePendingDeletions() throws {
        var failure: (any Error)?
        for id in deletionLedger.intents.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            do {
                try finishLocalDeletion(id: id)
            } catch {
                if failure == nil { failure = error }
            }
        }
        if let failure { throw failure }
    }

    public func pendingCloudDeletions(account: String) -> [DesktopHistoryPendingDeletion] {
        deletionLedger.intents.values.filter { $0.cloudPending && $0.account == account }.map {
            DesktopHistoryPendingDeletion(id: $0.id, account: account, revision: $0.revision)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public func acknowledgeCloudDeletion(_ attempt: DesktopHistoryPendingDeletion) throws {
        guard let intent = deletionLedger.intents[attempt.id],
              intent.account == attempt.account, intent.revision == attempt.revision,
              intent.cloudPending else { return }
        var next = deletionLedger
        next.intents[attempt.id]?.cloudPending = false
        try next.save(in: directory)
        deletionLedger = next
    }

    /// A stale copy returned after acknowledgement still cannot restore this
    /// record. Reconcile it again only in the account that owned the deletion.
    public func requeueCloudDeletion(id: UUID, account: String) throws {
        guard let intent = deletionLedger.intents[id],
              intent.account == account, !intent.cloudPending else { return }
        var next = deletionLedger
        next.intents[id]?.revision = UUID()
        next.intents[id]?.cloudPending = true
        try next.save(in: directory)
        deletionLedger = next
    }

    private func deletionMetadata(id: UUID) throws -> [URL] {
        try metadataFiles().filter { Self.recordID(ofMetadataFile: $0) == id }
    }

    private func validateDeletionAudio(id: UUID, audioFilename: String) throws {
        guard !audioFilename.isEmpty else { return }
        let record = Record(id: id, audioFilename: audioFilename, modelIdentifier: "")
        do {
            _ = try ownedAudioURL(for: record)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // Missing owned audio does not prevent removing retained metadata.
            return
        }
        for file in try metadataFiles() where Self.recordID(ofMetadataFile: file) != id {
            let other: Record
            do {
                other = try loadRecord(at: file)
            } catch {
                throw DesktopHistoryDeletionError.audioOwnershipUnclear
            }
            #if os(Windows) || os(macOS)
            let sameName = other.audioFilename.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
                .caseInsensitiveCompare(audioFilename.trimmingCharacters(in: CharacterSet(charactersIn: " .")))
                == .orderedSame
            #else
            let sameName = other.audioFilename == audioFilename
            #endif
            guard !sameName else {
                throw DesktopHistoryDeletionError.audioOwnershipUnclear
            }
        }
    }

    private func finishLocalDeletion(id: UUID) throws {
        guard let intent = deletionLedger.intents[id], intent.localCleanupPending else { return }
        let files = try deletionMetadata(id: id)
        for file in files {
            guard try loadRecord(at: file).audioFilename == intent.audioFilename else {
                throw DesktopHistoryDeletionError.changedAudioOwnership
            }
        }
        if intent.deleteAudio != false {
            try validateDeletionAudio(id: id, audioFilename: intent.audioFilename)
        }
        if intent.deleteAudio != false, !intent.audioFilename.isEmpty {
            let record = Record(id: id, audioFilename: intent.audioFilename, modelIdentifier: "")
            let audio: URL?
            do {
                audio = try ownedAudioURL(for: record)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                audio = nil
            }
            if let audio { try FileManager.default.removeItem(at: audio) }
        }
        for file in files { try FileManager.default.removeItem(at: file) }
        var next = deletionLedger
        next.intents[id]?.localCleanupPending = false
        try next.save(in: directory)
        deletionLedger = next
    }
}
