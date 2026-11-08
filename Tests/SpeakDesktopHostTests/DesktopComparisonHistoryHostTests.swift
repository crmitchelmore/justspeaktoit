import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

/// "Save results to History" on Windows and Linux: off by default, and when
/// on, each lane of a finished round becomes one tagged local History record.
final class DesktopComparisonHistoryHostTests: XCTestCase {
    func testSaveResultsToHistory_IsOptInAndAddsOneTaggedRecordPerModel() async throws {
        DesktopHostModels.configure(streamingQualified: false)
        defer { DesktopHostModels.configure(streamingQualified: true) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.wav")
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(repeating: 4, count: 3200), sampleRate: 16_000))
            .write(to: source)
        let effects = ComparisonHostEffects(sourceToMutate: root.appendingPathComponent("unused"))
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: effects)
        await controller.markReadyForSelfTest()
        let models = ["openai/whisper-1", "openai/gpt-4o-transcribe"]
        let payload = "\n" + models.joined(separator: "\t") + "\n" + source.path

        await controller.comparisonEvent(102, text: payload, index: 0)
        await controller.comparisonTask?.value
        var history = try await controller.store.records()
        XCTAssertTrue(history.isEmpty, "Off by default: a comparison never touches History")

        await controller.comparisonEvent(129, text: "", index: 1)
        let comparisons = try await controller.loadComparisonStore()
        let enabled = await comparisons.savesResultsToHistory()
        XCTAssertTrue(enabled)
        await controller.comparisonEvent(102, text: payload, index: 0)
        await controller.comparisonTask?.value
        history = try await controller.store.records()
        XCTAssertEqual(history.count, models.count)
        XCTAssertEqual(Set(history.map(\.modelIdentifier)), Set(models))
        XCTAssertTrue(history.allSatisfy(DesktopComparisonHistory.isComparisonRecord))
        XCTAssertTrue(history.allSatisfy { $0.originPlatform == nil && $0.audioFilename.isEmpty })
        XCTAssertTrue(history.allSatisfy { $0.result != nil || $0.failure != nil })

        await controller.comparisonEvent(129, text: "", index: 0)
        await controller.comparisonEvent(102, text: payload, index: 0)
        await controller.comparisonTask?.value
        history = try await controller.store.records()
        XCTAssertEqual(history.count, models.count, "Turning it off stops further History writes")
        await controller.close()
    }
}
