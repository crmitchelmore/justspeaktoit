import CryptoKit
import Foundation
import Security
import SpeakCore

/// Everything `SpeakCLIInstaller` needs from the outside world — network,
/// archive extraction, code-signing verification and the machine's
/// architecture — so the install flow is testable end to end without a
/// network, the Security framework or a real release (issue #775).
struct SpeakCLIInstallerDependencies {
  typealias ProgressHandler = @Sendable (Double) -> Void

  /// Fetches a small release asset (the manifest and its signature).
  var fetchData: @Sendable (URL) async throws -> Data
  /// Downloads an archive to a temporary file, reporting fractional progress.
  var download: @Sendable (URL, @escaping ProgressHandler) async throws -> URL
  /// Extracts the single `speak` executable from a zip archive into `directory`.
  var extractExecutable: @Sendable (_ archive: URL, _ directory: URL) async throws -> URL
  /// Throws unless the executable carries a valid Developer ID signature from this app's team.
  var verifyCodeSignature: @Sendable (URL) throws -> Void
  /// `arm64` on Apple Silicon hardware (even under Rosetta), `x86_64` on Intel.
  var hardwareArchitecture: @Sendable () -> String
  /// Sparkle's Ed25519 public key from Info.plist, which also signs the manifest.
  var publicKeyBase64: String?
  var automationSchemaVersion: Int
  var manifestURL: URL
  var signatureURL: URL
  /// Where the CLI is installed: `<Application Support>/SpeakApp/bin`.
  var installDirectory: URL

  static var live: SpeakCLIInstallerDependencies {
    let releases = URL(string: "https://github.com/crmitchelmore/justspeaktoit/releases/latest/download/")!
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    return SpeakCLIInstallerDependencies(
      fetchData: { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        try Self.checkStatus(response, for: url)
        return data
      },
      download: { url, progress in
        try await Self.downloadToTemporaryFile(url, progress: progress)
      },
      extractExecutable: { archive, directory in
        try await Self.extract(archive, into: directory)
      },
      verifyCodeSignature: { executable in
        try Self.verifyDeveloperIDSignature(of: executable)
      },
      hardwareArchitecture: { Self.hardwareArchitecture },
      publicKeyBase64: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
      automationSchemaVersion: AutomationSchema.currentVersion,
      manifestURL: releases.appendingPathComponent(SpeakCLIManifest.manifestAssetName),
      signatureURL: releases.appendingPathComponent(SpeakCLIManifest.signatureAssetName),
      installDirectory: support
        .appendingPathComponent("SpeakApp", isDirectory: true)
        .appendingPathComponent("bin", isDirectory: true)
    )
  }

  // MARK: - Live implementations

  enum TransportError: LocalizedError {
    case httpStatus(Int, URL)
    case notPublished(URL)

    var errorDescription: String? {
      switch self {
      case .httpStatus(let status, let url):
        return "The download of \(url.lastPathComponent) failed with HTTP \(status)."
      case .notPublished(let url):
        return "\(url.lastPathComponent) is not published for the latest release yet."
      }
    }
  }

  static func checkStatus(_ response: URLResponse, for url: URL) throws {
    guard let http = response as? HTTPURLResponse else { return }
    if http.statusCode == 404 { throw TransportError.notPublished(url) }
    guard (200..<300).contains(http.statusCode) else { throw TransportError.httpStatus(http.statusCode, url) }
  }

  private static func downloadToTemporaryFile(_ url: URL, progress: @escaping ProgressHandler) async throws -> URL {
    let (bytes, response) = try await URLSession.shared.bytes(from: url)
    try checkStatus(response, for: url)
    let expected = response.expectedContentLength
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("speak-cli-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let fileURL = destination.appendingPathComponent(url.lastPathComponent)
    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    let handle = try FileHandle(forWritingTo: fileURL)
    defer { try? handle.close() }

    var buffer = Data()
    buffer.reserveCapacity(256 * 1024)
    var received: Int64 = 0
    for try await byte in bytes {
      buffer.append(byte)
      if buffer.count >= 256 * 1024 {
        try handle.write(contentsOf: buffer)
        received += Int64(buffer.count)
        buffer.removeAll(keepingCapacity: true)
        if expected > 0 { progress(min(1, Double(received) / Double(expected))) }
      }
    }
    if !buffer.isEmpty {
      try handle.write(contentsOf: buffer)
      received += Int64(buffer.count)
    }
    progress(1)
    return fileURL
  }

  private static func extract(_ archive: URL, into directory: URL) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
          try process.run()
          process.waitUntilExit()
          guard process.terminationStatus == 0 else {
            throw SpeakCLIInstallerError.extractionFailed("ditto exited with status \(process.terminationStatus)")
          }
          let executable = directory.appendingPathComponent("speak")
          guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw SpeakCLIInstallerError.extractionFailed("the archive does not contain a speak executable")
          }
          continuation.resume(returning: executable)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// Requires a valid signature anchored at Apple with this app's own team
  /// identifier on the leaf certificate, so only a CLI from the same developer
  /// is ever placed on the user's PATH.
  static func verifyDeveloperIDSignature(of executable: URL) throws {
    guard let teamIdentifier = currentTeamIdentifier() else {
      throw SpeakCLIInstallerError.codeSignatureRejected(
        "this app is not signed with a team identifier, so it cannot vouch for a downloaded executable")
    }
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(executable as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
      throw SpeakCLIInstallerError.codeSignatureRejected("the executable could not be opened for signature checks")
    }
    let requirementText = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
      let requirement
    else {
      throw SpeakCLIInstallerError.codeSignatureRejected("the signing requirement could not be built")
    }
    var error: Unmanaged<CFError>?
    let status = SecStaticCodeCheckValidityWithErrors(staticCode, [], requirement, &error)
    guard status == errSecSuccess else {
      let detail = error?.takeRetainedValue().localizedDescription ?? "status \(status)"
      throw SpeakCLIInstallerError.codeSignatureRejected(detail)
    }
  }

  private static func currentTeamIdentifier() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var information: CFDictionary?
    let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
    guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
      let info = information as? [String: Any],
      let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
      !team.isEmpty
    else { return nil }
    return team
  }

  /// The hardware architecture, not the process's: a universal app translated
  /// by Rosetta still installs the arm64 CLI on an Apple Silicon Mac.
  static var hardwareArchitecture: String {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0, value == 1 {
      return "arm64"
    }
    return "x86_64"
  }

  static func sha256Hex(of fileURL: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
