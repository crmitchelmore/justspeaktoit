import Foundation
import SpeakCore

/// Canonical revision persistence; standings are always derived from the persisted rounds.
public actor DesktopComparisonStore {
    private struct Document: Codable {
        var revisions: [UUID: ModelComparisonRevision] = [:]
        var acknowledgements: [UUID: Date] = [:]
        var selectedModelIDs: Set<String>?
    }
    private var document: Document
    private var executing: Set<UUID> = []
    public nonisolated let directory: URL
    private let storageURL: URL
    private let write: @Sendable (Data, URL) throws -> Void

    public init(
        directory: URL,
        write: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    ) throws {
        self.directory = directory
        storageURL = directory.appendingPathComponent("rounds.json")
        self.write = write
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: storageURL.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let saved = try decoder.decode(Document.self, from: Data(contentsOf: storageURL))
            guard saved.revisions.allSatisfy({ $0.key == $0.value.id && $0.value.isValid }) else {
                throw DesktopComparisonError.message("Saved comparisons are corrupt. The original file was retained.")
            }
            document = saved
        } else { document = Document() }
    }

    public func rounds() -> [ModelComparisonRound] {
        document.revisions.values.compactMap(\.round).sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
        }
    }

    public func selectedModelIDs() -> Set<String> { document.selectedModelIDs ?? [] }

    public func selectModels(_ identifiers: Set<String>, replacing available: Set<String>) throws {
        guard identifiers.isSubset(of: available) else {
            throw DesktopComparisonError.message("A selected comparison model is not available.")
        }
        var next = document
        next.selectedModelIDs = (next.selectedModelIDs ?? []).subtracting(available).union(identifiers)
        try commit(next)
    }

    public func upsert(_ round: ModelComparisonRound, isExecuting: Bool = false) throws {
        guard round.isValid else { throw DesktopComparisonError.message("Invalid comparison round.") }
        var next = document
        next.revisions[round.id] = ModelComparisonRevision(round: round)
        next.acknowledgements[round.id] = nil
        try commit(next)
        if isExecuting { executing.insert(round.id) } else { executing.remove(round.id) }
    }

    public func pendingRevisions() -> [ModelComparisonRevision] {
        document.revisions.values.filter {
            !executing.contains($0.id) && document.acknowledgements[$0.id] != $0.updatedAt
        }
            .sorted { $0.updatedAt < $1.updatedAt }
    }

    public func revisions() -> [ModelComparisonRevision] {
        document.revisions.values.filter { !executing.contains($0.id) }.sorted { $0.updatedAt < $1.updatedAt }
    }

    public func endExecution(ids: Set<UUID>) {
        executing.subtract(ids)
    }

    public func remove(id: UUID, at date: Date = Date()) throws {
        guard !executing.contains(id) else {
            throw DesktopComparisonError.message("Finish or cancel the active comparison before deleting it.")
        }
        guard let round = document.revisions[id]?.round else {
            throw DesktopComparisonError.message("This comparison is no longer available.")
        }
        var next = document
        next.revisions[id] = ModelComparisonRevision(
            deleting: id, at: max(date, round.updatedAt.addingTimeInterval(0.001))
        )
        next.acknowledgements[id] = nil
        try commit(next)
        try discardSample(id: id)
    }

    public func applyRemoteRevision(_ revision: ModelComparisonRevision) throws {
        guard !executing.contains(revision.id) else {
            throw DesktopComparisonError.message("An active comparison cannot be changed by sync.")
        }
        guard revision.isValid else { throw DesktopComparisonError.message("Invalid comparison revision.") }
        if let local = document.revisions[revision.id] {
            if local.updatedAt > revision.updatedAt { return }
            if local.updatedAt == revision.updatedAt, local.round == nil, revision.round != nil { return }
        }
        var next = document
        next.revisions[revision.id] = revision
        next.acknowledgements[revision.id] = revision.updatedAt
        try commit(next)
        if revision.round == nil { try discardSample(id: revision.id) }
    }

    public func acknowledgeRevisions(_ revisions: [ModelComparisonRevision]) throws {
        var next = document
        for revision in revisions where next.revisions[revision.id] == revision {
            next.acknowledgements[revision.id] = revision.updatedAt
        }
        try commit(next)
    }

    public func applyLegacyDeletion(id: UUID) throws {
        guard !pendingRevisions().contains(where: { $0.id == id }),
              let round = document.revisions[id]?.round else { return }
        try applyRemoteRevision(ModelComparisonRevision(deleting: id, at: round.updatedAt))
    }

    public func pruneOrphanSamples() throws {
        let samples = directory.appendingPathComponent("Samples", isDirectory: true)
        guard FileManager.default.fileExists(atPath: samples.path) else { return }
        let retained = Set(rounds().map { $0.id.uuidString + ".wav" })
        let files = try FileManager.default.contentsOfDirectory(
            at: samples, includingPropertiesForKeys: [.isRegularFileKey]
        )
        for file in files where !retained.contains(file.lastPathComponent)
            && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
            try Task.checkCancellation()
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    private func discardSample(id: UUID) throws {
        let sample = directory.appendingPathComponent("Samples").appendingPathComponent(id.uuidString + ".wav")
        do {
            if FileManager.default.fileExists(atPath: sample.path) {
                guard try sample.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw DesktopComparisonError.message("The saved sample is not a regular audio file.")
                }
                try FileManager.default.removeItem(at: sample)
            }
        } catch {
            throw DesktopComparisonError.message(
                "The comparison was deleted, but its saved audio could not be removed: \(error.localizedDescription)"
            )
        }
    }

    private func commit(_ next: Document) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try write(encoder.encode(next), storageURL)
        document = next
    }

    public func judge(id: UUID, ranksInBlindOrder: [Int]) throws {
        guard !executing.contains(id), var round = document.revisions[id]?.round, !round.isJudged,
              ranksInBlindOrder.count == round.blindOrder.count else {
            throw DesktopComparisonError.message("Select an unjudged round and rank every result.")
        }
        let ranking = zip(round.blindOrder, ranksInBlindOrder).map {
            ModelComparisonRanking(entryID: $0.0, rank: $0.1)
        }
        let previousUpdate = round.updatedAt
        guard round.judge(rankings: ranking) else {
            throw DesktopComparisonError.message("Use each rank from 1 to \(round.entries.count) exactly once.")
        }
        round.updatedAt = max(round.updatedAt, previousUpdate.addingTimeInterval(0.001))
        try upsert(round)
    }
}
