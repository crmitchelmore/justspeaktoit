import Foundation
import SpeakCore
import SpeakDesktop
import XCTest

final class DataMigrationProfileCatalogTests: XCTestCase {
    private let id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    func testRawProfiles_PreservePromptsUnknownMatchersAndRouting() throws {
        let data = Data("""
        [{
          "id":"\(id)","name":"Profile","polishPrompt":"Keep this exact prompt\\nSecond line",
          "polishEnabled":false,"polishOutputLanguage":"","transcriptionRouting":"future-routing",
          "matchers":[{"kind":"bundleID","value":"com.example.app"},
                      {"kind":"future-matcher","value":"retained","future":7}],
          "futureMetadata":{"enabled":false,"count":0}
        }]
        """.utf8)
        let raw = try JSONDecoder().decode([AnyCodable].self, from: data)
        let records = try DataMigrationProfileCatalog.records(data: data, digest: { _ in
            XCTFail("An explicit profile ID must not be replaced by a payload digest.")
            return ""
        })
        XCTAssertEqual(records.map(\.value), raw)
        XCTAssertEqual(records.map(\.id), [id])
        XCTAssertNil(records[0].date)
        XCTAssertNoThrow(try DataMigrationProfileCatalog.validate(records[0], category: .profiles))
        let runtime = try DataMigrationCoding.decode(DictationProfile.self, records[0].value)
        XCTAssertEqual(runtime.polishPrompt, "Keep this exact prompt\nSecond line")
        XCTAssertEqual(runtime.matchers.count, 1)
        XCTAssertNil(runtime.transcriptionRouting)
        XCTAssertEqual(records[0].value, raw[0])
    }

    func testCollectionProjection_UsesRawIdentityAndTimestampOnly() throws {
        let data = Data("""
        [{"id":"First","timestamp":"1970-01-01T00:00:10Z","createdAt":"ignored"},
         {"id":"Second","timestamp":0},
         {"name":"Fallback","updatedAt":"ignored"}]
        """.utf8)
        var digested: [Data] = []
        let records = try DataMigrationCollectionRecords.records(data: data, kind: "fixture", digest: {
            digested.append($0)
            return "synthetic-digest"
        })
        XCTAssertEqual(records.map(\.id), ["First", "Second", "synthetic-digest"])
        XCTAssertEqual(records[0].date, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(records[1].date, Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertNil(records[2].date)
        XCTAssertEqual(digested, [try DataMigrationCoding.encoder.encode(records[2].value)])
    }

    func testEmptyAndMalformedCollections_DistinguishPresentEmptyFromDamage() throws {
        XCTAssertEqual(try DataMigrationProfileCatalog.records(data: Data("[]".utf8), digest: { _ in "" }), [])
        for json in ["{}", "[", "null"] {
            XCTAssertThrowsError(try DataMigrationProfileCatalog.records(data: Data(json.utf8), digest: { _ in "" }))
        }
    }

    func testTimestampProjection_DistinguishesNumbersFromBooleansAndPreservesRawValues() throws {
        let data = Data("""
        [{"id":"integer","timestamp":1},{"id":"fractional","timestamp":1.5},
         {"id":"negative","timestamp":-1},{"id":"true","timestamp":true},
         {"id":"false","timestamp":false},{"id":"null","timestamp":null},
         {"id":"invalid","timestamp":"not-a-date"},{"id":"array","timestamp":[]}]
        """.utf8)
        let raw = try JSONDecoder().decode([AnyCodable].self, from: data)
        let records = try DataMigrationCollectionRecords.records(data: data, kind: "fixture", digest: { _ in "" })
        XCTAssertEqual(records.map(\.value), raw)
        XCTAssertEqual(records.prefix(3).map(\.date), [
            Date(timeIntervalSinceReferenceDate: 1), Date(timeIntervalSinceReferenceDate: 1.5),
            Date(timeIntervalSinceReferenceDate: -1)
        ])
        XCTAssertTrue(records.dropFirst(3).allSatisfy { $0.date == nil })
    }

    func testOversizedSource_IsRefusedBeforeDecodingOrDigesting() {
        let data = Data(repeating: 0, count: Int(DataMigrationArchivePolicy.maximumJSONBytes) + 1)
        XCTAssertThrowsError(try DataMigrationProfileCatalog.records(data: data, digest: { _ in
            XCTFail("An oversized source must fail before digesting values.")
            return ""
        }))
    }

    func testValidation_RejectsInvalidCategoryKindIdentityAndPayload() throws {
        let data = Data(#"[{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","name":"Profile"}]"#.utf8)
        let original = try XCTUnwrap(
            DataMigrationProfileCatalog.records(data: data, digest: { _ in "" }).first
        )
        XCTAssertNoThrow(try DataMigrationProfileCatalog.validate(original, category: .profiles))
        XCTAssertThrowsError(try DataMigrationProfileCatalog.validate(original, category: .settings))
        var invalid = original
        invalid.kind = "default"
        XCTAssertThrowsError(try DataMigrationProfileCatalog.validate(invalid, category: .profiles))
        invalid = original
        invalid.id = UUID().uuidString
        XCTAssertThrowsError(try DataMigrationProfileCatalog.validate(invalid, category: .profiles))
        invalid = original
        invalid.value = AnyCodable(.string("Not a profile"))
        XCTAssertThrowsError(try DataMigrationProfileCatalog.validate(invalid, category: .profiles))
    }

    func testCancellationAndDigestFailures_DoNotReturnPartialCollections() throws {
        enum Failure: Error { case digest }
        let data = Data(#"[{"name":"First"},{"name":"Second"}]"#.utf8)
        XCTAssertThrowsError(try DataMigrationProfileCatalog.records(
            data: data, digest: { _ in throw Failure.digest }
        )) { XCTAssertTrue($0 is Failure) }
        var checks = 0
        XCTAssertThrowsError(try DataMigrationProfileCatalog.records(
            data: data, digest: { _ in "fixture" }, checkCancellation: {
                checks += 1
                if checks == 4 { throw CancellationError() }
            }
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 4)
    }

    func testDuplicateProfiles_PreserveSourceOrderForCallerValidation() throws {
        let data = Data("""
        [{"id":"\(id)","name":"First"},{"id":"\(id)","name":"Second"}]
        """.utf8)
        let records = try DataMigrationProfileCatalog.records(data: data, digest: { _ in "" })
        XCTAssertEqual(records.map(\.id), [id, id])
        let names = try records.map { try DataMigrationCoding.decode(DictationProfile.self, $0.value).name }
        XCTAssertEqual(names, ["First", "Second"])
    }

    func testDesktopSource_UsesCanonicalFilenameAndPreservesPrompt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopDictationProfileStore(directory: root)
        XCTAssertEqual(store.fileURL.lastPathComponent, DataMigrationProfileCatalog.desktopFilename)
        XCTAssertEqual(DesktopDictationProfileStore.filename, DataMigrationProfileCatalog.desktopFilename)
        let profile = DictationProfile(name: "Native profile", polishPrompt: "Native per-profile prompt")
        try store.save([profile])
        let bytes = try Data(contentsOf: store.fileURL)
        let records = try DataMigrationProfileCatalog.records(data: bytes, digest: { _ in "" })
        XCTAssertEqual(
            try DataMigrationCoding.decode(DictationProfile.self, records[0].value).polishPrompt,
            profile.polishPrompt
        )
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
    }
}
