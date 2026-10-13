import Foundation
import SpeakCore

/// Canonical revision persistence; standings are always derived from the persisted rounds.
public actor DesktopComparisonStore {
    private struct Document: Codable {
        var revisions: [UUID: ModelComparisonRevision] = [:]
        var acknowledgements: [UUID: Date] = [:]
    }
    private var document: Document
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

    public func upsert(_ round: ModelComparisonRound) throws {
        guard round.isValid else { throw DesktopComparisonError.message("Invalid comparison round.") }
        var next = document
        next.revisions[round.id] = ModelComparisonRevision(round: round)
        next.acknowledgements[round.id] = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try write(encoder.encode(next), storageURL)
        document = next
    }

    public func judge(id: UUID, ranksInBlindOrder: [Int]) throws {
        guard var round = document.revisions[id]?.round, !round.isJudged,
              ranksInBlindOrder.count == round.blindOrder.count else {
            throw DesktopComparisonError.message("Select an unjudged round and rank every result.")
        }
        let ranking = zip(round.blindOrder, ranksInBlindOrder).map {
            ModelComparisonRanking(entryID: $0.0, rank: $0.1)
        }
        guard round.judge(rankings: ranking) else {
            throw DesktopComparisonError.message("Use each rank from 1 to \(round.entries.count) exactly once.")
        }
        try upsert(round)
    }
}
