import CryptoKit
import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

/// A fake release: signed manifest, downloadable archives whose "executable"
/// is a synthetic Mach-O header, and switches to corrupt each verification step.
@MainActor
final class FakeReleaseWorld {
  let installDirectory: URL
  let signingKey = Curve25519.Signing.PrivateKey()
  var hardwareArchitecture: String
  var automationSchemaVersion: Int
  /// Architecture of the executable inside the archive built for this Mac;
  /// defaults to the hardware's, and is changed to simulate a mislabelled asset.
  var executableArchitecture: String { didSet { servedManifest = nil } }
  var corruptByteCount = false { didSet { servedManifest = nil } }
  var corruptDigest = false { didSet { servedManifest = nil } }
  var tamperManifest = false
  var manifestPublished = true
  private let signatureGate = SignatureGate()
  private let recordGate = SignatureGate()
  private(set) var downloadedURLs: [URL] = []

  /// When set, committing the installation record fails after the executable
  /// has already been replaced — the hardest point for consistency.
  var failRecordCommit: Bool {
    get { recordGate.reject }
    set { recordGate.reject = newValue }
  }
  /// The manifest bytes a real server keeps serving for one published state,
  /// so the detached signature covers exactly what the manifest fetch returned.
  private var servedManifest: Data?

  /// The code-signing check runs synchronously off the main actor, so its
  /// switch and counter live behind a lock rather than on this class.
  var rejectSignature: Bool {
    get { signatureGate.reject }
    set { signatureGate.reject = newValue }
  }

  var signatureChecks: Int { signatureGate.checks }
  private var version: String
  private var archives: [String: Data] = [:]
  private let root: URL

  init(
    version: String,
    hardwareArchitecture: String = "arm64",
    automationSchemaVersion: Int = AutomationSchema.currentVersion
  ) throws {
    self.version = version
    self.hardwareArchitecture = hardwareArchitecture
    self.executableArchitecture = hardwareArchitecture
    self.automationSchemaVersion = automationSchemaVersion
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("speak-cli-installer-tests-\(UUID().uuidString)", isDirectory: true)
    installDirectory = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    publish(version: version)
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }

  var executableBytes: Data { executableBytes(for: version) }

  func executableBytes(for version: String) -> Data {
    var data = MachOFixtures.thin(architecture: executableArchitecture)
    data.append(Data("speak \(version)".utf8))
    return data
  }

  /// Publishes a new release version with fresh archives for both architectures.
  func publish(version: String) {
    self.version = version
    servedManifest = nil
    for architecture in ["arm64", "x86_64"] {
      var payload = MachOFixtures.thin(architecture: architecture)
      payload.append(Data("speak \(version)".utf8))
      // The "zip" is the executable bytes themselves; extraction copies them.
      archives[SpeakCLIManifest.archiveName(version: version, architecture: architecture)] = payload
    }
  }

  private func manifestData() throws -> Data {
    let assets = ["arm64", "x86_64"].map { architecture -> SpeakCLIManifest.Asset in
      let name = SpeakCLIManifest.archiveName(version: version, architecture: architecture)
      var archive = archives[name] ?? Data()
      if architecture == hardwareArchitecture {
        archive = executableBytes
        archives[name] = archive
      }
      let digest = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
      return SpeakCLIManifest.Asset(
        architecture: architecture,
        url: URL(string: "https://example.com/releases/\(name)")!,
        byteCount: archive.count + (corruptByteCount ? 1 : 0),
        sha256: corruptDigest ? String(repeating: "0", count: 64) : digest
      )
    }
    let manifest = SpeakCLIManifest(
      version: version, automationSchemaVersion: automationSchemaVersion, assets: assets
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try encoder.encode(manifest)
  }

  private func currentManifest() throws -> Data {
    if let servedManifest { return servedManifest }
    let data = try manifestData()
    servedManifest = data
    return data
  }

  func makeInstaller() -> SpeakCLIInstaller {
    let dependencies = SpeakCLIInstallerDependencies(
      fetchData: { [weak self] url in
        guard let self else { throw CancellationError() }
        return try await self.fetch(url)
      },
      download: { [weak self] url, progress in
        guard let self else { throw CancellationError() }
        return try await self.download(url, progress: progress)
      },
      extractExecutable: { archive, directory in
        let executable = directory.appendingPathComponent("speak")
        try FileManager.default.copyItem(at: archive, to: executable)
        return executable
      },
      verifyCodeSignature: { [signatureGate] _ in
        signatureGate.recordCheck()
        if signatureGate.reject {
          throw SpeakCLIInstallerError.codeSignatureRejected("test rejection")
        }
      },
      hardwareArchitecture: { [hardwareArchitecture] in hardwareArchitecture },
      commitRecord: { [recordGate] staged, final in
        if recordGate.reject { throw CocoaError(.fileWriteUnknown) }
        try SpeakCLIInstallerDependencies.commitRecord(staged: staged, final: final)
      },
      publicKeyBase64: signingKey.publicKey.rawRepresentation.base64EncodedString(),
      automationSchemaVersion: AutomationSchema.currentVersion,
      manifestURL: URL(string: "https://example.com/releases/speak-cli-manifest.json")!,
      signatureURL: URL(string: "https://example.com/releases/speak-cli-manifest.json.sig")!,
      installDirectory: installDirectory
    )
    return SpeakCLIInstaller(dependencies: dependencies)
  }

  private func fetch(_ url: URL) async throws -> Data {
    guard manifestPublished else {
      throw SpeakCLIInstallerDependencies.TransportError.notPublished(url)
    }
    let manifest = try currentManifest()
    switch url.lastPathComponent {
    case SpeakCLIManifest.manifestAssetName:
      return tamperManifest ? manifest + Data(" ".utf8) : manifest
    case SpeakCLIManifest.signatureAssetName:
      return Data(try signingKey.signature(for: manifest).base64EncodedString().utf8)
    default:
      throw SpeakCLIInstallerDependencies.TransportError.httpStatus(404, url)
    }
  }

  private func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
    downloadedURLs.append(url)
    guard let payload = archives[url.lastPathComponent] else {
      throw SpeakCLIInstallerDependencies.TransportError.httpStatus(404, url)
    }
    let directory = root.appendingPathComponent("download-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(url.lastPathComponent)
    try payload.write(to: file)
    progress(1)
    return file
  }
}

/// Lock-protected switch and counter for the synchronous code-signing seam.
final class SignatureGate: @unchecked Sendable {
  private let lock = NSLock()
  private var rejectValue = false
  private var checkCount = 0

  var reject: Bool {
    get { lock.withLock { rejectValue } }
    set { lock.withLock { rejectValue = newValue } }
  }

  var checks: Int { lock.withLock { checkCount } }

  func recordCheck() {
    lock.withLock { checkCount += 1 }
  }
}
