import Foundation
import SpeakCore
import SpeakDesktop
import XCTest

final class DesktopProfileRawEditingTests: XCTestCase {
    private var directory: URL!
    private var store: DesktopDictationProfileStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("profile-edit-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = DesktopDictationProfileStore(directory: directory)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func fixture() throws -> Data {
        let objects: [[String: Any]] = [[
            "id": UUID().uuidString, "name": "Future", "transcriptionModelID": "local/future",
            "transcriptionRouting": "future-on-device", "futureOptions": ["keep": [1, 2, 3]],
            "matchers": [["kind": "futureMatcher", "value": "opaque", "metadata": true],
                         ["kind": "bundleID", "value": "com.apple.mail", "newField": "keep"]]
        ]]
        let data = try JSONSerialization.data(withJSONObject: objects)
        try data.write(to: store.fileURL)
        return data
    }

    private func objects() throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [[String: Any]])
    }

    func testRenameAndDuplicatePreserveUnknownFieldsMatchersRoutingAndRawTransferInput() throws {
        let original = try fixture()
        var profiles = try store.load()
        let source = try XCTUnwrap(profiles.first)
        let encoded = try DictationProfile.encodeList([source])
        XCTAssertEqual(try DictationProfile.decodeList(encoded).first?.unsupportedTranscriptionRouting,
                       source.unsupportedTranscriptionRouting)
        profiles[0].name = "Renamed"
        var copy = profiles[0]
        copy.id = UUID()
        copy.name = "Copy"
        profiles.append(copy)
        try store.savePreservingUnknownFields(profiles, copiedFrom: [copy.id: source.id], expectedDocument: original)
        let raw = try objects()
        XCTAssertEqual(raw.count, 2)
        for object in raw {
            XCTAssertEqual(object["transcriptionRouting"] as? String, "future-on-device")
            XCTAssertNotNil(object["futureOptions"])
            let matchers = try XCTUnwrap(object["matchers"] as? [[String: Any]])
            XCTAssertEqual(matchers.first?["kind"] as? String, "futureMatcher")
            XCTAssertEqual(matchers.last?["newField"] as? String, "keep")
        }
        let records = try DataMigrationProfileCatalog.records(data: store.rawDocument(), digest: { _ in "fixture" })
        XCTAssertEqual(records.count, 2, "Transfer reads the preserved raw file, not the lossy runtime projection.")
        let session = DesktopProfileSessionResolver.resolve(
            profile: try store.load().first, defaultModel: ModelCatalog.defaultBatchTranscriptionModel,
            defaultPostProcessing: .init(), capabilities: .shared
        )
        XCTAssertFalse(session.canRecord)
        XCTAssertTrue(session.limitations.contains(.transcriptionRoutingUnavailable("future-on-device")))
    }

    func testExplicitReplacementClearsFutureRouteButUnchangedOverridesDoNot() throws {
        let document = try fixture()
        var profiles = try store.load()
        profiles[0].transcriptionModelID = nil
        profiles[0].transcriptionRouting = nil
        profiles[0].unsupportedTranscriptionRouting = nil
        try store.savePreservingUnknownFields(profiles, expectedDocument: document)
        let raw = try XCTUnwrap(objects().first)
        XCTAssertNil(raw["transcriptionRouting"])
        XCTAssertNil(raw["transcriptionModelID"])
        XCTAssertNotNil(raw["futureOptions"])
    }

    func testStaleEditorCannotOverwriteNewerRawFieldsOrOrder() throws {
        let document = try fixture()
        let profiles = try store.load()
        var newer = document
        newer.append(0x20)
        try newer.write(to: store.fileURL)
        XCTAssertThrowsError(try store.savePreservingUnknownFields(profiles, expectedDocument: document))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), newer)
    }

    func testEmptyExistingDocumentIsCorruptNotPermissionToReplaceIt() throws {
        let missing = try store.loadForEditing()
        XCTAssertTrue(missing.profiles.isEmpty)
        try Data().write(to: store.fileURL)
        XCTAssertThrowsError(try store.loadForEditing())
        XCTAssertThrowsError(try store.savePreservingUnknownFields([DictationProfile(name: "New")]))
        XCTAssertTrue(try Data(contentsOf: store.fileURL).isEmpty)
    }
}
