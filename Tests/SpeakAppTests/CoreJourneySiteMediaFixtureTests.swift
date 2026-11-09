#if DEBUG
import Foundation
import SpeakCore
import XCTest
@testable import SpeakApp

final class CoreJourneySiteMediaFixtureTests: XCTestCase {
    func testSeedHistory_writesFictionalItemsThatHistoryCanDecode() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("site-media-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        try CoreJourneySiteMediaFixture.seedHistory(in: directory, now: now)

        let url = directory.appendingPathComponent(ReleaseTrain.current.supportDirectory)
            .appendingPathComponent("History/history-log.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let items = try decoder.decode([HistoryItem].self, from: Data(contentsOf: url))
        XCTAssertEqual(items.count, 5)
        XCTAssertTrue(items.allSatisfy { $0.audioFileURL == nil && $0.errors.isEmpty && $0.createdAt < now })
        XCTAssertTrue(items.allSatisfy { $0.modelsUsed == $0.modelUsages.map(\.modelIdentifier) })
        XCTAssertEqual(items.map(\.createdAt), items.map(\.createdAt).sorted(by: >))
    }

    func testSeedCorrections_writesRulesThatTheLexiconStoreLoads() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("site-media-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try CoreJourneySiteMediaFixture.seedCorrections(in: directory)

        let store = PersonalLexiconStore(baseDirectory: directory)
        let rules = try await store.load()
        XCTAssertEqual(rules.map(\.canonical), ["Lighthouse", "Saoirse", "Kestrel API"])
        XCTAssertTrue(rules.allSatisfy { !$0.aliases.isEmpty && $0.activation == .automatic })
    }
}
#endif
