import Foundation
import SpeakCore

/// Installs, updates and removes the standalone `speak` CLI under the user's
/// Application Support folder, without administrator rights and without
/// touching shell startup files (issue #775).
///
/// Every download is verified completely — signed manifest, byte count,
/// SHA-256, Mach-O architecture and Developer ID signature — in a temporary
/// location before the installed executable is replaced atomically, so a
/// failed install can never leave a partial or untrusted binary in place.
@MainActor
final class SpeakCLIInstaller: ObservableObject {
  static let shared = SpeakCLIInstaller()

  /// What the installer owns on disk, recorded next to the executable.
  struct InstalledCLI: Codable, Equatable {
    let version: String
    let architecture: String
    let sha256: String
    let automationSchemaVersion: Int
    let installedAt: Date
  }

  enum Phase: Equatable {
    case downloading(Double?)
    case verifying
    case installing
  }

  enum State: Equatable {
    case notInstalled
    /// No CLI can be offered right now (not published yet, or built for a
    /// protocol this app does not speak). The message explains which.
    case unavailable(String)
    case installing(Phase)
    case installed(InstalledCLI)
    case updateAvailable(installed: InstalledCLI, latest: String)
    /// The previous installation, if any, is untouched.
    case failed(String, installed: InstalledCLI?)

    var installed: InstalledCLI? {
      switch self {
      case .installed(let cli), .updateAvailable(let cli, _), .failed(_, let cli?): return cli
      default: return nil
      }
    }

    var isBusy: Bool {
      if case .installing = self { return true }
      return false
    }
  }

  static let executableName = "speak"
  static let recordName = "installed.json"

  @Published private(set) var state: State = .notInstalled
  @Published private(set) var latestVersion: String?

  let dependencies: SpeakCLIInstallerDependencies
  private let fileManager: FileManager
  private let logger = SpeakLogger.logger(category: "SpeakCLIInstaller")

  init(
    dependencies: SpeakCLIInstallerDependencies = .live,
    fileManager: FileManager = .default
  ) {
    self.dependencies = dependencies
    self.fileManager = fileManager
    refresh()
  }

  var executableURL: URL {
    dependencies.installDirectory.appendingPathComponent(Self.executableName)
  }

  private var recordURL: URL {
    dependencies.installDirectory.appendingPathComponent(Self.recordName)
  }

  /// Shell line users paste into their own profile; the installer never edits it for them.
  var pathCommand: String {
    "export PATH=\"\(dependencies.installDirectory.path):$PATH\""
  }

  /// Whether the installed CLI speaks the automation protocol this app speaks.
  func isCompatible(_ cli: InstalledCLI) -> Bool {
    cli.automationSchemaVersion == dependencies.automationSchemaVersion
  }

  // MARK: - State

  /// Re-reads what is installed, without touching the network.
  func refresh() {
    guard !state.isBusy else { return }
    if let installed = readRecord() {
      if let latestVersion, latestVersion != installed.version {
        state = .updateAvailable(installed: installed, latest: latestVersion)
      } else {
        state = .installed(installed)
      }
    } else {
      state = .notInstalled
    }
  }

  func checkForUpdate() async {
    guard !state.isBusy else { return }
    do {
      let manifest = try await fetchVerifiedManifest()
      latestVersion = manifest.version
      guard let installed = readRecord() else {
        state = .notInstalled
        return
      }
      state = manifest.version == installed.version
        ? .installed(installed)
        : .updateAvailable(installed: installed, latest: manifest.version)
    } catch {
      if readRecord() == nil {
        state = .unavailable(error.localizedDescription)
      } else {
        state = .failed(error.localizedDescription, installed: readRecord())
      }
    }
  }

  // MARK: - Install

  func install() async {
    guard !state.isBusy else { return }
    let previous = readRecord()
    var scratch: URL?
    defer { if let scratch { try? fileManager.removeItem(at: scratch) } }
    do {
      state = .installing(.downloading(nil))
      let manifest = try await fetchVerifiedManifest()
      latestVersion = manifest.version
      let architecture = dependencies.hardwareArchitecture()
      guard let asset = manifest.asset(for: architecture) else {
        throw SpeakCLIInstallerError.noAssetForArchitecture(architecture)
      }
      guard manifest.automationSchemaVersion == dependencies.automationSchemaVersion else {
        throw SpeakCLIInstallerError.incompatibleProtocol(
          cli: manifest.automationSchemaVersion, app: dependencies.automationSchemaVersion)
      }

      let archive = try await dependencies.download(asset.url) { [weak self] fraction in
        Task { @MainActor [weak self] in
          guard let self, case .installing(.downloading) = self.state else { return }
          self.state = .installing(.downloading(fraction))
        }
      }
      scratch = archive.deletingLastPathComponent()

      state = .installing(.verifying)
      try Self.verifyArchive(archive, against: asset)
      let executable = try await dependencies.extractExecutable(archive, archive.deletingLastPathComponent())
      let slices = try MachOArchitectures.architectures(of: executable)
      guard slices == [architecture] else {
        throw SpeakCLIInstallerError.wrongArchitecture(expected: architecture, found: slices.sorted())
      }
      try dependencies.verifyCodeSignature(executable)

      state = .installing(.installing)
      let record = InstalledCLI(
        version: manifest.version,
        architecture: architecture,
        sha256: asset.sha256,
        automationSchemaVersion: manifest.automationSchemaVersion,
        installedAt: Self.installationDate()
      )
      try place(executable, record: record)
      state = .installed(record)
      logger.info("Installed speak CLI \(manifest.version, privacy: .public) (\(architecture, privacy: .public))")
    } catch {
      logger.error("speak CLI install failed: \(error.localizedDescription, privacy: .public)")
      state = .failed(error.localizedDescription, installed: previous)
    }
  }

