import Foundation

/// Owns the on-disk lifecycle of multipart upload body files (issue #706).
///
/// Upload bodies contain raw microphone audio, so they are staged in a dedicated
/// temporary subdirectory with restrictive permissions, and anything left behind
/// by a crash, force quit or failed removal is purged once it is safely stale.
/// Bodies claimed by in-flight uploads are tracked in an in-process registry and
/// are never purged. Removal failures are logged without file contents and are
/// retried by the next purge pass.
public final class MultipartUploadStaging: @unchecked Sendable {
  public static let shared = MultipartUploadStaging()

  /// Conservative age after which an unclaimed upload body counts as abandoned.
  /// In-flight bodies are protected by the claim registry regardless of age.
  public static let defaultStalenessThreshold: TimeInterval = 60 * 60

  private let directory: URL
  private let stalenessThreshold: TimeInterval
  private let fileManager: FileManager
  private let lock = NSLock()
  private var claimedPaths: Set<String> = []
  private let logger = SpeakLogger.logger(category: "MultipartUploadStaging")

  /// A `stalenessThreshold` that is not a finite, positive interval falls back to
  /// `defaultStalenessThreshold`: `NaN` or infinity would silently disable the
  /// stale purge, and zero or less would purge bodies the moment they are unclaimed.
  public init(
    directory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent(ReleaseTrain.current.namespace("speak-multipart-uploads"), isDirectory: true),
    stalenessThreshold: TimeInterval = MultipartUploadStaging.defaultStalenessThreshold,
    fileManager: FileManager = .default
  ) {
    self.directory = directory
    self.stalenessThreshold = stalenessThreshold.isFinite && stalenessThreshold > 0
      ? stalenessThreshold
      : Self.defaultStalenessThreshold
    self.fileManager = fileManager
  }

  /// Creates an empty upload body file and claims it for the current upload so a
  /// concurrent purge can never remove it. Callers must hand the URL back to
  /// `removeUploadBodyFile(at:)` once the upload finishes or fails.
  public func createUploadBodyFile(providerID: String) throws -> URL {
    // Retry removals that previously failed; the directory only ever holds
    // in-flight bodies, so the scan is cheap.
    self.purgeStaleUploads()

    try self.fileManager.createDirectory(
      at: self.directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    // createDirectory applies attributes only when it creates the directory,
    // so enforce the restrictive mode on a pre-existing directory as well.
    try self.fileManager.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: self.directory.path
    )
    let url = self.directory.appendingPathComponent(
      "\(Self.safeFileNamePrefix(providerID))-upload-\(UUID().uuidString).multipart"
    )
    self.claim(url)
    let created = self.fileManager.createFile(
      atPath: url.path,
      contents: nil,
      attributes: [.posixPermissions: 0o600]
    )
    guard created else {
      self.releaseClaim(url)
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    return url
  }

  /// Removes an upload body this instance created and still claims, and releases
  /// that claim. Any other URL (a source recording, another instance's body, a
  /// path that merely resolves into the staging directory, or a body already
  /// released) is refused and left untouched, so this public cleanup can never
  /// delete a file it does not own. A failed removal is logged (never the
  /// contents) and retried by a later purge pass once stale.
  public func removeUploadBodyFile(at url: URL) {
    guard self.releaseClaimIfOwned(url) else {
      self.logger.error(
        "Refused to remove \(url.lastPathComponent, privacy: .private): not a body this staging instance owns"
      )
      return
    }
    do {
      try self.fileManager.removeItem(at: url)
    } catch {
      guard self.fileManager.fileExists(atPath: url.path) else { return }
      self.logger.error(
        """
        Failed to remove multipart upload body \
        \(url.lastPathComponent, privacy: .public): \
        \(error.localizedDescription, privacy: .public)
        """
      )
    }
  }

  /// Deletes abandoned `*-upload-*.multipart` files older than the staleness
  /// threshold. Bodies claimed by in-flight uploads are never touched.
  public func purgeStaleUploads(now: Date = Date()) {
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
        self.logger.info(
          "Purged stale multipart upload body \(url.lastPathComponent, privacy: .public)"
        )
      } catch {
        self.logger.error(
          """
          Failed to purge stale multipart upload body \
          \(url.lastPathComponent, privacy: .public): \
          \(error.localizedDescription, privacy: .public)
          """
        )
      }
    }
  }

  /// Reduces a provider ID to one safe file-name component, so an ID such as
  /// `../escaped` cannot place a body outside the staging directory, where the
  /// stale purge would never find it.
  static func safeFileNamePrefix(_ providerID: String) -> String {
    var safe = String.UnicodeScalarView()
    for scalar in providerID.unicodeScalars {
      let isSafe = scalar.isASCII
        && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
      safe.append(isSafe ? scalar : "_")
    }
    return safe.isEmpty ? "provider" : String(safe)
  }

  private static func isUploadBody(_ url: URL) -> Bool {
    url.pathExtension == "multipart" && url.lastPathComponent.contains("-upload-")
  }

  /// `contentsOfDirectory(at:)` resolves symlinks (`/var` → `/private/var`), so
  /// claims are keyed by the standardised, fully resolved path.
  private static func claimKey(for url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
  }

  private func claim(_ url: URL) {
    self.lock.lock()
    defer { self.lock.unlock() }
    self.claimedPaths.insert(Self.claimKey(for: url))
  }

  private func releaseClaim(_ url: URL) {
    self.lock.lock()
    defer { self.lock.unlock() }
    self.claimedPaths.remove(Self.claimKey(for: url))
  }

  /// Claims are only ever taken for bodies this instance created inside its own
  /// directory, so holding one is the ownership proof for removal. The check and
  /// the release share one lock, so a body is removed at most once.
  private func releaseClaimIfOwned(_ url: URL) -> Bool {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.claimedPaths.remove(Self.claimKey(for: url)) != nil
  }

  private func currentClaims() -> Set<String> {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.claimedPaths
  }
}
