import Foundation

// The hand-off between the Share extension and the app (issue #1020).
//
// The extension cannot transcribe: it has no microphone need but it does have
// the memory budget of an extension, no background time worth the name, and no
// access to the app's running services. So it does the one thing it is well
// placed to do — take a durable copy of the shared recording while the
// security-scoped URL is still valid — and leaves the work to the app.
//
// Deliberately a directory of files plus one small JSON manifest each, not a
// database and not a `UserDefaults` blob: two processes write here, the
// extension can be killed between the copy and the manifest, and a
// half-finished item must be inert rather than corrupting anything. An item is
// only visible to the app once its manifest exists, and the manifest is
// written last.

/// One recording waiting to be transcribed, as recorded by the extension.
public struct SharedRecordingInboxItem: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    /// The user's own name for the file, shown in History and in any error.
    /// Never used to build a path — see ``SharedRecordingInbox/stagedURL(id:fileExtension:)``.
    public let originalFilename: String
    public let fileExtension: String
    public let byteCount: Int
    public let receivedAt: Date

    public init(
        id: UUID = UUID(),
        originalFilename: String,
        fileExtension: String,
        byteCount: Int,
        receivedAt: Date = Date()
    ) {
        self.id = id
        self.originalFilename = originalFilename
        self.fileExtension = fileExtension
        self.byteCount = byteCount
        self.receivedAt = Self.storable(receivedAt)
    }

    /// Rounds to whole milliseconds.
    ///
    /// The manifest stores this as a JSON number of seconds, and a `Double`
    /// does not reliably survive that decimal text round trip bit for bit: a
    /// committed item and the same item read back could compare unequal.
    /// Millisecond resolution is far finer than anything the inbox orders by,
    /// and the decode below re-applies exactly this rounding, so the two
    /// values are computed from the same integer and are always identical.
    static func storable(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    private enum CodingKeys: String, CodingKey {
        case id, originalFilename, fileExtension, byteCount, receivedAt
    }

    /// Routed through the memberwise initialiser so a decoded date is rounded
    /// the same way a committed one was.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            originalFilename: try container.decode(String.self, forKey: .originalFilename),
            fileExtension: try container.decode(String.self, forKey: .fileExtension),
            byteCount: try container.decode(Int.self, forKey: .byteCount),
            receivedAt: try container.decode(Date.self, forKey: .receivedAt)
        )
    }
}

/// The shared-container drop box. Injectable root so every rule below is
/// testable on the host without an App Group.
///
/// `@unchecked Sendable` for the injected `FileManager`, which is not itself
/// `Sendable`: the extension hands this value to the background thread
/// `NSItemProvider` calls back on, and the operations used here (create
/// directory, enumerate, remove) are documented as safe from any thread on
/// `FileManager.default`.
public struct SharedRecordingInbox: @unchecked Sendable {
    public static let directoryName = "SharedRecordings"

    public let root: URL
    private let fileManager: FileManager

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    /// The inbox inside the app group container, or `nil` when the running
    /// binary lacks the entitlement (`AppGroupAvailability`'s rule: report
    /// unavailable rather than write somewhere the other process cannot read).
    public static func shared(
        groupIdentifier: String = KeyboardHandoffStore.appGroupIdentifier,
        fileManager: FileManager = .default
    ) -> SharedRecordingInbox? {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier
        ) else {
            SpeakLogger.logger(category: "SharedRecordingInbox").fault(
                """
                App Group \(groupIdentifier, privacy: .public) has no container; shared \
                recordings cannot be handed to the app.
                """
            )
            return nil
        }
        return SharedRecordingInbox(root: container.appendingPathComponent(directoryName))
    }

    /// Path for the copy of the recording. Built from the item's UUID and its
    /// validated extension only — never from the user's filename, which can
    /// contain separators, `..`, or characters the file system will not take.
    public func stagedURL(id: UUID, fileExtension: String) -> URL {
        root.appendingPathComponent(id.uuidString).appendingPathExtension(fileExtension)
    }

    public func manifestURL(id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    public func prepare() throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Publishes an item. Called *after* the copy is complete, so an item the
    /// app can see always has all of its bytes.
    public func commit(_ item: SharedRecordingInboxItem) throws {
        try Self.encoder.encode(item).write(to: manifestURL(id: item.id), options: .atomic)
    }

    /// Items ready to transcribe, oldest first, skipping any whose audio copy
    /// is missing (an interrupted extension, or a half-cleared inbox).
    public func pending() -> [SharedRecordingInboxItem] {
        let decoder = Self.decoder
        let contents = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> SharedRecordingInboxItem? in
                guard let data = try? Data(contentsOf: url),
                      let item = try? decoder.decode(SharedRecordingInboxItem.self, from: data)
                else { return nil }
                let audio = stagedURL(id: item.id, fileExtension: item.fileExtension)
                guard fileManager.fileExists(atPath: audio.path) else {
                    // Orphaned manifest: drop it so it is not retried forever.
                    try? fileManager.removeItem(at: url)
                    return nil
                }
                return item
            }
            .sorted { $0.receivedAt < $1.receivedAt }
    }

    /// Seconds since the epoch rather than ISO 8601: the manifest is read
    /// only by this app, and a text timestamp rounds to the second, which
    /// would let two recordings shared in the same second come back in an
    /// arbitrary order.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    /// Removes our copy and its manifest once the app has finished with it.
    /// Only ever touches files inside `root`, all of which this code wrote.
    public func remove(_ item: SharedRecordingInboxItem) {
        try? fileManager.removeItem(at: stagedURL(id: item.id, fileExtension: item.fileExtension))
        try? fileManager.removeItem(at: manifestURL(id: item.id))
    }
}
