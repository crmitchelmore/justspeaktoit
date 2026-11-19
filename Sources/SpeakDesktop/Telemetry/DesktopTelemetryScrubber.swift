import Foundation

/// Reduces an error message to text that is safe to leave the device: no
/// transcript or quoted user text, credentials, URL queries, e-mail addresses,
/// identifiers or file paths that carry a user name.
public enum DesktopTelemetryScrubber {
    public static let maximumLength = 300

    private static let rules: [(NSRegularExpression, String)] = [
        // Quoted text is where transcripts, prompts and file names appear.
        (#""[^"]*""#, "\"[text]\""),
        (#"“[^”]*”"#, "\"[text]\""),
        (#"«[^»]*»"#, "\"[text]\""),
        // URLs keep scheme and host only: paths and queries can carry tokens.
        (#"(?i)\b([a-z][a-z0-9+.-]*://[^/\s?#]+)[/?#]\S*"#, "$1/[redacted]"),
        (#"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]+"#, "$1 [redacted]"),
        (#"(?i)\b(api[_-]?key|secret|password|passwd|token|authorization|auth)\s*[:=]\s*\S+"#, "$1=[redacted]"),
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "[email]"),
        // Home folders on Windows, Linux and macOS, with any user name.
        // Windows user names may contain spaces, so the name runs to the next separator.
        (#"(?i)\b[a-z]:[\\/]+(?:users|documents and settings)[\\/]+[^\\/\r\n,;:"']+"#, "~"),
        (#"(?:/home|/Users|/var/home)/[^/\s]+"#, "~"),
        (#"\\\\[^\\\s]+\\[^\\\s]+"#, "[network path]"),
        // Keys, tokens, UUIDs and other long opaque values.
        (#"\b(?:sk|pk|rk|phc|gsk|xai)[-_][A-Za-z0-9_-]{8,}"#, "[redacted]"),
        (#"[A-Za-z0-9_+=-]{24,}"#, "[redacted]"),
        (#"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#, "[id]")
    ].map { pattern, template in
        // swiftlint:disable:next force_try
        (try! NSRegularExpression(pattern: pattern), template)
    }

    public static func scrub(_ text: String, homeDirectory: String? = currentHomeDirectory) -> String {
        var result = String(text.prefix(4 * maximumLength))
        if var home = homeDirectory {
            while home.hasSuffix("/") || home.hasSuffix("\\") { home.removeLast() }
            for variant in Set([home, home.replacingOccurrences(of: "\\", with: "/")]) where variant.count > 3 {
                result = result.replacingOccurrences(of: variant, with: "~", options: .caseInsensitive)
            }
        }
        for (expression, template) in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = expression.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        let collapsed = result.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed.count > maximumLength ? String(collapsed.prefix(maximumLength - 1)) + "…" : collapsed
    }

    public static var currentHomeDirectory: String? {
        let environment = ProcessInfo.processInfo.environment
        return environment["USERPROFILE"] ?? environment["HOME"]
    }
}
