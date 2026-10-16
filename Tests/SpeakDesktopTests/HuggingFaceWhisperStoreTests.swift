import Foundation
import XCTest
import SpeakCore
@testable import SpeakDesktop

final class HuggingFaceWhisperStoreTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws { directory = try LocalModelTestFiles.temporaryDirectory() }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private var store: HuggingFaceWhisperStore {
        HuggingFaceWhisperStore(directory: directory) {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }
    }

    func testAbsentStoreDoesNotImportMacReferencesAndMetadataSurvivesRestart() throws {
        try Data(#"[{"engine":"whisperkit","modelName":"tiny","modelRepo":"argmaxinc/whisperkit-coreml"}]"#.utf8)
            .write(to: directory.appendingPathComponent("imported-hugging-face-models.json"))
        XCTAssertEqual(try store.load(), [])
        let imported = try WhisperImportFixtures.model()
        try store.save([imported])
        XCTAssertEqual(try store.load(), [imported])
        let saved = String(decoding: try Data(contentsOf: store.url), as: UTF8.self)
        XCTAssertFalse(saved.contains("credential"))
        XCTAssertFalse(saved.contains("CoreML"))
    }

    func testDuplicateOversizeAndUnsupportedSchemaAreRejected() throws {
        let imported = try WhisperImportFixtures.model()
        XCTAssertThrowsError(try store.save([imported, imported]))
        try Data(#"{"version":2,"models":[]}"#.utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load())
        try Data(repeating: 32, count: 128 * 1_024 + 1).write(to: store.url)
        XCTAssertThrowsError(try store.load())
    }

    func testFailedAtomicWritePreservesPreviouslyImportedMetadata() throws {
        let imported = try WhisperImportFixtures.model()
        try store.save([imported])
        let previous = try Data(contentsOf: store.url)
        let refused = HuggingFaceWhisperStore(directory: directory) { _ in
            throw CocoaError(.fileWriteNoPermission)
        }
        XCTAssertThrowsError(try refused.save([]))
        XCTAssertEqual(try Data(contentsOf: store.url), previous)
        XCTAssertEqual(try store.load(), [imported])
    }

    #if !os(Windows)
    func testSymlinkStoreIsNotFollowedOrOverwritten() throws {
        let outside = directory.appendingPathComponent("outside.json")
        let marker = Data("do not replace".utf8)
        try marker.write(to: outside)
        try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: outside)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save([]))
        XCTAssertEqual(try Data(contentsOf: outside), marker)
    }
    #endif

    func testAppendingImportsDoesNotReassignNativeSlotsOrEnterLiveMode() throws {
        var slots = DesktopModelSlots(live: DesktopLiveTranscription.liveModels)
        let before = slots.entries.map { $0.option.id }
        let imported = try WhisperImportFixtures.model()
        try slots.appendLocal([DesktopLocalTranscription.option(imported.model)])
        XCTAssertEqual(Array(slots.entries.prefix(before.count)).map { $0.option.id }, before)
        let index = try XCTUnwrap(slots.entries.firstIndex { $0.option.id == imported.id })
        XCTAssertTrue(slots.entries[index].isLocal)
        XCTAssertFalse(slots.entries[index].isLive)
        try slots.update(discovered: [], retaining: [imported.id])
        XCTAssertEqual(slots.entries[index].option.id, imported.id)
        XCTAssertTrue(slots.visibleIndices.contains(index))
        DesktopLocalTranscription.rememberImportedNames([imported])
        XCTAssertEqual(DesktopHistorySearch.modelDisplayName(for: imported.id), imported.displayName + " (on-device)")
        XCTAssertEqual(DesktopHistoryRetry.route(for: imported.id), .onDevice)
    }

    func testImportAndNativeSlotCapacityFailuresAreAtomic() throws {
        let first = try WhisperImportFixtures.model()
        try store.save([first])
        let models = try (0...HuggingFaceWhisperStore.maximumModels).map { index in
            try HuggingFaceWhisperModel(
                repository: first.repository, filename: first.filename, revision: first.revision,
                byteCount: first.byteCount,
                sha256: String(repeating: "0", count: 62) + String(format: "%02x", index), license: first.license
            )
        }
        XCTAssertThrowsError(try store.save(models)) {
            XCTAssertEqual($0 as? HuggingFaceWhisperError, .importLimit)
        }
        XCTAssertEqual(try store.load(), [first])
        var slots = DesktopModelSlots(live: [], maximumSlots: 0)
        let before = slots.entries.map { $0.option.id }
        let visible = slots.visibleIndices
        XCTAssertThrowsError(try slots.appendLocal([DesktopLocalTranscription.option(first.model)]))
        XCTAssertEqual(slots.entries.map { $0.option.id }, before)
        XCTAssertEqual(slots.visibleIndices, visible)
    }
}
