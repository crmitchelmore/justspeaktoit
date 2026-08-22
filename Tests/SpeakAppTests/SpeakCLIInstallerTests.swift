import CryptoKit
import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

/// The standalone CLI install flow must verify everything before touching the
/// installed executable, replace it atomically, keep a working installation
/// on failure, and remove only what it owns (issue #775).
@MainActor
final class SpeakCLIInstallerTests: XCTestCase {
  private typealias Installed = SpeakCLIInstaller.InstalledCLI

  // MARK: - Install

  func testInstall_verifiesManifestArchiveArchitectureAndSignatureThenInstalls() async throws {
    let world = try FakeReleaseWorld(version: "2.62.0")
    let installer = world.makeInstaller()
    XCTAssertEqual(installer.state, .notInstalled)

    await installer.install()

    guard case .installed(let cli) = installer.state else {
      return XCTFail("Expected installed, got \(installer.state)")
    }
    XCTAssertEqual(cli.version, "2.62.0")
    XCTAssertEqual(cli.architecture, "arm64")
    XCTAssertEqual(cli.automationSchemaVersion, AutomationSchema.currentVersion)
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installer.executableURL.path))
    XCTAssertEqual(try Data(contentsOf: installer.executableURL), world.executableBytes)
    XCTAssertEqual(world.signatureChecks, 1)
    XCTAssertEqual(installer.latestVersion, "2.62.0")
    XCTAssertTrue(installer.pathCommand.hasPrefix("export PATH=\"\(world.installDirectory.path):$PATH\""))

    // A fresh installer instance reads the record back without any network access.
    let reloaded = world.makeInstaller()
    XCTAssertEqual(reloaded.state, .installed(cli))
  }

  func testInstall_choosesTheAssetForTheHardwareArchitecture() async throws {
    let world = try FakeReleaseWorld(version: "2.62.0", hardwareArchitecture: "x86_64")
    let installer = world.makeInstaller()

    await installer.install()

    guard case .installed(let cli) = installer.state else {
      return XCTFail("Expected installed, got \(installer.state)")
    }
    XCTAssertEqual(cli.architecture, "x86_64")
    XCTAssertEqual(world.downloadedURLs.map(\.lastPathComponent), ["speak-2.62.0-x86_64.zip"])
  }

  func testInstall_refusesSizeMismatchBeforeInstalling() async throws {
    let world = try FakeReleaseWorld(version: "2.62.0")
    world.corruptByteCount = true
    let installer = world.makeInstaller()

    await installer.install()

    guard case .failed(let message, let installed) = installer.state else {
      return XCTFail("Expected failed, got \(installer.state)")
    }
    XCTAssertTrue(message.contains("bytes"), message)
    XCTAssertNil(installed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: installer.executableURL.path))
    XCTAssertEqual(world.signatureChecks, 0, "Nothing is signature-checked after a size mismatch")
  }

  func testInstall_refusesChecksumMismatch() async throws {
    let world = try FakeReleaseWorld(version: "2.62.0")
    world.corruptDigest = true
    let installer = world.makeInstaller()

    await installer.install()

    guard case .failed(let message, _) = installer.state else {
      return XCTFail("Expected failed, got \(installer.state)")
    }
    XCTAssertTrue(message.contains("SHA-256"), message)
    XCTAssertFalse(FileManager.default.fileExists(atPath: installer.executableURL.path))
  }

  func testInstall_refusesTamperedManifest() async throws {
    let world = try FakeReleaseWorld(version: "2.62.0")
    world.tamperManifest = true
    let installer = world.makeInstaller()

    await installer.install()

    guard case .failed(let message, _) = installer.state else {
      return XCTFail("Expected failed, got \(installer.state)")
    }
    XCTAssertTrue(message.contains("signature"), message)
    XCTAssertTrue(world.downloadedURLs.isEmpty, "An untrusted manifest must not trigger any download")
  }

  func testInstall_refusesWrongArchitectureBinary() async throws {
    let world = try FakeReleaseWorld(version: "2.62.0")
    world.executableArchitecture = "x86_64"
    let installer = world.makeInstaller()

    await installer.install()

    guard case .failed(let message, _) = installer.state else {
      return XCTFail("Expected failed, got \(installer.state)")
    }
    XCTAssertTrue(message.contains("built for x86_64"), message)
    XCTAssertFalse(FileManager.default.fileExists(atPath: installer.executableURL.path))
  }

  func testInstall_refusesRejectedCodeSignature() async throws {
    let world = try FakeReleaseWorld(version: "2.62.0")
    world.rejectSignature = true
    let installer = world.makeInstaller()

    await installer.install()

    guard case .failed(let message, _) = installer.state else {
      return XCTFail("Expected failed, got \(installer.state)")
    }
    XCTAssertTrue(message.contains("not signed"), message)
    XCTAssertFalse(FileManager.default.fileExists(atPath: installer.executableURL.path))
  }

  func testInstall_refusesIncompatibleAutomationProtocol() async throws {
    let world = try FakeReleaseWorld(version: "2.62.0", automationSchemaVersion: AutomationSchema.currentVersion + 1)
    let installer = world.makeInstaller()

    await installer.install()

    guard case .failed(let message, _) = installer.state else {
      return XCTFail("Expected failed, got \(installer.state)")
    }
    XCTAssertTrue(message.contains("protocol"), message)
    XCTAssertTrue(world.downloadedURLs.isEmpty)
  }

  func testInstall_whenTheReleaseHasNoCLIYet_reportsUnavailableAfterCheck() async throws {
    let world = try FakeReleaseWorld(version: "2.62.0")
    world.manifestPublished = false
    let installer = world.makeInstaller()

    await installer.checkForUpdate()
    guard case .unavailable(let message) = installer.state else {
      return XCTFail("Expected unavailable, got \(installer.state)")
    }
    XCTAssertTrue(message.contains("not published"), message)

    await installer.install()
    guard case .failed = installer.state else {
      return XCTFail("Expected failed, got \(installer.state)")
    }
  }

  // MARK: - Update

  func testUpdate_replacesTheExecutableAndKeepsTheOldOneWhenTheNewOneFails() async throws {
    let world = try FakeReleaseWorld(version: "2.62.0")
    let installer = world.makeInstaller()
    await installer.install()
    guard case .installed(let first) = installer.state else { return XCTFail("install failed") }

    world.publish(version: "2.63.0")
    await installer.checkForUpdate()
    XCTAssertEqual(installer.state, .updateAvailable(installed: first, latest: "2.63.0"))

    // The new build is rejected: the 2.62.0 executable must survive untouched.
    world.rejectSignature = true
    await installer.install()
    guard case .failed(_, let kept) = installer.state else { return XCTFail("Expected failed") }
    XCTAssertEqual(kept, first)
    XCTAssertEqual(try Data(contentsOf: installer.executableURL), world.executableBytes(for: "2.62.0"))

    world.rejectSignature = false
    await installer.install()
    guard case .installed(let second) = installer.state else { return XCTFail("Expected installed") }
    XCTAssertEqual(second.version, "2.63.0")
    XCTAssertEqual(try Data(contentsOf: installer.executableURL), world.executableBytes(for: "2.63.0"))
  }

  // MARK: - Uninstall

  func testUninstall_removesOnlyOwnedFiles() async throws {
    let world = try FakeReleaseWorld(version: "2.62.0")
    let installer = world.makeInstaller()
    await installer.install()
    let foreign = world.installDirectory.appendingPathComponent("user-script.sh")
    try Data("#!/bin/sh\n".utf8).write(to: foreign)

    installer.uninstall()

    XCTAssertEqual(installer.state, .notInstalled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: installer.executableURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path), "Files the installer did not write stay")
    XCTAssertTrue(FileManager.default.fileExists(atPath: world.installDirectory.path))

    try FileManager.default.removeItem(at: foreign)
    await installer.install()
    installer.uninstall()
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: world.installDirectory.path),
      "An empty install directory is removed"
    )
  }

  func testCompatibility_flagsACLIBuiltForAnotherProtocol() async throws {
    let world = try FakeReleaseWorld(version: "2.62.0")
    let installer = world.makeInstaller()
    let stale = Installed(
      version: "1.0.0", architecture: "arm64", sha256: "", automationSchemaVersion: 0, installedAt: Date()
    )
    XCTAssertFalse(installer.isCompatible(stale))
    await installer.install()
    XCTAssertTrue(installer.isCompatible(try XCTUnwrap(installer.state.installed)))
  }
}
