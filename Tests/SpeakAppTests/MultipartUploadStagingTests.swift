import Foundation
import XCTest

@testable import SpeakApp

final class MultipartUploadStagingTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("multipart-staging-tests-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDownWithError() throws {
    if let directory {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: directory.path
      )
      try? FileManager.default.removeItem(at: directory)
    }
    try super.tearDownWithError()
  }

  func testCreateUploadBodyFile_createsEmptyRestrictedFileInStagingDirectory() throws {
    let staging = makeStaging()

    let url = try staging.createUploadBodyFile(providerID: "mistral")

    XCTAssertEqual(url.deletingLastPathComponent().path, directory.path)
    XCTAssertTrue(url.lastPathComponent.hasPrefix("mistral-upload-"))
    XCTAssertEqual(url.pathExtension, "multipart")
    XCTAssertEqual(try Data(contentsOf: url), Data())

    let filePermissions = try posixPermissions(atPath: url.path)
    XCTAssertEqual(filePermissions, 0o600)
    let directoryPermissions = try posixPermissions(atPath: directory.path)
    XCTAssertEqual(directoryPermissions, 0o700)
  }

  func testCreateUploadBodyFile_throwsWhenFileCannotBeCreated() throws {
    let staging = makeStaging(fileManager: FailingCreateFileManager())

    XCTAssertThrowsError(try staging.createUploadBodyFile(providerID: "mistral")) { error in
      XCTAssertEqual((error as? CocoaError)?.code, .fileWriteUnknown)
    }
  }

  func testCreateUploadBodyFile_repairsLoosePermissionsOnExistingDirectory() throws {
    // createDirectory applies attributes only on creation, so a staging
    // directory left behind with loose permissions must be re-restricted.
    let staging = makeStaging()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: directory.path
    )

    let url = try staging.createUploadBodyFile(providerID: "mistral")
    defer { staging.removeUploadBodyFile(at: url) }

    XCTAssertEqual(try posixPermissions(atPath: directory.path), 0o700)
  }

  func testPurge_removesStaleUploadBodies() throws {
    let staging = makeStaging()
    let stale = try seedFile(named: "mistral-upload-\(UUID().uuidString).multipart", age: 7_200)
    let staleSoniox = try seedFile(named: "soniox-upload-\(UUID().uuidString).multipart", age: 7_200)

    staging.purgeStaleUploads()

    XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: staleSoniox.path))
  }

  func testPurge_keepsFilesYoungerThanTheStalenessThreshold() throws {
    let staging = makeStaging()
    let fresh = try seedFile(named: "mistral-upload-\(UUID().uuidString).multipart", age: 60)

    staging.purgeStaleUploads()

    XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
  }

  func testPurge_ignoresFilesThatAreNotUploadBodies() throws {
    let staging = makeStaging(stalenessThreshold: 0)
    let unrelated = try seedFile(named: "notes.txt", age: 7_200)
    let wrongName = try seedFile(named: "recording.multipart", age: 7_200)

    staging.purgeStaleUploads()

    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: wrongName.path))
  }

  func testPurge_neverRemovesActiveUploadBodies() throws {
    let staging = makeStaging(stalenessThreshold: 0)

    let active = try staging.createUploadBodyFile(providerID: "soniox")
    try backdate(active, by: 7_200)

    staging.purgeStaleUploads()

    XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
  }

  func testRemoveUploadBodyFile_deletesFileAndReleasesClaimForPurge() throws {
    let staging = makeStaging(stalenessThreshold: 0)
    let url = try staging.createUploadBodyFile(providerID: "mistral")

    staging.removeUploadBodyFile(at: url)

    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

    // A released path is fair game again: recreate it out-of-band and confirm
    // the purge now claims it.
    try Data("stale".utf8).write(to: url)
    try backdate(url, by: 7_200)
    staging.purgeStaleUploads()
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
  }

  func testCreateUploadBodyFile_purgesStaleLeftoversFirst() throws {
    let staging = makeStaging(stalenessThreshold: 0)
    let stale = try seedFile(named: "mistral-upload-\(UUID().uuidString).multipart", age: 7_200)

    let url = try staging.createUploadBodyFile(providerID: "mistral")
    defer { staging.removeUploadBodyFile(at: url) }

    XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
  }

  // MARK: - Helpers

  private func makeStaging(
    stalenessThreshold: TimeInterval = MultipartUploadStaging.defaultStalenessThreshold,
    fileManager: FileManager = .default
  ) -> MultipartUploadStaging {
    MultipartUploadStaging(
      directory: directory,
      stalenessThreshold: stalenessThreshold,
      fileManager: fileManager
    )
  }

  private func seedFile(named name: String, age: TimeInterval) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try Data("leftover".utf8).write(to: url)
    try backdate(url, by: age)
    return url
  }

  private func backdate(_ url: URL, by age: TimeInterval) throws {
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-age)],
      ofItemAtPath: url.path
    )
  }

  private func posixPermissions(atPath path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
  }
}

/// Models a file-creation failure (e.g. disk full) after directory setup
/// succeeded, so the surfaced-error seam stays covered deterministically.
private final class FailingCreateFileManager: FileManager, @unchecked Sendable {
  override func createFile(
    atPath path: String,
    contents data: Data?,
    attributes attr: [FileAttributeKey: Any]? = nil
  ) -> Bool {
    false
  }
}
