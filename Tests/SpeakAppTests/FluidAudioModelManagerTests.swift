import FluidAudio
import Foundation
import XCTest

@testable import SpeakApp

@MainActor
final class FluidAudioModelManagerTests: XCTestCase {
  private var temporaryDirectory: URL!

  override func setUpWithError() throws {
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("FluidAudioModelManagerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let temporaryDirectory {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }
    temporaryDirectory = nil
  }

  func testRefresh_reportsInstalledOnlyWhenEveryArtifactExists() throws {
    let manager = FluidAudioModelManager(modelsDirectory: temporaryDirectory)
    XCTAssertEqual(manager.installState, .notInstalled)

    try createModelArtifacts()
    try FileManager.default.removeItem(
      at: modelDirectory.appendingPathComponent(ModelNames.ParakeetEOU.decoderFile)
    )
    manager.refresh()

    XCTAssertEqual(manager.installState, .notInstalled)

    try createModelArtifacts()
    manager.refresh()

    XCTAssertEqual(manager.installState, .installed)
    XCTAssertEqual(manager.downloadProgress, 1)
  }

  func testDelete_removesOnlyParakeetModelDirectory() throws {
    try createModelArtifacts()
    let unrelated = temporaryDirectory.appendingPathComponent("keep-me.txt")
    try Data("keep".utf8).write(to: unrelated)
    let manager = FluidAudioModelManager(modelsDirectory: temporaryDirectory)
    XCTAssertEqual(manager.installState, .installed)

    manager.delete()

    XCTAssertEqual(manager.installState, .notInstalled)
    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: modelDirectory.path))
  }

  func testModelIdentifier_usesDownloadedLocalStreamingNamespace() {
    XCTAssertTrue(FluidAudioParakeetModel.id.hasPrefix("local/streaming/"))
    XCTAssertTrue(FluidAudioParakeetModel.matches(FluidAudioParakeetModel.id))
    XCTAssertFalse(FluidAudioParakeetModel.matches("local/streaming/sherpa/example"))
  }

  private var modelDirectory: URL {
    temporaryDirectory.appendingPathComponent(Repo.parakeetEou160.folderName, isDirectory: true)
  }

  private func createModelArtifacts() throws {
    try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
    for artifact in ModelNames.ParakeetEOU.requiredModels {
      let artifactURL = modelDirectory.appendingPathComponent(artifact)
      if artifact.hasSuffix(".mlmodelc") {
        try FileManager.default.createDirectory(at: artifactURL, withIntermediateDirectories: true)
      } else {
        try Data("{}".utf8).write(to: artifactURL)
      }
    }
  }
}
