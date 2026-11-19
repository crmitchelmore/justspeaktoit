import Foundation
import SpeakCore

/// The recordings directory as files: listing, keeping and removing
/// recordings, and where staged recorders live and how their leftovers are
/// swept. Static and stateless; `AudioFileManager` supplies the active
/// recording that must never be touched.
enum RecordingFiles {
  /// See ``CaptureStaging`` for why the choice depends on which volume the
  /// recordings directory is on.
  static func resolveStagingDirectory(for recordingsDirectory: URL) -> URL {
    let temporary = FileManager.default.temporaryDirectory
    return CaptureStaging.directory(
      temporaryDirectory: temporary,
      recordingsDirectory: recordingsDirectory,
      sharesVolume: Self.sharesVolume(temporary, recordingsDirectory)
    )
  }

  /// Whether both URLs sit on the same volume, which is what makes claiming a
  /// staged recorder a rename rather than a copy. Unknown answers count as
  /// "no", so an unreadable volume identifier keeps staging beside the
  /// recordings directory instead of risking a cross-volume move.
  static func sharesVolume(_ lhs: URL, _ rhs: URL) -> Bool {
    guard
      let left = try? lhs.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
      let right = try? rhs.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
    else {
      return false
    }
    return left.isEqual(right)
  }

  /// Asks for the staging folder of `recordingsDirectory` to be swept.
  ///
  /// The owner calls this from the composition root at launch, and again
  /// whenever the recordings directory changes, for the old folder and the new
  /// one. Creating a recorder deliberately starts nothing: a test or a preview
  /// that builds one must never reach a real recordings directory, so the
  /// trigger belongs to whoever knows the app is really running.
  ///
  /// Housekeeping must also never stand in front of a session. On the actor,
  /// the directory scan would hold every other message — the warm-up handshake
  /// and `startRecording` included — behind it for as long as it ran, which is
  /// exactly the delay pre-warming exists to remove. The sweep therefore runs
  /// detached, at utility priority, and only once the launch has settled.
  static func scheduleStagedLeftoverSweep(in recordingsDirectory: URL) {
    Task.detached(priority: .utility) {
      try? await Task.sleep(nanoseconds: 2 * NSEC_PER_SEC)
      Self.sweepStagedLeftovers(in: recordingsDirectory, now: Date())
    }
  }

  /// Removes staged files no session ever claimed.
  ///
  /// A crash, a force quit or a power loss between staging a recorder and the
  /// hotkey leaves its file behind, and nothing runs on the way out to clean
  /// it up. This sweep runs once per launch and only takes files that have
  /// been untouched for ``CaptureStaging/leftoverAge``, so it can never reach
  /// a file the running app still owns.
  static func sweepStagedLeftovers(in recordingsDirectory: URL, now: Date) {
    let manager = FileManager.default

    let staging = Self.resolveStagingDirectory(for: recordingsDirectory)
    let stagedKeys: [URLResourceKey] = [.contentModificationDateKey]
    let stagedFiles =
      (try? manager.contentsOfDirectory(at: staging, includingPropertiesForKeys: stagedKeys)) ?? []
    for url in stagedFiles {
      let modified = (try? url.resourceValues(forKeys: Set(stagedKeys)))?.contentModificationDate
      guard CaptureStaging.isLeftover(modifiedAt: modified ?? .distantFuture, now: now) else {
        continue
      }
      try? manager.removeItem(at: url)
    }

    // Builds before staging moved out of the recordings directory left their
    // unclaimed files there. Clear those too, on the same age rule.
    let inPlaceKeys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
    let recordings =
      (try? manager.contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: inPlaceKeys))
      ?? []
    for url in recordings {
      let values = try? url.resourceValues(forKeys: Set(inPlaceKeys))
      guard
        CaptureStaging.isAbandonedInPlaceStage(
          fileName: url.lastPathComponent,
          byteSize: values?.fileSize ?? .max,
          modifiedAt: values?.contentModificationDate ?? .distantFuture,
          now: now
        )
      else {
        continue
      }
      try? manager.removeItem(at: url)
    }
  }

  /// A cancelled recording worth keeping; an empty file holds no speech, so it is removed.
  static func keptRecording(at url: URL?) -> URL? {
    guard let url else { return nil }
    let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    guard size > 0 else {
      try? FileManager.default.removeItem(at: url)
      return nil
    }
    return url
  }

  static func listRecordings(
    in directory: URL, excluding activeRecordingURL: URL? = nil
  ) -> [RecordingSummary] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory.resolvingSymlinksInPath(),
        includingPropertiesForKeys: [.creationDateKey, .fileSizeKey, .isRegularFileKey],
        // Keeps the hidden staging folder, which holds files no session has
        // claimed, out of the user's recordings list.
        options: [.skipsHiddenFiles])
    else {
      return []
    }

    let allowedExtensions = RecordingAudioFormats.macArchiveExtensions
    let activeRecording = activeRecordingURL?.resolvingSymlinksInPath().standardizedFileURL

    var summaries: [RecordingSummary] = []
    while let next = enumerator.nextObject() as? URL {
      let url = next
      guard allowedExtensions.contains(url.pathExtension.lowercased()),
        url.resolvingSymlinksInPath().standardizedFileURL != activeRecording
      else { continue }
      do {
        let resource = try url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey, .isRegularFileKey])
        guard resource.isRegularFile == true else { continue }
        let creationDate = resource.creationDate ?? Date()
        let fileSize = Int64(resource.fileSize ?? 0)
        let stem = url.deletingPathExtension().lastPathComponent
          .replacingOccurrences(of: "Recording-", with: "")
          .replacingOccurrences(of: "Imported-", with: "")
        let id = UUID(uuidString: stem) ?? UUID()
        summaries.append(
          RecordingSummary(
            id: id,
            url: url,
            startedAt: creationDate,
            duration: 0,
            fileSize: fileSize
          )
        )
      } catch {
        continue
      }
    }
    return summaries.sorted { $0.startedAt > $1.startedAt }
  }

  static func removeRecording(at url: URL, excluding activeRecordingURL: URL?) {
    // macOS can expose the same recording through /var and /private/var,
    // or through a user-selected directory symlink. Neither alias is safe to delete.
    guard url.resolvingSymlinksInPath().standardizedFileURL
      != activeRecordingURL?.resolvingSymlinksInPath().standardizedFileURL else { return }
    try? FileManager.default.removeItem(at: url)
  }

  /// Copies an audio file into `directory` as a new imported recording.
  static func importRecording(from url: URL, into directory: URL) throws -> URL {
    let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
    let destination = directory.appendingPathComponent("Imported-\(UUID().uuidString).\(ext)")
    try FileManager.default.copyItem(at: url, to: destination)
    return destination
  }
}
