import Foundation

// MARK: - Records

/// The keyboard extension's short-lived advertisement that it is on screen in
/// a particular text document (issue #1002).
///
/// A keyboard extension cannot be asked whether it is visible, so it publishes
/// this instead and lets it lapse. The lifetime is deliberately a few seconds:
/// `viewDidDisappear` is not guaranteed to run before the extension is
/// suspended or killed, so a target that stops being refreshed must stop
/// looking open on its own, quickly. Anything longer would let a hardware
/// trigger deliver into a field the user left minutes ago.
public struct KeyboardTargetRecord: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    /// How long an unrefreshed target keeps looking open.
    public static let lifetime: TimeInterval = 8
    /// How often the keyboard rewrites it while it stays on screen.
    public static let refreshInterval: TimeInterval = 2

    public let schemaVersion: Int
    public let documentIdentifier: UUID
    public let updatedAt: Date
    public let expiresAt: Date
    /// A secure field never becomes a delivery target.
    public let isSecureField: Bool

    public init(
        schemaVersion: Int = Self.schemaVersion,
        documentIdentifier: UUID,
        updatedAt: Date,
        expiresAt: Date,
        isSecureField: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.documentIdentifier = documentIdentifier
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.isSecureField = isSecureField
    }

    public func isOpen(now: Date) -> Bool {
        expiresAt > now && !isSecureField
    }
}

/// A transcript the containing app is offering to the keyboard for delivery
/// (issues #1002 and #1003). Written only by the containing app.
///
/// No audio, credential, or surrounding text enters this record. It is the
/// same App Group the hand-off already uses, so it exists only with Full
/// Access; without it nothing is published and nothing is offered.
public struct KeyboardPickupOffer: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    /// Where the transcript came from, so the chip can say so.
    public enum Source: String, Codable, Equatable, Sendable {
        case hardwareTrigger
        case app
        case watch

        public var displayName: String {
            switch self {
            case .hardwareTrigger: return "Action Button"
            case .app: return "Just Speak"
            case .watch: return "Watch"
            }
        }
    }

    /// How the keyboard is allowed to deliver this offer.
    public enum Mode: String, Codable, Equatable, Sendable {
        /// The keyboard was demonstrably on screen in `originDocumentIdentifier`
        /// when the capture finished, so the user's physical press was itself
        /// the instruction to put the words in that field (#1002). Auto-inserts
        /// on an exact document match and on nothing else.
        case targetedInsert
        /// Any other capture. Offered as a chip the user taps (#1003); it
        /// auto-inserts only when the user turned that on *and* the document
        /// matches the one the capture started in.
        case latePickup
    }

    /// A targeted insert is "the field you are in right now"; it must not
    /// outlive that claim, so it matches the hand-off result lifetime.
    public static let targetedInsertLifetime: TimeInterval = 60
    /// The late-pickup window. Ten minutes covers the journey the feature
    /// exists for — dictate in the pocket, walk to the desk, open Messages —
    /// while staying short enough that the text on offer is still one the user
    /// remembers saying. The preview also sits in the keyboard strip above
    /// whatever app is focused, so a longer window is a standing privacy
    /// exposure for a transcript the user has moved on from. History and the
    /// clipboard remain the unbounded fallbacks.
    public static let latePickupLifetime: TimeInterval = 10 * 60

    public let schemaVersion: Int
    public let offerID: UUID
    public let text: String
    public let source: Source
    public let mode: Mode
    public let createdAt: Date
    public let expiresAt: Date
    /// The document the capture belonged to, when there was one. `nil` for a
    /// watch or pocket capture, which can never auto-insert anywhere.
    public let originDocumentIdentifier: UUID?

    public init(
        schemaVersion: Int = Self.schemaVersion,
        offerID: UUID = UUID(),
        text: String,
        source: Source,
        mode: Mode,
        createdAt: Date,
        expiresAt: Date,
        originDocumentIdentifier: UUID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.offerID = offerID
        self.text = text
        self.source = source
        self.mode = mode
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.originDocumentIdentifier = originDocumentIdentifier
    }
}

/// The keyboard extension's record that it has taken (or dismissed) an offer.
/// Written only by the extension, so neither process read-modify-writes the
/// other's key.
public struct KeyboardPickupClaim: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let offerID: UUID
    public let claimedAt: Date

    public init(
        schemaVersion: Int = Self.schemaVersion,
        offerID: UUID,
        claimedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.offerID = offerID
        self.claimedAt = claimedAt
    }
}

/// App-owned, non-secret keyboard delivery preferences (issues #1003, #1005).
public struct KeyboardDeliveryPreferences: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    /// Hand the keyboard back to the previous one after a successful insert.
    public let handsBackAfterInsert: Bool
    /// Let a late-pickup offer insert itself when it returns to the very same
    /// document it was captured in. Off by default: inserting text the user
    /// did not just ask for is a data-corruption risk, so the chip is opt-out
    /// only by explicit choice.
    public let autoInsertsMatchingPickup: Bool
    /// Show words in the field as they are spoken, as provisional marked text,
    /// instead of only in the keyboard strip (issue #1004). On by default: it
    /// is what the system keyboard does. A host app that handles marked text
    /// badly is the reason it can be turned off — with it off, the transcript
    /// still arrives, in one insertion at the end.
    public let streamsMarkedText: Bool

    public init(
        schemaVersion: Int = Self.schemaVersion,
        handsBackAfterInsert: Bool = true,
        autoInsertsMatchingPickup: Bool = false,
        streamsMarkedText: Bool = true
    ) {
        self.schemaVersion = schemaVersion
        self.handsBackAfterInsert = handsBackAfterInsert
        self.autoInsertsMatchingPickup = autoInsertsMatchingPickup
        self.streamsMarkedText = streamsMarkedText
    }

    /// A record written before `streamsMarkedText` existed keeps its other two
    /// choices and takes the default for the new one, rather than being
    /// discarded as undecodable and silently resetting the user's toggles.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        handsBackAfterInsert = try container.decode(Bool.self, forKey: .handsBackAfterInsert)
        autoInsertsMatchingPickup = try container.decode(Bool.self, forKey: .autoInsertsMatchingPickup)
        streamsMarkedText = try container.decodeIfPresent(Bool.self, forKey: .streamsMarkedText) ?? true
    }

    public static let `default` = KeyboardDeliveryPreferences()
}
