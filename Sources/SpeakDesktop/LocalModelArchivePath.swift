import Foundation

/// Validates archive entry names before anything is written.
///
/// Names are relative POSIX paths of ASCII letters, digits, `-`, `_`, `.`
/// and `+`. Absolute, drive, UNC and alternate-stream forms, `.`/`..`,
/// empty components, Windows device names, trailing dots or spaces and
/// over-long names are refused, so no entry can address anything outside the
/// extraction directory on either platform.
public enum LocalModelArchivePath {
    public static let maximumLength = 240
    public static let maximumComponentLength = 100

    private static let reservedDeviceNames: Set<String> = {
        var names: Set<String> = ["con", "prn", "aux", "nul", "conin$", "conout$", "clock$"]
        for index in 0...9 {
            names.insert("com\(index)")
            names.insert("lpt\(index)")
        }
        return names
    }()

    /// Returns the normalised components of `raw`. A single trailing `/`
    /// (the tar spelling of a directory) is accepted.
    public static func components(of raw: String) throws -> [String] {
        var name = raw
        if name.hasSuffix("/") { name.removeLast() }
        guard !name.isEmpty, name.utf8.count <= maximumLength else {
            throw LocalModelArchiveError.unsafePath(raw)
        }
        guard !name.hasPrefix("/") else { throw LocalModelArchiveError.unsafePath(raw) }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for part in parts where !isSafeComponent(part) {
            throw LocalModelArchiveError.unsafePath(raw)
        }
        return parts
    }

    static func isSafeComponent(_ part: String) -> Bool {
        guard !part.isEmpty, part != ".", part != "..", part.utf8.count <= maximumComponentLength,
              !part.hasSuffix("."), !part.hasSuffix(" ") else { return false }
        let allowed = part.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5a).contains(byte) || (0x61...0x7a).contains(byte)
                || byte == 0x2d || byte == 0x5f || byte == 0x2e || byte == 0x2b
        }
        guard allowed else { return false }
        let stem = part.lowercased().split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
        return !reservedDeviceNames.contains(stem)
    }

    /// Case-insensitive identity: Windows and default macOS volumes treat
    /// names differing only by case as the same file.
    static func collisionKey(_ components: [String]) -> String {
        components.joined(separator: "/").lowercased()
    }
}

public enum LocalModelArchiveError: LocalizedError, Equatable {
    case unsafePath(String)
    case unsupportedEntry(String, String)
    case unsupportedFormat(String)
    case corruptHeader(String)
    case duplicateEntry(String)
    case unexpectedEntry(String)
    case missingEntry(String)
    case sizeMismatch(String)
    case digestMismatch(String)
    case expandedSizeMismatch
    case truncated
    case trailingData

    public var errorDescription: String? {
        switch self {
        case .unsafePath(let name):
            return "The archive contains an unsafe path (\(Self.printable(name))). Nothing was installed."
        case .unsupportedEntry(let name, let kind):
            return "The archive contains a \(kind) (\(Self.printable(name))), which is refused."
        case .unsupportedFormat(let detail):
            return "The archive format is not supported (\(detail))."
        case .corruptHeader(let detail):
            return "The archive has a corrupt entry header (\(detail))."
        case .duplicateEntry(let name):
            return "The archive lists \(Self.printable(name)) more than once, including by letter case."
        case .unexpectedEntry(let name):
            return "The archive contains \(Self.printable(name)), which is not part of the pinned model."
        case .missingEntry(let name):
            return "The archive is missing \(Self.printable(name))."
        case .sizeMismatch(let name):
            return "\(Self.printable(name)) does not have its pinned size."
        case .digestMismatch(let name):
            return "\(Self.printable(name)) does not match its pinned SHA-256."
        case .expandedSizeMismatch:
            return "The archive does not expand to its pinned size."
        case .truncated:
            return "The archive ended before its last entry was complete."
        case .trailingData:
            return "The archive contains data after its end marker."
        }
    }

    /// Entry names come from untrusted bytes: bound and neutralise them.
    private static func printable(_ name: String) -> String {
        let scalars = name.unicodeScalars.prefix(120).map { scalar in
            scalar.value < 0x20 || scalar.value == 0x7f ? "?" : String(scalar)
        }
        return "\"" + scalars.joined() + "\""
    }
}