  /// Removes only what the installer wrote: the executable and its record.
  /// The directory is removed only when nothing else is left in it.
  func uninstall() {
    guard !state.isBusy else { return }
    do {
      for url in [executableURL, recordURL] where fileManager.fileExists(atPath: url.path) {
        try fileManager.removeItem(at: url)
      }
      let remaining = (try? fileManager.contentsOfDirectory(atPath: dependencies.installDirectory.path)) ?? []
      if remaining.isEmpty {
        try? fileManager.removeItem(at: dependencies.installDirectory)
      }
      state = .notInstalled
    } catch {
      state = .failed(error.localizedDescription, installed: readRecord())
    }
  }

  // MARK: - Steps

  private func fetchVerifiedManifest() async throws -> SpeakCLIManifest {
    let manifestData = try await dependencies.fetchData(dependencies.manifestURL)
    let signatureData = try await dependencies.fetchData(dependencies.signatureURL)
    let signature = String(bytes: signatureData, encoding: .utf8) ?? ""
    return try SpeakCLIManifestVerifier.verifiedManifest(
      manifestData: manifestData,
      signatureBase64: signature,
      publicKeyBase64: dependencies.publicKeyBase64
    )
  }

  /// The record round-trips through ISO 8601 without fractional seconds, so
  /// the timestamp is stored at whole-second precision from the start and the
  /// in-memory record equals the one read back after a relaunch.
  static func installationDate(now: Date = Date()) -> Date {
    Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
  }

  private static func verifyArchive(_ archive: URL, against asset: SpeakCLIManifest.Asset) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
    let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? -1
    guard byteCount == asset.byteCount else {
      throw SpeakCLIInstallerError.sizeMismatch(expected: asset.byteCount, actual: byteCount)
    }
    let digest = try SpeakCLIInstallerDependencies.sha256Hex(of: archive)
    guard digest.caseInsensitiveCompare(asset.sha256) == .orderedSame else {
      throw SpeakCLIInstallerError.checksumMismatch
    }
  }

  /// Moves the verified executable into place. The replacement is a single
  /// rename, so a concurrent `speak` invocation sees either the old or the
  /// new binary, never a partial one.
  private func place(_ executable: URL, record: InstalledCLI) throws {
    try fileManager.createDirectory(
      at: dependencies.installDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    // The download carries a quarantine flag; the executable has just been
    // verified against the manifest and this team's Developer ID, so clear it
    // rather than have Gatekeeper block a terminal launch.
    removexattr(executable.path, "com.apple.quarantine", 0)

    if fileManager.fileExists(atPath: executableURL.path) {
      _ = try fileManager.replaceItemAt(executableURL, withItemAt: executable)
    } else {
      try fileManager.moveItem(at: executable, to: executableURL)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(record).write(to: recordURL, options: .atomic)
  }

  private func readRecord() -> InstalledCLI? {
    guard fileManager.isExecutableFile(atPath: executableURL.path),
      let data = fileManager.contents(atPath: recordURL.path)
    else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(InstalledCLI.self, from: data)
  }
}

enum SpeakCLIInstallerError: LocalizedError, Equatable {
  case noAssetForArchitecture(String)
  case incompatibleProtocol(cli: Int, app: Int)
  case sizeMismatch(expected: Int, actual: Int)
  case checksumMismatch
  case wrongArchitecture(expected: String, found: [String])
  case codeSignatureRejected(String)
  case extractionFailed(String)

  var errorDescription: String? {
    switch self {
    case .noAssetForArchitecture(let architecture):
      return "This release has no speak CLI build for \(architecture) Macs."
    case .incompatibleProtocol(let cli, let app):
      return "This speak CLI speaks automation protocol v\(cli) but the app speaks v\(app). Update the app first."
    case .sizeMismatch(let expected, let actual):
      return "The download was \(actual) bytes but the release manifest expects \(expected). Nothing was installed."
    case .checksumMismatch:
      return "The download's SHA-256 does not match the release manifest. Nothing was installed."
    case .wrongArchitecture(let expected, let found):
      return "The download is built for \(found.joined(separator: ", ")) but this Mac needs \(expected). "
        + "Nothing was installed."
    case .codeSignatureRejected(let detail):
      return "The download is not signed by Just Speak to It's developer (\(detail)). Nothing was installed."
    case .extractionFailed(let detail):
      return "The download could not be unpacked: \(detail)."
    }
  }
}
