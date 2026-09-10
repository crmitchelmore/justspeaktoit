import Foundation

// Issue #1020: making an *existing* recording — a Voice Memo, a watch memo, a
// file in Files, an attachment someone sent — usable without opening it,
// exporting it, and pasting it back.
//
// Everything that decides anything lives here, in a pure unit, because the
// place it runs is the worst possible place to debug: a Share extension has a
// tight memory budget, is killed without ceremony when it exceeds it, and has
// no console the user can see. Every branch below is exercised by
// `SharedAudioImportTests` on the host.
//
// **The user's file is never written to.** `stage` opens the source for
// reading only, copies it in fixed-size chunks into *our* container, and
// removes only the copy it made. Nothing in this file, or anything that calls
// it, moves, renames, truncates or deletes the shared item. A test hashes the
// source before and after every path, including the cancelled one.

/// Why a shared recording was refused, and what the user is told.
///
/// One case per real-world failure, and each message says what happened and
/// what to do about it. The repo has a documented history of surfaces claiming
/// outcomes that did not happen (#945, #952); a share sheet that dismisses
/// itself on a file it never read would be the next one.
public enum SharedAudioImportRejection: LocalizedError, Equatable, Sendable {
    /// The item has no file extension, so the container format is unknown.
    case missingExtension(filename: String)
    /// A known extension, but not one any batch provider ingests.
    case unsupportedType(fileExtension: String)
    /// Over `AutomationIntentSupport.maximumAudioFileBytes`.
    case tooLarge(byteCount: Int, limit: Int)
    /// An iCloud Drive placeholder: the file exists in Files but its bytes are
    /// not on this device. Reading it would block for as long as the download
    /// takes, which a Share extension does not have.
    case notDownloaded(filename: String)
    /// The bytes are nominally present but cannot be opened — a permission
    /// failure, a security-scoped URL that would not start, a broken alias.
    case unreadable(filename: String)
    /// A zero-byte file: a Voice Memo still being written, or a failed export.
    case empty(filename: String)
    /// The user dismissed the share sheet, or the extension was terminated,
    /// while the copy was in flight.
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingExtension(let filename):
            return "\"\(filename)\" has no file extension, so its audio format can't be determined. "
                + "Nothing was imported and the file was not changed."
        case .unsupportedType(let fileExtension):
            let supported = AutomationIntentSupport.supportedAudioExtensions.sorted()
                .joined(separator: ", ")
            return "\".\(fileExtension)\" files can't be transcribed. Supported formats: \(supported). "
                + "Nothing was imported and the file was not changed."
        case .tooLarge(let byteCount, let limit):
            let size = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
            let cap = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
            return "That recording is \(size), over the \(cap) limit for file transcription. "
                + "Split it up, or transcribe it on the Mac app. The file was not changed."
        case .notDownloaded(let filename):
            return "\"\(filename)\" is in iCloud but not downloaded to this device yet. "
                + "Open it once in the Files app to download it, then share it again."
        case .unreadable(let filename):
            return "\"\(filename)\" couldn't be opened. The app that shared it may have "
                + "revoked access before the copy finished. Try sharing it again."
        case .empty(let filename):
            return "\"\(filename)\" is empty — there is no audio in it. If the recording is "
                + "still saving, wait for it to finish and share it again."
        case .cancelled:
            return "Import cancelled. Nothing was transcribed, and the recording was not changed."
        }
    }
}

/// What is known about a shared item before a single byte is copied.
///
/// Built from a URL by ``SharedAudioImport/inspect(fileURL:fileManager:)``, or
/// by hand in tests. Separating the reading of it from the judging of it is
/// what makes every rejection above provable without a device.
public struct SharedAudioCandidate: Equatable, Sendable {
    public let filename: String
    /// `nil` when the size could not be read at all, which is itself a signal
    /// that the item is not readable.
    public let byteCount: Int?
    /// `false` only for an iCloud placeholder whose contents are elsewhere.
    public let isDownloaded: Bool
    public let isReadable: Bool

    public init(filename: String, byteCount: Int?, isDownloaded: Bool = true, isReadable: Bool = true) {
        self.filename = filename
        self.byteCount = byteCount
        self.isDownloaded = isDownloaded
        self.isReadable = isReadable
    }
}

/// A candidate that passed every check, carrying the values the staging copy
/// and the transcription request need.
public struct SharedAudioAcceptance: Equatable, Sendable {
    public let filename: String
    /// Lowercased, validated container extension. Used to name our copy so the
    /// provider can detect the format.
    public let fileExtension: String
    public let byteCount: Int

