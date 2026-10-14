import Foundation
import SpeakCore
import XCTest
@testable import SpeakApp

private final class KindScopeMigrationFileManager: FileManager, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func urls(
        for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask
    ) -> [URL] {
        directory == .applicationSupportDirectory ? [root] : super.urls(for: directory, in: domainMask)
    }
}

@MainActor
final class DataMigrationKindScopeInteropTests: XCTestCase {
    @MainActor
    private struct Fixture {
        let root: URL
        let suite: String
        let defaults: UserDefaults
        let history: HistoryManager
        let store: MigrationStore

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            suite = "kind-scope-migration-\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            history = HistoryManager(
                fileManager: KindScopeMigrationFileManager(root: root), flushInterval: 3600,
                batchSizeThreshold: 10000
            )
            store = MigrationStore(
                defaults: defaults, support: root.appendingPathComponent("SpeakApp"), history: history,
                secrets: SecureStorage(configuration: .init(service: suite))
            )
        }

        func clean() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testHistoryKindReplace_PreservesRawSpeechUsageWithSameIdentifierThroughMacApply() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let id = UUID().uuidString
        let usage = TTSUsageRecord(
            provider: .openai, voice: "fixture", duration: 1, characterCount: 4, cost: nil,
            timestamp: Date(timeIntervalSince1970: 10)
        )
        var raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(usage)) as? [String: Any]
        )
        raw["id"] = id
        raw["futureMetadata"] = ["retained": true]
        let value = AnyCodable(raw)
        fixture.defaults.set(try JSONEncoder().encode([value]), forKey: "ttsUsageHistory")
        let imported = MigrationRecord(
            id: id, kind: "history", value: try HistoryItem.placeholder.migrationValue(id: id)
        )
        let incoming = MigrationSnapshot(
            manifest: .init(categories: [.history], scopes: ["history": .init(selectedKinds: ["history"])]),
            records: [.history: [imported]]
        )
        try await apply(incoming, category: .history, fixture: fixture)
        XCTAssertEqual(fixture.history.allItems.map { $0.id.uuidString }, [id])
        let retained = try JSONDecoder().decode(
            [AnyCodable].self, from: XCTUnwrap(fixture.defaults.data(forKey: "ttsUsageHistory"))
        )
        XCTAssertEqual(retained, [value])
        let collected = try await fixture.store.snapshot(categories: [.history])
        XCTAssertEqual(collected.records[.history]?.filter { $0.kind == "ttsUsage" }.map(\.value), [value])
    }

    func testCoveredPreferenceReplace_PreservesOtherDefaultsThroughMacApply() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.defaults.set("dark", forKey: "appearance")
        fixture.defaults.set(true, forKey: "showHUD")
        let incoming = MigrationSnapshot(
            manifest: .init(
                categories: [.settings],
                scopes: ["settings": .init(selectedIDs: ["showHUD"], selectedKinds: ["default", "jsonDefault"])]
            ),
            records: [.settings: [.init(id: "showHUD", kind: "default", value: AnyCodable(.bool(false)))]]
        )
        try await apply(incoming, category: .settings, fixture: fixture)
        XCTAssertFalse(fixture.defaults.bool(forKey: "showHUD"))
        XCTAssertEqual(fixture.defaults.string(forKey: "appearance"), "dark")
    }

    func testMacExport_HonorsCoveredPreferenceKeysAndKinds() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.defaults.set("dark", forKey: "appearance")
        fixture.defaults.set(true, forKey: "showHUD")
        let snapshot = try await fixture.store.snapshot(
            categories: [.settings],
            scopes: ["settings": .init(selectedIDs: ["showHUD"], selectedKinds: ["default"])]
        )
        XCTAssertEqual(snapshot.records[.settings]?.map(\.id), ["showHUD"])
        let empty = try await fixture.store.snapshot(
            categories: [.settings], scopes: ["settings": .init(selectedKinds: [])]
        )
        XCTAssertEqual(empty.records[.settings], [])
    }

    private func apply(
        _ incoming: MigrationSnapshot, category: MigrationCategory, fixture: Fixture
    ) async throws {
        let current = try await fixture.store.snapshot(categories: [category])
        let checked = fixture.store.validate(incoming)
        XCTAssertTrue(checked.notices.isEmpty, checked.notices.joined(separator: "\n"))
        let plan = try MigrationPlanner.plan(
            current: current, incoming: checked, modes: [category: .replace], useImported: []
        )
        try await fixture.store.apply(plan, categories: [category])
    }
}
