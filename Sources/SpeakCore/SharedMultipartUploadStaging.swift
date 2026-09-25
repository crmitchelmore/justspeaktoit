import Foundation

/// Owns the on-disk lifecycle of multipart upload body files (issue #706).
///
/// Upload bodies contain raw microphone audio, so they are staged in a dedicated
/// temporary subdirectory with restrictive permissions, and anything left behind
/// by a crash, force quit or failed removal is purged once it is safely stale.
/// Bodies claimed by in-flight uploads are tracked in an in-process registry and
/// are never purged. Removal failures are logged without file contents and are
/// retried by the next purge pass.
public final class SharedMultipartUploadStaging: @unchecked Sendable {
  #if !os(Windows)
  public static let posixShared = SharedMultipartUploadStaging(
    directory: FileManager.default.temporaryDirectory
      .appendingPathComponent(ReleaseTrain.current.namespace("speak-multipart-uploads"), isDirectory: true),
    securityPolicy: .posix
  )
  #endif

  /// Conservative age after which an unclaimed upload body counts as abandoned.
  /// In-flight bodies are protected by the claim registry regardless of age.
  public static let defaultStalenessThreshold: TimeInterval = 60 * 60

  private let directory: URL
  private let stalenessThreshold: TimeInterval
  private let fileManager: FileManager
  private static let claims = ClaimRegistry()
  private let securityPolicy: SecurityPolicy
  private let report: @Sendable (Event) -> Void

  public init(
    directory: URL,
    securityPolicy: SecurityPolicy,
    stalenessThreshold: TimeInterval = SharedMultipartUploadStaging.defaultStalenessThreshold,
    fileManager: FileManager = .default,
    report: @escaping @Sendable (Event) -> Void = { _ in }
  ) {
    self.directory = directory
    self.securityPolicy = securityPolicy
    self.stalenessThreshold = stalenessThreshold
    self.fileManager = fileManager
    self.report = report
  }

  /// Creates an empty upload body file and claims it for the current upload so a
  /// concurrent purge can never remove it. Callers must hand the URL back to
  /// `removeUploadBodyFile(at:)` once the upload finishes or fails.
  public func createUploadBodyFile(providerID: String) throws -> URL {
    guard !providerID.isEmpty, providerID.utf8.count <= 64,
          providerID.utf8.allSatisfy({
            (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
          }) else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    // Secure and validate the directory before scanning it, including a
    // Windows policy's reparse-point check. Failure must prevent every write.
    try self.securityPolicy.prepareDirectory(self.directory, self.fileManager)
    self.purgeSecuredDirectory(now: Date())
    let url = self.directory
      .appendingPathComponent("\(providerID)-upload-\(UUID().uuidString).multipart")
    self.claim(url)
    do {
      guard try self.securityPolicy.createFile(url, self.fileManager) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
      }
    } catch {
      self.releaseClaim(url)
      throw error
    }
    return url
  }

  /// Removes an upload body and releases its claim. A failed removal is logged
  /// (never the contents) and retried by a later purge pass once stale.
  public func removeUploadBodyFile(at url: URL) {
    self.releaseClaim(url)
    do {
      try self.fileManager.removeItem(at: url)
    } catch {
      guard self.fileManager.fileExists(atPath: url.path) else { return }
      self.report(.removalFailed(filename: url.lastPathComponent, message: error.localizedDescription))
    }
  }

  /// Deletes abandoned `*-upload-*.multipart` files older than the staleness
  /// threshold. Bodies claimed by in-flight uploads are never touched.
  public func purgeStaleUploads(now: Date = Date()) {
    do {
      try self.securityPolicy.prepareDirectory(self.directory, self.fileManager)
      self.purgeSecuredDirectory(now: now)
    } catch {
      self.report(.directoryPreparationFailed(message: error.localizedDescription))
    }
  }

  private func purgeSecuredDirectory(now: Date) {
    guard let candidates = try? self.fileManager.contentsOfDirectory(
      at: self.directory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ) else { return }

    let claimed = self.currentClaims()
    for url in candidates where Self.isUploadBody(url) && !claimed.contains(Self.claimKey(for: url)) {
      let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? .distantPast
      guard now.timeIntervalSince(modified) >= self.stalenessThreshold else { continue }
      do {
        try self.fileManager.removeItem(at: url)
        self.report(.purged(filename: url.lastPathComponent))
      } catch {
        self.report(.removalFailed(filename: url.lastPathComponent, message: error.localizedDescription))
      }
    }
  }

  private static func isUploadBody(_ url: URL) -> Bool {
    url.pathExtension == "multipart" && url.lastPathComponent.contains("-upload-")
  }

  /// `contentsOfDirectory(at:)` resolves symlinks (`/var` → `/private/var`), so
  /// claims are keyed by the fully resolved path.
  private static func claimKey(for url: URL) -> String {
    let path = url.resolvingSymlinksInPath().path
    #if os(Windows)
    return path.lowercased()
    #else
    return path
    #endif
  }

  private func claim(_ url: URL) {
    _ = Self.claims.lock.withLock { Self.claims.paths.insert(Self.claimKey(for: url)) }
  }

  private func releaseClaim(_ url: URL) {
    _ = Self.claims.lock.withLock { Self.claims.paths.remove(Self.claimKey(for: url)) }
  }

  private func currentClaims() -> Set<String> {
    Self.claims.lock.withLock { Self.claims.paths }
  }

  /// Apple and portable consumers may have different logging/policy adapters
  /// for one directory. Claims must therefore span all staging instances.
  private final class ClaimRegistry: @unchecked Sendable {
    let lock = NSLock()
    var paths: Set<String> = []
  }
}
