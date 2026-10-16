import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopSync
import XCTest
@testable import SpeakSync

struct DesktopComparisonSyncFixture {
    let service: DesktopCloudSyncService
    let state: DesktopCloudSyncStateStore
    let store: DesktopComparisonStore
}

extension DesktopCloudSyncTestCase {
    func comparisonFixture(
        transport: (any CloudKitWebServicesHTTPTransport)? = nil,
        write: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    ) async throws -> DesktopComparisonSyncFixture {
        let (service, state) = try await signedInService(transport: transport)
        try await service.setHistoryEnabled(false)
        let store = try DesktopComparisonStore(directory: directory.appendingPathComponent("Comparisons"), write: write)
        await service.installComparisonStore(store)
        try await service.setComparisonEnabled(true)
        return DesktopComparisonSyncFixture(service: service, state: state, store: store)
    }

    func comparisonRound(id: UUID = UUID(), at date: Date = fixtureDate(10)) -> ModelComparisonRound {
        let entries = ["first", "second"].map {
            ModelComparisonEntry(
                modelID: "synthetic/\($0)", modelDisplayName: $0, providerDisplayName: "Synthetic",
                transcript: "Synthetic comparison words"
            )
        }
        return ModelComparisonRound(
            id: id, createdAt: date, inputMode: .file,
            sample: .init(name: "sample.wav", contentHash: nil, durationSeconds: 1),
            language: "en", originPlatform: "synthetic", entries: entries, blindOrder: entries.map(\.id)
        )
    }

    func seedComparison(_ revision: ModelComparisonRevision) throws {
        var fields: [String: (value: Any, type: String)] = [:]
        for assignment in try ComparisonRecordCodec.assignments(for: revision) {
            let data = try JSONEncoder().encode(CloudKitWebFieldPayload(value: assignment.value))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            fields[assignment.key] = (
                try XCTUnwrap(payload["value"]), try XCTUnwrap(payload["type"] as? String)
            )
        }
        server.seedRecord(
            zone: syncZone, recordName: SyncSchema.ComparisonRound.recordName(for: revision.id),
            recordType: SyncSchema.ComparisonRound.recordType, fields: fields
        )
    }

    func assertNoComparisonApplied(_ fixture: DesktopComparisonSyncFixture) async {
        let rounds = await fixture.store.rounds()
        let state = await fixture.state.current
        XCTAssertTrue(rounds.isEmpty)
        XCTAssertNil(state.comparisonCursor)
        XCTAssertTrue(state.comparisonAcknowledgements?.isEmpty ?? true)
    }
}
