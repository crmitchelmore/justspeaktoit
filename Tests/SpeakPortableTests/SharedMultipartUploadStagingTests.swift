import Foundation
import XCTest
@testable import SpeakCore

final class SharedMultipartUploadStagingTests: XCTestCase {
    func testDistinctConsumersShareClaimsAndReleaseThemAfterRemoval() throws {
        let directory = temporaryDirectory()
        let first = staging(directory)
        let second = staging(directory)
        let active = try first.createUploadBodyFile(providerID: "mistral")
        defer { first.removeUploadBodyFile(at: active) }
        second.purgeStaleUploads(now: .distantFuture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))

        first.removeUploadBodyFile(at: active)
        try Data("abandoned fixture".utf8).write(to: active)
        second.purgeStaleUploads(now: .distantFuture)
        XCTAssertFalse(FileManager.default.fileExists(atPath: active.path))
    }

    func testCleanupRequiresCreatingOwnerAndPreservesTheClaim() throws {
        let directory = temporaryDirectory()
        let owner = staging(directory)
        let other = staging(directory)
        let active = try owner.createUploadBodyFile(providerID: "openai")
        defer { owner.removeUploadBodyFile(at: active) }
        other.removeUploadBodyFile(at: active)
        other.purgeStaleUploads(now: .distantFuture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
        owner.removeUploadBodyFile(at: active)
        XCTAssertFalse(FileManager.default.fileExists(atPath: active.path))
    }

    #if !os(Windows)
    func testFinalFileAliasCannotReleaseRealBodyButDirectoryAliasCanRemoveIt() throws {
        let directory = temporaryDirectory()
        let owner = staging(directory)
        let body = try owner.createUploadBodyFile(providerID: "openai")
        let fileAlias = directory.appendingPathComponent("alias")
        let directoryAlias = directory.appendingPathComponent("directory-alias")
        try FileManager.default.createSymbolicLink(at: fileAlias, withDestinationURL: body)
        owner.removeUploadBodyFile(at: fileAlias)
        owner.purgeStaleUploads(now: .distantFuture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: body.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileAlias.path))
        try FileManager.default.createSymbolicLink(at: directoryAlias, withDestinationURL: directory)
        owner.removeUploadBodyFile(at: directoryAlias.appendingPathComponent(body.lastPathComponent))
        XCTAssertFalse(FileManager.default.fileExists(atPath: body.path))
    }

    func testCreationThroughDirectoryAliasKeepsCanonicalClaimsUntilOwnerRemoval() throws {
        let (directory, alias) = try aliasedDirectory()
        let owner = staging(alias)
        let other = staging(directory)
        let body = try owner.createUploadBodyFile(providerID: "openai")
        let canonicalBody = directory.appendingPathComponent(body.lastPathComponent)
        defer { owner.removeUploadBodyFile(at: canonicalBody) }

        other.removeUploadBodyFile(at: canonicalBody)
        other.purgeStaleUploads(now: .distantFuture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalBody.path))
        owner.removeUploadBodyFile(at: canonicalBody)
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalBody.path))

        try Data("abandoned fixture".utf8).write(to: canonicalBody)
        other.purgeStaleUploads(now: .distantFuture)
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalBody.path))
    }

    func testReplacingOwnedLocationWithFinalSymlinkCannotReleaseItsClaim() throws {
        let directory = temporaryDirectory()
        let owner = staging(directory)
        let body = try owner.createUploadBodyFile(providerID: "openai")
        let target = try owner.createUploadBodyFile(providerID: "mistral")
        defer {
            owner.removeUploadBodyFile(at: body)
            owner.removeUploadBodyFile(at: target)
        }
        let saved = directory.appendingPathComponent("saved-body")
        try FileManager.default.moveItem(at: body, to: saved)
        try FileManager.default.createSymbolicLink(at: body, withDestinationURL: target)

        owner.removeUploadBodyFile(at: body)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: body.path), target.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        try FileManager.default.removeItem(at: body)
        try FileManager.default.moveItem(at: saved, to: body)
        staging(directory).purgeStaleUploads(now: .distantFuture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: body.path), "The refused alias must retain the claim")
        owner.removeUploadBodyFile(at: body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: body.path))
    }

    func testFailedCreationThroughDirectoryAliasReleasesTheCanonicalClaim() throws {
        for throwsError in [false, true] {
            let (directory, alias) = try aliasedDirectory()
            let failing = SharedMultipartUploadStaging(directory: alias, securityPolicy: .init(
                prepareDirectory: Self.fixturePolicy.prepareDirectory,
                createFile: { url, manager in
                    XCTAssertTrue(manager.createFile(atPath: url.path, contents: Data("fixture".utf8)))
                    if throwsError { throw PolicyError.denied }
                    return false
                }
            ))
            XCTAssertThrowsError(try failing.createUploadBodyFile(providerID: "mistral"))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
            staging(directory).purgeStaleUploads(now: .distantFuture)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        }
    }
    #endif

    func testPolicyFailurePreventsScanningOrCreatingFiles() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let abandoned = directory.appendingPathComponent("mistral-upload-old.multipart")
        try Data("fixture".utf8).write(to: abandoned)
        let guarded = SharedMultipartUploadStaging(directory: directory, securityPolicy: .init(
            prepareDirectory: { _, _ in throw PolicyError.denied },
            createFile: { _, _ in
                XCTFail("An unvalidated directory must never be written")
                return false
            }
        ))
        XCTAssertThrowsError(try guarded.createUploadBodyFile(providerID: "mistral")) { error in
            XCTAssertEqual(error as? PolicyError, .denied)
        }
        guarded.purgeStaleUploads(now: .distantFuture)
        XCTAssertEqual(try Data(contentsOf: abandoned), Data("fixture".utf8))
    }

    func testFailedCreationReleasesItsClaimForAnotherConsumersCleanup() throws {
        for throwsError in [false, true] {
            let directory = temporaryDirectory()
            let failing = SharedMultipartUploadStaging(directory: directory, securityPolicy: .init(
                prepareDirectory: Self.fixturePolicy.prepareDirectory,
                createFile: { url, manager in
                    XCTAssertTrue(manager.createFile(atPath: url.path, contents: Data("fixture".utf8)))
                    if throwsError { throw PolicyError.denied }
                    return false
                }
            ))
            XCTAssertThrowsError(try failing.createUploadBodyFile(providerID: "mistral"))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
            staging(directory).purgeStaleUploads(now: .distantFuture)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        }
    }

    func testPurgeRecognisesOnlyAbandonedMultipartBodies() throws {
        let directory = temporaryDirectory()
        let store = staging(directory, age: 3_600)
        let active = try store.createUploadBodyFile(providerID: "mistral")
        defer { store.removeUploadBodyFile(at: active) }
        let old = directory.appendingPathComponent("soniox-upload-old.multipart")
        let fresh = directory.appendingPathComponent("mistral-upload-fresh.multipart")
        let unrelated = directory.appendingPathComponent("recording.multipart")
        for url in [old, fresh, unrelated] { try Data("fixture".utf8).write(to: url) }
        // Windows FILETIME starts in 1601; Date.distantPast lies outside that
        // range. Use a realistic timestamp and verify the fixture was applied.
        let now = Date()
        let expired = now.addingTimeInterval(-7_200)
        try FileManager.default.setAttributes([.modificationDate: expired], ofItemAtPath: old.path)
        let modified = try XCTUnwrap(old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        XCTAssertGreaterThan(now.timeIntervalSince(modified), 3_600)
        store.purgeStaleUploads(now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        for url in [active, fresh, unrelated] { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
    }

    func testProviderIdentifiersCannotEscapeThePrivateDirectory() {
        let store = staging(temporaryDirectory())
        let invalid = ["../mistral", "mistral/escape", "mistral\\escape", "", "../", String(repeating: "a", count: 65)]
        for identifier in invalid {
            XCTAssertThrowsError(try store.createUploadBodyFile(providerID: identifier)) { error in
                XCTAssertEqual((error as? CocoaError)?.code, .fileWriteInvalidFileName)
            }
        }
    }

    func testConcurrentConsumersNeverPurgeActiveClaims() async throws {
        let directory = temporaryDirectory()
        let first = staging(directory)
        let second = staging(directory)
        let files = try await withThrowingTaskGroup(of: URL.self) { group in
            for index in 0..<32 {
                group.addTask {
                    try (index.isMultiple(of: 2) ? first : second).createUploadBodyFile(providerID: "mistral")
                }
            }
            var files: [URL] = []
            for try await file in group { files.append(file) }
            return files
        }
        defer { files.forEach { first.removeUploadBodyFile(at: $0); second.removeUploadBodyFile(at: $0) } }
        second.purgeStaleUploads(now: .distantFuture)
        XCTAssertEqual(Set(files).count, 32)
        for file in files { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
    }

    #if !os(Windows)
    func testPOSIXPolicyRepairsLooseDirectoryPermissionsAndProtectsNewFiles() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let store = SharedMultipartUploadStaging(directory: directory, securityPolicy: .posix)
        let file = try store.createUploadBodyFile(providerID: "mistral")
        defer { store.removeUploadBodyFile(at: file) }
        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(try permissions(file), 0o600)
    }
    #endif
}

private extension SharedMultipartUploadStagingTests {
    enum PolicyError: Error { case denied }

    // Synthetic fixtures only. This injected policy deliberately makes no
    // claim about native Windows ACLs; the executable validates that adapter.
    static let fixturePolicy = SharedMultipartUploadStaging.SecurityPolicy(
        prepareDirectory: { url, manager in
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        },
        createFile: { url, manager in manager.createFile(atPath: url.path, contents: nil) }
    )

    func staging(_ directory: URL, age: TimeInterval = 0) -> SharedMultipartUploadStaging {
        SharedMultipartUploadStaging(directory: directory, securityPolicy: Self.fixturePolicy, stalenessThreshold: age)
    }

    func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    #if !os(Windows)
    func aliasedDirectory() throws -> (directory: URL, alias: URL) {
        let root = temporaryDirectory()
        let directory = root.appendingPathComponent("uploads", isDirectory: true)
        let alias = root.appendingPathComponent("directory-alias", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        return (directory, alias)
    }

    func permissions(_ url: URL) throws -> Int? {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }
    #endif
}
