import Foundation
import SpeakCore
import SpeakDesktop

struct DesktopComparisonImportPlan {
    let source: URL
    let id: UUID
    let sourceBytes: Int
}

final class DesktopComparisonImportBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let staging: DesktopComparisonStaging
    private let id: UUID
    private var bytes: Int
    private var entries: [String: Int]
    private let audioBytes: Int

    init(round: ModelComparisonRound, audioBytes: Int, staging: DesktopComparisonStaging) throws {
        self.staging = staging
        id = round.id
        self.audioBytes = audioBytes
        entries = try Dictionary(uniqueKeysWithValues: round.entries.map {
            ($0.modelID, try Self.encoder().encode($0).count)
        })
        bytes = audioBytes + (try Self.metadataBytes(round)) + Self.margin(round.entries.count)
        try staging.reserve(id: id, bytes: bytes)
    }

    func record(_ entry: ModelComparisonEntry) throws {
        let count = try Self.encoder().encode(entry).count
        try lock.withLock {
            guard let previous = entries[entry.modelID] else {
                throw DesktopHostError(message: "The comparison result is outside its frozen snapshot.")
            }
            let next = bytes + count - previous - 256
            try staging.reserve(id: id, bytes: next)
            bytes = next
            entries[entry.modelID] = nil
        }
    }

    func finish(_ round: ModelComparisonRound) throws {
        try staging.reserve(id: id, bytes: audioBytes + Self.metadataBytes(round))
    }

    static func metadataBytes(_ round: ModelComparisonRound) throws -> Int {
        // Include the enclosing document's revision key and separators.
        try encoder().encode(ModelComparisonRevision(round: round)).count + 64
    }

    static func margin(_ entryCount: Int) -> Int { (entryCount + 1) * 256 }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
