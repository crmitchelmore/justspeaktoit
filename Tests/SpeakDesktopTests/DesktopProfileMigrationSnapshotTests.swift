import Foundation
import SpeakCore
import SpeakDesktop
import XCTest

final class DesktopProfileMigrationSnapshotTests: XCTestCase {
    func testOriginalProfiles_PreserveOrderPromptAndUnknownMembersWithoutChangingSource() throws {
        let fixture = try ProfileSourceFixture()
        defer { fixture.remove() }
        let data = Data("""
        [{"id":"Second","polishPrompt":"Exact\\nPrompt","matchers":[{"kind":"future","value":"retained"}]},
         {"id":"First","future":{"enabled":false,"count":0}},{"name":"Digest identity"}]
        """.utf8)
        try data.write(to: fixture.store.fileURL)
        let snapshot = try fixture.store.migrationSnapshot(digests: fixture.digests)
        XCTAssertEqual(snapshot.manifest.categories, [.profiles])
        XCTAssertEqual(snapshot.manifest.scopes["profiles"]?.selectedKinds, [DataMigrationProfileCatalog.kind])
        let records = try XCTUnwrap(snapshot.records[.profiles])
        XCTAssertEqual(records.map(\.value), try JSONDecoder().decode([AnyCodable].self, from: data))
        XCTAssertEqual(records.map(\.id), ["Second", "First", String(repeating: "a", count: 64)])
        XCTAssertEqual(try Data(contentsOf: fixture.store.fileURL), data)
        XCTAssertTrue(snapshot.files.isEmpty)
    }

    func testMissingAndPresentEmptyProfiles_AreExplicitScopedEmptyCollections() throws {
        let fixture = try ProfileSourceFixture()
        defer { fixture.remove() }
        let missing = try fixture.store.migrationSnapshot(digests: fixture.digests)
        XCTAssertEqual(missing.records[.profiles], [])
        XCTAssertEqual(missing.manifest.scopes["profiles"]?.selectedKinds, ["profile"])
        try Data("[]".utf8).write(to: fixture.store.fileURL)
        XCTAssertEqual(try fixture.store.migrationSnapshot(digests: fixture.digests).records[.profiles], [])
    }

    func testMalformedSource_FailsInsteadOfReturningEmptyAuthority() throws {
        let fixture = try ProfileSourceFixture()
        defer { fixture.remove() }
        for json in ["{}", "null", "[", ""] {
            let original = Data(json.utf8)
            try original.write(to: fixture.store.fileURL)
            XCTAssertThrowsError(try fixture.store.migrationSnapshot(digests: fixture.digests))
            XCTAssertEqual(try Data(contentsOf: fixture.store.fileURL), original)
        }
    }

    func testChangingSourceDuringProjection_FailsRevalidationWithoutPartialSnapshot() throws {
        let fixture = try ProfileSourceFixture()
        defer { fixture.remove() }
        try Data(#"[{"name":"Digest this source"}]"#.utf8).write(to: fixture.store.fileURL)
        let file = fixture.store.fileURL
        let digests = LocalModelDigestProvider(name: "Synthetic changed-source fixture") {
            ProfileSourceHasher(change: file)
        }
        XCTAssertThrowsError(try fixture.store.migrationSnapshot(digests: digests)) {
            guard let failure = $0 as? DesktopOwnedAppDataFileReadError, case .changedSource = failure else {
                return XCTFail("Expected changed-source refusal, got \($0)")
            }
        }
    }

    func testCancellation_IsPropagatedBeforeAnySourceRead() throws {
        let fixture = try ProfileSourceFixture()
        defer { fixture.remove() }
        XCTAssertThrowsError(try fixture.store.migrationSnapshot(
            digests: fixture.digests, checkCancellation: { throw CancellationError() }
        )) { XCTAssertTrue($0 is CancellationError) }
    }

    func testMissingOwnedRoot_DoesNotBecomeEmptyAuthority() throws {
        let fixture = try ProfileSourceFixture()
        defer { fixture.remove() }
        let absent = DesktopDictationProfileStore(directory: fixture.root.appendingPathComponent("Missing"))
        XCTAssertThrowsError(try absent.migrationSnapshot(digests: fixture.digests)) {
            guard let failure = $0 as? DesktopOwnedAppDataFileReadError, case .insufficientIdentity = failure else {
                return XCTFail("Expected unsupported absence binding, got \($0)")
            }
        }
    }

    func testLinkedSource_IsRefusedAndByteBudgetIsEnforced() throws {
        let fixture = try ProfileSourceFixture()
        defer { fixture.remove() }
        let other = fixture.root.appendingPathComponent("Other.json")
        try Data("[]".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: fixture.store.fileURL, withDestinationURL: other)
        XCTAssertThrowsError(try fixture.store.migrationSnapshot(digests: fixture.digests))
        try FileManager.default.removeItem(at: fixture.store.fileURL)
        try Data("[123]".utf8).write(to: fixture.store.fileURL)
        XCTAssertThrowsError(try DesktopOwnedAppDataFileReader.readStrict(
            DesktopDictationProfileStore.filename, appDirectory: fixture.root, maximumBytes: 2
        )) {
            guard let failure = $0 as? DesktopOwnedAppDataFileReadError, case .exceedsByteBudget = failure else {
                return XCTFail("Expected bounded-source refusal, got \($0)")
            }
        }
    }

    func testNativeCategoryFlags_PreserveLegacyChoicesAndRejectUnrecognizedBits() throws {
        for flags in 0...3 {
            let choice = try DesktopMigrationBackup.Selection(nativeFlags: flags)
            XCTAssertEqual(choice.includeAudio, flags & 1 != 0)
            XCTAssertEqual(choice.includeProfiles, flags & 2 != 0)
        }
        for flags in [-1, 4, Int.min, Int.max] {
            XCTAssertThrowsError(try DesktopMigrationBackup.Selection(nativeFlags: flags))
        }
        XCTAssertFalse(DesktopMigrationBackup.Selection(includeAudio: true).includeProfiles)
    }
}

private struct ProfileSourceFixture {
    let root: URL
    var store: DesktopDictationProfileStore { .init(directory: root) }
    var digests: LocalModelDigestProvider {
        .init(name: "Synthetic fixed digest; not cryptographic proof") { ProfileSourceHasher() }
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("profile-source-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    func remove() {
        do { try FileManager.default.removeItem(at: root) } catch { XCTFail(error.localizedDescription) }
    }
}

private final class ProfileSourceHasher: LocalModelSHA256Hasher {
    let change: URL?

    init(change: URL? = nil) { self.change = change }

    func update(_ bytes: UnsafeRawBufferPointer) throws {
        try Task.checkCancellation()
        if let change { try Data("[]".utf8).write(to: change, options: .atomic) }
    }

    func finish() throws -> String { String(repeating: "a", count: 64) }
}
