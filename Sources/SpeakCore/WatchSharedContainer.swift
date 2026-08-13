import Foundation

// MARK: - Watch Shared Container
//
// The watch app and the watch widget extension are separate processes with
// separate data containers, so anything the complication has to read (capture
// queue, complication snapshot, pending record request) must live in the App
// Group container they share. Pure Foundation so the same file compiles in
// SpeakCore (mac/iOS) and is included by direct source reference in both
// watchOS targets, which cannot depend on the package graph.

/// The directory the watch app and its widget extension both read, plus the
/// small-payload IO both do against it.
///
/// Falls back to the app's own Application Support directory when the App
/// Group entitlement is not present (unprovisioned development builds): the
/// app keeps working, the complication simply shows idle.
public struct WatchSharedContainer: Sendable {
    /// App Group shared by `com.justspeaktoit.ios.watchkitapp` and
    /// `com.justspeaktoit.ios.watchkitapp.complication`. Distinct from the
    /// iOS group (`group.com.justspeaktoit.ios`): App Group containers are
    /// per-device, so the watch pair needs its own registration.
    public static let appGroupIdentifier = "group.com.justspeaktoit.watch"

    /// The container every watch process uses.
    public static let shared = WatchSharedContainer()

    private let directory: URL
    private let legacyDirectory: URL

    /// True when the App Group container was reachable, i.e. the complication
    /// can see what the app writes.
    public let isAppGroupBacked: Bool

    public init(fileManager: FileManager = .default) {
        let legacy = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let shared = fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier)
        self.directory = shared ?? legacy
        self.legacyDirectory = legacy
        self.isAppGroupBacked = shared != nil
    }

    /// Seam for tests and previews: an explicit pair of directories standing
    /// in for the App Group container and the pre-App-Group location.
    public init(directory: URL, legacyDirectory: URL) {
        self.directory = directory
        self.legacyDirectory = legacyDirectory
        self.isAppGroupBacked = directory.standardizedFileURL != legacyDirectory.standardizedFileURL
    }

    public func url(named name: String) -> URL {
        self.directory.appendingPathComponent(name)
    }

    // MARK: - Small payload IO

    /// Reads a shared payload, returning nil when it has never been written.
    public func read(named name: String) -> Data? {
        try? Data(contentsOf: self.url(named: name))
    }

    /// Atomically writes a shared payload, creating the container directory if
    /// needed. Silent on failure: none of these payloads is worth failing a
    /// recording over.
    public func write(_ data: Data, named name: String) {
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        try? data.write(to: self.url(named: name), options: .atomic)
    }

    public func remove(named name: String) {
        try? FileManager.default.removeItem(at: self.url(named: name))
    }

    /// Atomically moves one payload to another name in the same container.
    /// A successful move transfers ownership to the caller before it reads,
    /// so a producer can safely recreate the original path immediately.
    func claim(named name: String, as claimedName: String) -> Bool {
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        do {
            try FileManager.default.moveItem(
                at: self.url(named: name),
                to: self.url(named: claimedName)
            )
            return true
        } catch {
            return false
        }
    }

    // MARK: - Migration

    /// Moves a file left behind in the app-local container into the shared
    /// one, so an existing install keeps its capture queue when the App Group
    /// is added. No-op when the destination already exists, when the source
    /// does not, or when there is no App Group to move into. Returns true when
    /// a file was moved.
    @discardableResult
    public func migrateLegacyFile(named name: String) -> Bool {
        guard self.isAppGroupBacked else { return false }
        let source = self.legacyDirectory.appendingPathComponent(name)
        let destination = self.url(named: name)
        guard FileManager.default.fileExists(atPath: source.path) else { return false }
        guard !FileManager.default.fileExists(atPath: destination.path) else { return false }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            return true
        } catch {
            return false
        }
    }
}
