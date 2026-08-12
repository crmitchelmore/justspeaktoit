import Foundation

/// One rendered element of a release note.
///
/// The bundled notes are Markdown produced by the release pipeline. Parsing
/// them into blocks lets each platform render them with native text styles, so
/// they inherit Dynamic Type, VoiceOver semantics and text selection rather
/// than relying on an embedded web view.
public struct ReleaseNoteBlock: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// A `##` Markdown heading, such as "Overview".
        case heading
        /// A `###` Markdown heading nested under a `heading`.
        case subheading
        /// Free-standing prose.
        case paragraph
        /// A list item. `indentLevel` preserves nesting.
        case bullet
    }

    public let id: Int
    public let kind: Kind
    public let text: String
    public let indentLevel: Int

    public init(id: Int, kind: Kind, text: String, indentLevel: Int = 0) {
        self.id = id
        self.kind = kind
        self.text = text
        self.indentLevel = indentLevel
    }

    /// Inline Markdown (`**bold**`, links) rendered as an attributed string.
    /// Falls back to the literal text when the fragment is not valid Markdown.
    public var attributedText: AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    /// Plain text with inline Markdown markers removed, for accessibility labels.
    public var plainText: String {
        String(attributedText.characters)
    }
}

/// Turns release-note Markdown into renderable blocks.
public enum ReleaseNotesMarkdown {
    public static func blocks(from markdown: String) -> [ReleaseNoteBlock] {
        var blocks: [ReleaseNoteBlock] = []
        var isInsideHTMLComment = false

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if isInsideHTMLComment {
                if line.contains("-->") { isInsideHTMLComment = false }
                continue
            }
            if line.hasPrefix("<!--") {
                if !line.contains("-->") { isInsideHTMLComment = true }
                continue
            }
            guard !line.isEmpty else { continue }

            let indentLevel = Self.indentLevel(of: rawLine)
            if let text = Self.text(of: line, afterPrefix: "### ") {
                blocks.append(.init(id: blocks.count, kind: .subheading, text: text))
            } else if let text = Self.text(of: line, afterPrefix: "## ") {
                blocks.append(.init(id: blocks.count, kind: .heading, text: text))
            } else if let text = Self.text(of: line, afterPrefix: "# ") {
                blocks.append(.init(id: blocks.count, kind: .heading, text: text))
            } else if let text = Self.bulletText(of: line) {
                blocks.append(.init(id: blocks.count, kind: .bullet, text: text, indentLevel: indentLevel))
            } else {
                blocks.append(.init(id: blocks.count, kind: .paragraph, text: line))
            }
        }

        return blocks
    }

    private static func text(of line: String, afterPrefix prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func bulletText(of line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func indentLevel(of rawLine: String) -> Int {
        let leadingSpaces = rawLine.prefix { $0 == " " }.count
        let leadingTabs = rawLine.prefix { $0 == "\t" }.count
        return min(2, (leadingSpaces / 2) + leadingTabs)
    }
}

/// Notes for one shipped version.
public struct ReleaseNoteEntry: Identifiable, Hashable, Sendable, Codable {
    /// Marketing version without any tag prefix, for example `2.45.0`.
    public let version: String
    /// The Git tag the notes were generated from, for example `mac-v2.45.0`.
    public let tag: String
    /// ISO-8601 publication timestamp from the GitHub release.
    public let publishedAt: String
    public let markdown: String

    public var id: String { version }

    public init(version: String, tag: String, publishedAt: String, markdown: String) {
        self.version = ReleaseNotesVersion.normalised(version)
        self.tag = tag
        self.publishedAt = publishedAt
        self.markdown = markdown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            version: try container.decode(String.self, forKey: .version),
            tag: try container.decodeIfPresent(String.self, forKey: .tag) ?? "",
            publishedAt: try container.decodeIfPresent(String.self, forKey: .publishedAt) ?? "",
            markdown: try container.decode(String.self, forKey: .markdown)
        )
    }

    public var publishedDate: Date? {
        ReleaseNotesVersion.date(fromISO8601: publishedAt)
    }

    public var blocks: [ReleaseNoteBlock] {
        ReleaseNotesMarkdown.blocks(from: markdown)
    }
}