    public init(filename: String, fileExtension: String, byteCount: Int) {
        self.filename = filename
        self.fileExtension = fileExtension
        self.byteCount = byteCount
    }
}

public enum SharedAudioImport {
    /// Copy buffer for staging, matching the batch upload path's fixed 64 KiB
    /// chunk (`CartesiaBatchClient.writeUpload`). A Share extension is killed
    /// for exceeding its memory budget, so no recording-sized `Data` is ever
    /// held: the peak here is one chunk regardless of file length.
    public static let stagingChunkBytes = 65_536

    /// Judges a shared item. Ordered cheapest-and-most-specific first, so the
    /// user is told the most useful thing: an undownloaded iCloud placeholder
    /// reports that rather than "empty", and an unsupported format reports the
    /// format rather than the size.
    public static func evaluate(_ candidate: SharedAudioCandidate) throws -> SharedAudioAcceptance {
        let fileExtension = URL(fileURLWithPath: candidate.filename).pathExtension.lowercased()
        guard !fileExtension.isEmpty else {
            throw SharedAudioImportRejection.missingExtension(filename: candidate.filename)
        }
        guard AutomationIntentSupport.supportedAudioExtensions.contains(fileExtension) else {
            throw SharedAudioImportRejection.unsupportedType(fileExtension: fileExtension)
        }
        guard candidate.isDownloaded else {
            throw SharedAudioImportRejection.notDownloaded(filename: candidate.filename)
        }
        guard candidate.isReadable, let byteCount = candidate.byteCount else {
            throw SharedAudioImportRejection.unreadable(filename: candidate.filename)
        }
        guard byteCount > 0 else {
            throw SharedAudioImportRejection.empty(filename: candidate.filename)
        }
        guard byteCount <= AutomationIntentSupport.maximumAudioFileBytes else {
            throw SharedAudioImportRejection.tooLarge(
                byteCount: byteCount,
                limit: AutomationIntentSupport.maximumAudioFileBytes
            )
        }
        return SharedAudioAcceptance(
            filename: candidate.filename,
            fileExtension: fileExtension,
            byteCount: byteCount
        )
    }

    /// Reads what the file system knows about a shared URL. Read-only: the
    /// resource values below never mutate, and an iCloud download is
    /// deliberately *not* started — that would take longer than the extension
    /// lives and would look like a hang.
    public static func inspect(
        fileURL: URL,
        fileManager: FileManager = .default
    ) -> SharedAudioCandidate {
        let filename = fileURL.lastPathComponent
        let values = try? fileURL.resourceValues(forKeys: [
            .fileSizeKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .isReadableKey
        ])
        let isUbiquitous = values?.isUbiquitousItem ?? false
        let downloadingStatus = values?.ubiquitousItemDownloadingStatus
        // Only a ubiquitous item can be a placeholder. `.current` and
        // `.downloaded` both mean the bytes are here; anything else on an
        // iCloud item means they are not.
        let isDownloaded = !isUbiquitous
            || downloadingStatus == .current
            || downloadingStatus == .downloaded
        let isReadable = (values?.isReadable ?? fileManager.isReadableFile(atPath: fileURL.path))
            && values?.fileSize != nil
        return SharedAudioCandidate(
            filename: filename,
            byteCount: values?.fileSize,
            isDownloaded: isDownloaded,
            isReadable: isReadable
        )
    }

    /// Copies the shared recording into `destination` in fixed-size chunks.
    ///
    /// The source is opened for reading and nothing else. On cancellation or
    /// any failure the *partial copy* is removed and the source is left exactly
    /// as it was found — a half-written file in our inbox would later be
    /// transcribed as if it were the whole recording.
    ///
    /// Returns the number of bytes written.
    @discardableResult
    public static func stage(
        from source: URL,
        to destination: URL,
        isCancelled: () -> Bool = { false }
    ) throws -> Int {
        guard let input = try? FileHandle(forReadingFrom: source) else {
            throw SharedAudioImportRejection.unreadable(filename: source.lastPathComponent)
        }
        defer { try? input.close() }
        let fileManager = FileManager.default
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw SharedAudioImportRejection.unreadable(filename: destination.lastPathComponent)
        }
        do {
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var written = 0
            while true {
                if isCancelled() { throw SharedAudioImportRejection.cancelled }
                guard let chunk = try input.read(upToCount: stagingChunkBytes), !chunk.isEmpty else {
                    break
                }
                try output.write(contentsOf: chunk)
                written += chunk.count
            }
            try output.synchronize()
            return written
        } catch {
            // Our copy only. The shared item is untouched on every path.
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }
}
