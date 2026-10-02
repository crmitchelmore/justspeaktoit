import Foundation
import SpeakCore
import XCTest
@testable import SpeakDesktop

final class DesktopModelSlotsTests: XCTestCase {
    func testInitialSlotsUseCanonicalBatchDefaultAndLiveProjection() {
        let live = DesktopLiveTranscription.liveModels
        let slots = DesktopModelSlots(live: live)
        XCTAssertEqual(slots.entries.map(\.option.id), DesktopTranscription.batchModels.map(\.id) + live.map(\.id))
        XCTAssertTrue(slots.entries.contains { $0.option.id == ModelCatalog.defaultBatchTranscriptionModel })
        XCTAssertEqual(slots.visibleIndices, Array(slots.entries.indices))
        XCTAssertEqual(slots.entries.filter(\.isLive).map(\.option.id), live.map(\.id))
        XCTAssertTrue(slots.entries.allSatisfy(\.isAvailable))
    }

    func testRefreshReordersAndRenamesVisibleModelsWithoutChangingEventIdentities() throws {
        var slots = DesktopModelSlots(live: DesktopLiveTranscription.liveModels)
        let initial = slots.entries.map(\.option.id)
        let alpha = try model("vendor/alpha", name: "Alpha")
        let beta = try model("vendor/beta", name: "Beta")
        try slots.update(discovered: [alpha, beta], retaining: [])
        let identities = slots.entries.map(\.option.id)
        let alphaIndex = try XCTUnwrap(identities.firstIndex(of: alpha.transcriptionSelectionID))
        let betaIndex = try XCTUnwrap(identities.firstIndex(of: beta.transcriptionSelectionID))
        try slots.update(discovered: [beta, model("vendor/alpha", name: "Updated Alpha")], retaining: [])
        XCTAssertEqual(slots.entries.map(\.option.id), identities)
        XCTAssertEqual(Array(identities.prefix(initial.count)), initial)
        XCTAssertEqual(slots.entries[alphaIndex].option.displayName, "Updated Alpha")
        XCTAssertLessThan(try XCTUnwrap(slots.visibleIndices.firstIndex(of: betaIndex)),
                          try XCTUnwrap(slots.visibleIndices.firstIndex(of: alphaIndex)))
        XCTAssertFalse(slots.entries[alphaIndex].isLive)
    }

    func testRetiredSelectedModelStaysVisibleAndRoutableWithUnavailableState() throws {
        var slots = DesktopModelSlots(live: [])
        let selected = try model("vendor/retired", name: "Retained friendly name")
        try slots.update(discovered: [selected], retaining: [])
        let index = try XCTUnwrap(slots.entries.firstIndex { $0.option.id == selected.transcriptionSelectionID })
        try slots.update(discovered: [], retaining: [selected.transcriptionSelectionID])
        XCTAssertTrue(slots.visibleIndices.contains(index))
        XCTAssertFalse(slots.entries[index].isAvailable)
        XCTAssertEqual(slots.entries[index].option.displayName, "Retained friendly name")
        XCTAssertNotNil(DesktopTranscription.provider(for: slots.entries[index].option.id))
        try slots.update(discovered: [selected], retaining: [selected.transcriptionSelectionID])
        XCTAssertTrue(slots.entries[index].isAvailable)
        XCTAssertEqual(slots.entries.filter { $0.option.id == selected.transcriptionSelectionID }.count, 1)
    }

    func testMissingCachedSelectionGetsVisibleSlotWhileMalformedSelectionsAreIgnored() throws {
        var slots = DesktopModelSlots(live: [])
        let saved = OpenRouterTranscriptionSelection.identifier(for: "vendor/not-cached")
        try slots.update(discovered: [], retaining: [saved, saved, "not/a/real/provider", "openrouter/transcription/"])
        let index = try XCTUnwrap(slots.entries.firstIndex { $0.option.id == saved })
        XCTAssertEqual(slots.entries[index].option.displayName, "vendor/not-cached")
        XCTAssertFalse(slots.entries[index].isAvailable)
        XCTAssertTrue(slots.visibleIndices.contains(index))
        XCTAssertEqual(slots.entries.count, DesktopTranscription.batchModels.count + 1)
    }

    func testRetirementHidesUnusedModelButKeepsSlotForAlreadyQueuedEvents() throws {
        var slots = DesktopModelSlots(live: [])
        let retired = try model("vendor/retired")
        try slots.update(discovered: [retired], retaining: [])
        let index = try XCTUnwrap(slots.entries.firstIndex { $0.option.id == retired.transcriptionSelectionID })
        let newcomer = try model("vendor/new")
        try slots.update(discovered: [newcomer], retaining: [])
        XCTAssertEqual(slots.entries[index].option.id, retired.transcriptionSelectionID)
        XCTAssertFalse(slots.visibleIndices.contains(index))
        XCTAssertFalse(slots.entries[index].isAvailable)
        XCTAssertEqual(slots.entries.last?.option.id, newcomer.transcriptionSelectionID)
    }

    func testCapacityFailureLeavesExistingSlotsAndVisibilityUnchanged() throws {
        var slots = DesktopModelSlots(live: [], maximumSlots: DesktopTranscription.batchModels.count + 1)
        let first = try model("vendor/first")
        try slots.update(discovered: [first], retaining: [])
        let previous = slots.entries.map(\.option)
        let visibility = slots.visibleIndices
        XCTAssertThrowsError(try slots.update(discovered: [model("vendor/second")], retaining: [])) { error in
            guard case DesktopModelSlots.Failure.capacityExceeded = error else { return XCTFail("Unexpected \(error)") }
        }
        XCTAssertEqual(slots.entries.map(\.option), previous)
        XCTAssertEqual(slots.visibleIndices, visibility)
        XCTAssertTrue(slots.entries.allSatisfy(\.isAvailable))
    }

    func testSpeechOnlyDiscoveryDoesNotLeakIntoTranscriptionPicker() throws {
        var slots = DesktopModelSlots(live: [])
        let speech = try model("vendor/speech", capability: "speech")
        let audio = try model("vendor/audio")
        try slots.update(discovered: [speech, audio, audio], retaining: [])
        XCTAssertEqual(slots.entries.count, DesktopTranscription.batchModels.count + 1)
        XCTAssertEqual(slots.entries.last?.option.id, audio.transcriptionSelectionID)
    }

    private func model(
        _ id: String, name: String = "Discovered model", capability: String = "transcription"
    ) throws -> OpenRouterAudioModel {
        let json: [String: Any] = [
            "id": id, "name": name,
            "architecture": ["input_modalities": ["audio"], "output_modalities": [capability]]
        ]
        return try JSONDecoder().decode(OpenRouterAudioModel.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
