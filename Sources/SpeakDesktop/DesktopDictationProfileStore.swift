import Foundation
import SpeakCore

/// File-backed per-app dictation profiles for desktop hosts.
///
/// The file holds the same canonical list encoding the Apple store and
/// cross-device transfer use, so it decodes on every platform, and the shared
/// decoder's tolerance for unknown matcher kinds and newer routing values
/// applies unchanged. Profiles are stored in precedence order with their
/// identifiers exactly as given; the store never reorders, renames or drops.
public struct DesktopDictationProfileStore: Sendable {
    public static let filename = "profiles.json"

    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent(Self.filename)
    }

    /// Profiles in stored order. A missing file means no profiles; an
    /// unreadable file throws so the host can say so instead of hiding it.
    public func load() throws -> [DictationProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try DictationProfile.decodeList(Data(contentsOf: fileURL))
    }

    /// Replaces the whole list atomically. Callers persist only a validated
    /// list; a cancelled edit never reaches this call.
    public func save(_ profiles: [DictationProfile]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try DictationProfile.encodeList(profiles).write(to: fileURL, options: .atomic)
    }

    /// Moves a file `load` could not decode beside itself so a later save
    /// cannot overwrite data the user may still want. Returns the new location,
    /// or `nil` when there was nothing to preserve.
    @discardableResult
    public func preserveUnreadableFile(now: Date = Date()) throws -> URL? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let stamp = Int(now.timeIntervalSince1970)
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let destination = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(Self.filename).unreadable-\(stamp)-\(suffix)")
        try FileManager.default.moveItem(at: fileURL, to: destination)
        return destination
    }
}