/// Version string handling shared by the catalogue and the browsing model.
public enum ReleaseNotesVersion {
    /// Strips release-tag decoration so `mac-v2.45.0`, `v2.45.0` and `2.45.0`
    /// all compare equal.
    public static func normalised(_ value: String) -> String {
        var version = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["mac-", "ios-"] where version.lowercased().hasPrefix(prefix) {
            version = String(version.dropFirst(prefix.count))
        }
        if version.lowercased().hasPrefix("v") { version = String(version.dropFirst()) }
        return version.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Orders versions newest first.
    public static func isDescending(_ lhs: String, _ rhs: String) -> Bool {
        let left = components(of: lhs)
        let right = components(of: rhs)
        for index in 0..<max(left.count, right.count) {
            let leftPart = index < left.count ? left[index] : 0
            let rightPart = index < right.count ? right[index] : 0
            if leftPart != rightPart { return leftPart > rightPart }
        }
        return normalised(lhs).compare(normalised(rhs), options: .numeric) == .orderedDescending
    }

    static func components(of value: String) -> [Int] {
        normalised(value)
            .components(separatedBy: CharacterSet(charactersIn: ".-+"))
            .compactMap { Int($0) }
    }

    static func date(fromISO8601 value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

/// The release notes shipped inside the app bundle.
///
/// `Sources/SpeakCore/Resources/ReleaseNotes.json` is refreshed by
/// `scripts/update-release-notes-catalogue.mjs` during the release build from
/// the same Markdown that is published to GitHub Releases, so the notes are
/// available offline and always describe the installed build.
public struct ReleaseNotesCatalog: Sendable, Equatable {
    public static let resourceName = "ReleaseNotes"

    public let entries: [ReleaseNoteEntry]
    public let generatedAt: Date?

    public init(entries: [ReleaseNoteEntry], generatedAt: Date? = nil) {
        self.entries = entries.sorted { ReleaseNotesVersion.isDescending($0.version, $1.version) }
        self.generatedAt = generatedAt
    }

    public static let empty = ReleaseNotesCatalog(entries: [])

    /// The catalogue compiled into SpeakCore's resource bundle.
    public static let bundled: ReleaseNotesCatalog = {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? decode(from: data)
        else { return .empty }
        return catalog
    }()

    public static func decode(from data: Data) throws -> ReleaseNotesCatalog {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return ReleaseNotesCatalog(
            entries: payload.entries,
            generatedAt: payload.generatedAt.flatMap(ReleaseNotesVersion.date(fromISO8601:))
        )
    }

    public var latest: ReleaseNoteEntry? { entries.first }

    public var isEmpty: Bool { entries.isEmpty }

    /// Notes for a version, tolerating tag prefixes such as `mac-v`.
    public func entry(forVersion version: String) -> ReleaseNoteEntry? {
        let wanted = ReleaseNotesVersion.normalised(version)
        guard !wanted.isEmpty else { return nil }
        return entries.first { $0.version == wanted }
    }

    /// The marketing version of the running app, for example `2.45.0`.
    public static func installedVersion(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return ReleaseNotesVersion.normalised(version ?? "")
    }

    private struct Payload: Decodable {
        let generatedAt: String?
        let entries: [ReleaseNoteEntry]
    }
}

/// Drives the in-app release-notes screen on both platforms.
///
/// The installed version is selected by default so its changes are visible
/// immediately, and earlier versions stay browsable from the same surface.
public struct ReleaseNotesBrowser: Equatable, Sendable {
    public let entries: [ReleaseNoteEntry]
    public let installedVersion: String
    public private(set) var selectedVersion: String?

    public init(
        catalog: ReleaseNotesCatalog = .bundled,
        installedVersion: String = ReleaseNotesCatalog.installedVersion()
    ) {
        self.entries = catalog.entries
        self.installedVersion = ReleaseNotesVersion.normalised(installedVersion)
        self.selectedVersion = catalog.entry(forVersion: installedVersion)?.version
            ?? catalog.latest?.version
    }

    public var isEmpty: Bool { entries.isEmpty }

    public var installedEntry: ReleaseNoteEntry? {
        entries.first { $0.version == installedVersion }
    }

    /// True when the running build is newer than anything in the catalogue,
    /// which happens for development and unreleased builds.
    public var hasNotesForInstalledVersion: Bool { installedEntry != nil }

    public var selectedEntry: ReleaseNoteEntry? {
        guard let selectedVersion else { return nil }
        return entries.first { $0.version == selectedVersion }
    }

    public var isShowingInstalledVersion: Bool {
        selectedEntry != nil && selectedEntry?.version == installedVersion
    }

    /// Versions other than the one on screen, newest first.
    public var otherEntries: [ReleaseNoteEntry] {
        entries.filter { $0.version != selectedVersion }
    }

    public var installedVersionTitle: String {
        installedVersion.isEmpty ? "This version" : "Version \(installedVersion)"
    }

    public func title(for entry: ReleaseNoteEntry) -> String {
        entry.version == installedVersion
            ? "Version \(entry.version) (installed)"
            : "Version \(entry.version)"
    }

    public mutating func select(version: String) {
        let wanted = ReleaseNotesVersion.normalised(version)
        guard entries.contains(where: { $0.version == wanted }) else { return }
        selectedVersion = wanted
    }

    public mutating func selectInstalledVersion() {
        guard let installedEntry else { return }
        selectedVersion = installedEntry.version
    }
}
