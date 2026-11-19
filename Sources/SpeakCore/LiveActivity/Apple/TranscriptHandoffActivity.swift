import Foundation

/// The "Continue on Mac" pointer published after a capture (issue #1006).
///
/// ## The payload deliberately does not contain the transcript
///
/// The original idea carried "id + up to 2 KB preview". A Handoff activity is
/// advertised over Bluetooth LE and awdl to every nearby device signed in to
/// the same account, whether or not the user ever uses the Dock item, and it is
/// republished after every single capture. Putting the user's words on that
/// broadcast is a standing exposure for a feature whose only job is to say
/// *which* transcript to open.
///
/// So the payload is a pointer: the History entry's id, when it was made, how
/// many words it has, and which platform made it. The receiving Mac resolves
/// the text from its own synced History (issue #1007) — the same copy it
/// already has — and never learns anything from the pointer that it could not
/// already read locally. Everything is a `String` so the dictionary crosses the
/// activity boundary as a plain property list.
public enum TranscriptHandoffActivity {
    public static let activityType = "com.justspeaktoit.transcript"
    public static let schemaVersion = 1

    public enum Key {
        public static let schemaVersion = "schemaVersion"
        public static let entryID = "entryID"
        public static let createdAt = "createdAt"
        public static let wordCount = "wordCount"
        public static let originPlatform = "originPlatform"
    }

    public struct Pointer: Equatable, Sendable {
        public let entryID: UUID
        public let createdAt: Date
        public let wordCount: Int
        public let originPlatform: String

        public init(entryID: UUID, createdAt: Date, wordCount: Int, originPlatform: String) {
            self.entryID = entryID
            self.createdAt = createdAt
            self.wordCount = wordCount
            self.originPlatform = originPlatform
        }

        /// How the device is named in user-facing copy.
        public var deviceName: String {
            RemoteTranscriptArrival.deviceName(for: originPlatform)
        }
    }

    private static func makeFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    public static func userInfo(for pointer: Pointer) -> [String: String] {
        [
            Key.schemaVersion: String(schemaVersion),
            Key.entryID: pointer.entryID.uuidString,
            Key.createdAt: makeFormatter().string(from: pointer.createdAt),
            Key.wordCount: String(pointer.wordCount),
            Key.originPlatform: pointer.originPlatform
        ]
    }

    /// Rebuilds the pointer on the receiving side. Returns `nil` for anything
    /// that is not a pointer this build understands, so a future schema simply
    /// does not continue rather than continuing wrongly.
    public static func pointer(from userInfo: [AnyHashable: Any]?) -> Pointer? {
        guard let userInfo else { return nil }
        guard let versionString = userInfo[Key.schemaVersion] as? String,
              Int(versionString) == schemaVersion,
              let idString = userInfo[Key.entryID] as? String,
              let entryID = UUID(uuidString: idString),
              let createdAtString = userInfo[Key.createdAt] as? String,
              let createdAt = makeFormatter().date(from: createdAtString)
        else {
            return nil
        }
        let wordCount = Int((userInfo[Key.wordCount] as? String) ?? "") ?? 0
        let originPlatform = (userInfo[Key.originPlatform] as? String) ?? "unknown"
        return Pointer(
            entryID: entryID,
            createdAt: createdAt,
            wordCount: wordCount,
            originPlatform: originPlatform
        )
    }

    /// The title shown in the Mac's Dock Handoff slot.
    public static func title(for pointer: Pointer) -> String {
        let words = pointer.wordCount == 1 ? "1 word" : "\(pointer.wordCount) words"
        return "Transcript from \(pointer.deviceName) \u{00B7} \(words)"
    }

    /// What the Mac says when the pointer resolves to an entry it has not
    /// synced yet. A Handoff pointer is not a transfer, and pretending the
    /// words arrived when they have not is the #952 failure.
    public static let unresolvedMessage =
        "That transcript has not reached this Mac yet. It arrives with the next iCloud History sync."
}
