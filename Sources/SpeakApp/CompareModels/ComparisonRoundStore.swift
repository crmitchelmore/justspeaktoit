import Foundation
import SpeakCore

/// Rounds, deletion tombstones and revision acknowledgements commit atomically.
@MainActor
final class ComparisonRoundStore: ObservableObject {
    @Published private(set) var rounds: [ModelComparisonRound] = []
    @Published private(set) var persistenceError: String?
    @Published var syncError: String?
    var onRoundUpserted: ((ModelComparisonRound) -> Void)?
    var onRoundRemoved: ((UUID) -> Void)?

    private struct Document: Codable {
        var revisions: [UUID: ModelComparisonRevision] = [:]
        var acknowledgements: [UUID: Date] = [:]
    }

    private var document = Document()
    let storageURL: URL
    private let fileManager: FileManager
    private let write: (Data, URL) throws -> Void
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        return root.appendingPathComponent(ReleaseTrain.current.supportDirectory)
            .appendingPathComponent("Comparisons", isDirectory: true)
    }

    init(directory: URL, fileManager: FileManager = .default,
         write: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.fileManager = fileManager
        self.write = write
        storageURL = directory.appendingPathComponent("rounds.json")
        // Preserve sub-second revision identity. Legacy arrays used ISO dates.
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: storageURL.path) {
                let data = try Data(contentsOf: storageURL)
                if let saved = try? decoder.decode(Document.self, from: data) {
                    guard saved.revisions.allSatisfy({ $0.key == $0.value.id && $0.value.isValid }) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    document = saved
                } else {
                    let legacy = JSONDecoder()
                    legacy.dateDecodingStrategy = .iso8601
                    for round in try legacy.decode([ModelComparisonRound].self, from: data) {
                        document.revisions[round.id] = ModelComparisonRevision(round: round)
                    }
                }
                refreshRounds()
                removeUnusedSamples()
            }
        } catch {
            persistenceError = "Could not read saved comparisons: \(error.localizedDescription)"
        }
    }

    convenience init(fileManager: FileManager = .default) {
        self.init(directory: Self.defaultDirectory(fileManager: fileManager), fileManager: fileManager)
    }

    var samplesDirectory: URL {
        let url = storageURL.deletingLastPathComponent().appendingPathComponent("Samples", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var allRounds: [ModelComparisonRound] { rounds }
    var pendingRevisions: [ModelComparisonRevision] {
        document.revisions.values.filter { document.acknowledgements[$0.id] != $0.updatedAt }
            .sorted { $0.updatedAt < $1.updatedAt }
    }

    func round(id: UUID) -> ModelComparisonRound? { document.revisions[id]?.round }

    @discardableResult
    func upsert(_ round: ModelComparisonRound) -> Bool {
        guard round.isValid else { return false }
        var next = document
        next.revisions[round.id] = ModelComparisonRevision(round: round)
        next.acknowledgements[round.id] = nil
        guard save(next) else { return false }
        onRoundUpserted?(round)
        return true
    }

    func remove(id: UUID) {
        guard let round = round(id: id) else { return }
        var next = document
        next.revisions[id] = ModelComparisonRevision(deleting: id, at: max(Date(), round.updatedAt.addingTimeInterval(0.001)))
        next.acknowledgements[id] = nil
        guard save(next) else { return }
        discardSample(for: round)
        onRoundRemoved?(id)
    }

    /// Remote changes are acknowledged only after the entire mutation is durable.
    func applyRevision(_ revision: ModelComparisonRevision) throws {
        guard revision.isValid else { throw CocoaError(.fileReadCorruptFile) }
        if let local = document.revisions[revision.id] {
            if local.updatedAt > revision.updatedAt { return }
            if local.updatedAt == revision.updatedAt, local.round == nil, revision.round != nil { return }
        }
        let old = round(id: revision.id)
        var next = document
        next.revisions[revision.id] = revision
        next.acknowledgements[revision.id] = revision.updatedAt
        try commit(next)
        if revision.round == nil, let old { discardSample(for: old) }
    }

    func acknowledge(_ revisions: [ModelComparisonRevision]) throws {
        var next = document
        for revision in revisions where next.revisions[revision.id] == revision {
            next.acknowledgements[revision.id] = revision.updatedAt
        }
        try commit(next)
    }

    @discardableResult
    func applyRemote(_ round: ModelComparisonRound) -> Bool {
        guard (self.round(id: round.id)?.updatedAt ?? .distantPast) < round.updatedAt else { return false }
        do { try applyRevision(ModelComparisonRevision(round: round)); return true } catch { return false }
    }

    /// Legacy hard deletions have no date. Preserve pending local changes.
    func removeRemote(id: UUID) {
        guard !pendingRevisions.contains(where: { $0.id == id }), let round = round(id: id) else { return }
        try? applyRevision(ModelComparisonRevision(deleting: id, at: round.updatedAt))
    }

    func discardSample(for round: ModelComparisonRound) {
        guard round.inputMode == .streaming,
              !rounds.contains(where: { $0.inputMode == .streaming && $0.sample.name == round.sample.name }),
              round.sample.name == URL(fileURLWithPath: round.sample.name).lastPathComponent else { return }
        let url = samplesDirectory.appendingPathComponent(round.sample.name)
        do {
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        } catch {
            persistenceError = "Could not delete the saved recording: \(error.localizedDescription)"
        }
    }

    private func removeUnusedSamples() {
        // This directory contains only app-owned captures, never imported audio.
        let retained = Set(rounds.filter { $0.inputMode == .streaming }.map(\.sample.name))
        for url in (try? fileManager.contentsOfDirectory(at: samplesDirectory, includingPropertiesForKeys: nil)) ?? []
            where url.pathExtension == "wav" && !retained.contains(url.lastPathComponent) {
            do { try fileManager.removeItem(at: url) } catch {
                persistenceError = "Could not delete an unused recording: \(error.localizedDescription)"
            }
        }
    }

    private func refreshRounds() {
        rounds = document.revisions.values.compactMap(\.round).sorted { $0.createdAt > $1.createdAt }
    }

    private func save(_ next: Document) -> Bool {
        do { try commit(next); return true } catch { return false }
    }

    private func commit(_ next: Document) throws {
        do {
            try write(encoder.encode(next), storageURL)
            document = next
            refreshRounds()
            persistenceError = nil
        } catch {
            persistenceError = "Could not save comparisons: \(error.localizedDescription)"
            throw error
        }
    }
}
