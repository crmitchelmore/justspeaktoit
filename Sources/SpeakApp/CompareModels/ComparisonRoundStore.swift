import Foundation
import SpeakCore

/// Local persistence for Compare Models rounds (issue #1101).
///
/// Rounds are small (a few transcripts each) and rare (one per judgement),
/// so the whole set lives in one JSON file rewritten atomically on change,
/// beside History in the train's Application Support folder. Sync hooks
/// mirror `HistoryManager`'s so `MacComparisonSyncAdapter` can echo local
/// changes to CloudKit and apply remote ones without a round trip.
@MainActor
final class ComparisonRoundStore: ObservableObject {
    /// Newest first.
    @Published private(set) var rounds: [ModelComparisonRound] = []
    @Published private(set) var persistenceError: String?

    /// Fired for local inserts and updates, not for remote applications.
    var onRoundUpserted: ((ModelComparisonRound) -> Void)?
    /// Fired for local removals, not for remote deletions.
    var onRoundRemoved: ((UUID) -> Void)?

    let storageURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let log = SpeakLogger.logger(category: "ComparisonRoundStore")

    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        return supportURL
            .appendingPathComponent(ReleaseTrain.current.supportDirectory, isDirectory: true)
            .appendingPathComponent("Comparisons", isDirectory: true)
    }

    init(directory: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        storageURL = directory.appendingPathComponent("rounds.json", isDirectory: false)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        load()
    }

    convenience init(fileManager: FileManager = .default) {
        self.init(directory: Self.defaultDirectory(fileManager: fileManager), fileManager: fileManager)
    }

    /// The folder where microphone captures are kept so a round's sample can
    /// be re-run through other models later.
    var samplesDirectory: URL {
        let url = storageURL.deletingLastPathComponent().appendingPathComponent("Samples", isDirectory: true)
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    var allRounds: [ModelComparisonRound] { rounds }

    func round(id: UUID) -> ModelComparisonRound? {
        rounds.first { $0.id == id }
    }

    /// Inserts or replaces a round authored on this Mac.
    func upsert(_ round: ModelComparisonRound) {
        place(round)
        persist()
        onRoundUpserted?(round)
    }

    func remove(id: UUID) {
        guard rounds.contains(where: { $0.id == id }) else { return }
        rounds.removeAll { $0.id == id }
        persist()
        onRoundRemoved?(id)
    }

    /// Applies a round from CloudKit. Returns `true` when the store changed;
    /// a local copy at least as new as the remote one is kept.
    @discardableResult
    func applyRemote(_ round: ModelComparisonRound) -> Bool {
        if let local = self.round(id: round.id), local.updatedAt >= round.updatedAt {
            return false
        }
        place(round)
        persist()
        return true
    }

    func removeRemote(id: UUID) {
        guard rounds.contains(where: { $0.id == id }) else { return }
        rounds.removeAll { $0.id == id }
        persist()
    }

    private func place(_ round: ModelComparisonRound) {
        rounds.removeAll { $0.id == round.id }
        rounds.append(round)
        rounds.sort { $0.createdAt > $1.createdAt }
    }

    private func load() {
        guard fileManager.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            rounds = try decoder.decode([ModelComparisonRound].self, from: data)
                .sorted { $0.createdAt > $1.createdAt }
        } catch {
            persistenceError = "Could not read saved comparisons: \(error.localizedDescription)"
            log.error("Failed to load comparison rounds: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist() {
        do {
            let data = try encoder.encode(rounds)
            try data.write(to: storageURL, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = "Could not save comparisons: \(error.localizedDescription)"
            log.error("Failed to save comparison rounds: \(error.localizedDescription, privacy: .public)")
        }
    }
}
