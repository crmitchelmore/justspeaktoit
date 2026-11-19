import Foundation

/// Redacts sensitive header values to prevent exposure in debug UI, logs, or screenshots
///
/// This is the single registry of credential-carrying names for the whole app.
/// Add a provider's header or query-item name here, not to a second list next to
/// the consumer (debug snapshots, logs, crash reports).
public enum SensitiveHeaderRedactor {
    /// The marker that replaces a credential. Callers can compare against it.
    public static let redactionMarker = "[REDACTED]"

    /// Headers that may contain sensitive authentication or API key information
    private static let sensitiveHeaderKeys: Set<String> = [
        "authorization",
        "api-key",
        "x-api-key",
        "token",
        "x-auth-token",
        "bearer",
        "x-access-token",
        "openai-api-key",
        "deepgram-api-key",
        "anthropic-api-key",
        "xi-api-key",
        "x-gladia-key",
        // Azure Speech sends the subscription key under this name.
        "ocp-apim-subscription-key",
        "subscription-key",
        "x-goog-api-key"
    ]

    /// URL query item names that carry a credential.
    ///
    /// Some providers put the key in the URL instead of a header: AssemblyAI uses
    /// `token`, Modulate uses `api_key`. `token` is also a header name, so the two
    /// sets are unioned rather than duplicated.
    private static let sensitiveQueryItemNames: Set<String> = [
        "api_key",
        "apikey",
        "access_token",
        "auth_token",
        "key",
        "secret",
        "signature",
        "sig",
        "subscription_key"
    ]

    /// Redacts sensitive headers in a dictionary by masking values
    /// - Parameter headers: Dictionary of HTTP headers
    /// - Returns: Dictionary with sensitive values redacted
    public static func redactSensitiveHeaders(_ headers: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in headers {
            // Check if this is a sensitive key OR a sensitive value pattern
            if isSensitiveKey(key) || isSensitiveValue(value) {
                result[key] = redactValue(value)
            } else {
                result[key] = value
            }
        }
        return result
    }

    /// Redacts sensitive headers with a fixed marker, keeping **no** fragment of
    /// the original value.
    ///
    /// Use this wherever the redacted headers are stored or displayed (debug
    /// snapshots, logs, screenshots): `redactSensitiveHeaders` keeps a
    /// recognisable prefix/suffix, which is fine for interactive "is this the key
    /// I pasted?" comparison but is still credential material at rest.
    /// - Parameter headers: Dictionary of HTTP headers
    /// - Returns: Dictionary with every sensitive value replaced by `[REDACTED]`
    public static func fullyRedactSensitiveHeaders(_ headers: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in headers {
            if isSensitiveKey(key) || isSensitiveValue(value) {
                // Keep the scheme so the snapshot still shows *how* the request
                // authenticated; the token itself is gone.
                result[key] = value.trimmingCharacters(in: .whitespaces).hasPrefix("Bearer ")
                    ? "Bearer \(redactionMarker)"
                    : redactionMarker
            } else {
                result[key] = value
            }
        }
        return result
    }

    /// Determines if a header key is sensitive
    /// - Parameter key: Header name
    /// - Returns: True if the header is known to contain sensitive data
    public static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return sensitiveHeaderKeys.contains(normalized)
    }

    /// Determines if a URL query item name carries a credential
    /// - Parameter name: Query item name, percent-encoded or not
    /// - Returns: True if the query item is known to contain a credential
    public static func isSensitiveQueryItemName(_ name: String) -> Bool {
        let decoded = name.removingPercentEncoding ?? name
        let normalized = decoded.lowercased()
        return sensitiveQueryItemNames.contains(normalized) || isSensitiveKey(normalized)
    }

    /// Redacts credentials in a raw query string such as `token=abc&model=nova`
    ///
    /// The string is rewritten pair by pair, so ordering, unknown pairs and
    /// percent-encoding all survive.
    /// - Parameter queryString: Query string without the leading `?`
    /// - Returns: The query string with every credential value replaced
    public static func redactSensitiveQueryString(_ queryString: String) -> String {
        let pairs = queryString.split(separator: "&", omittingEmptySubsequences: false)
        let redactedPairs = pairs.map { pair -> String in
            guard let separator = pair.firstIndex(of: "=") else {
                return String(pair)
            }
            let name = String(pair[..<separator])
            let value = String(pair[pair.index(after: separator)...])
            guard isSensitiveQueryItemName(name) || isSensitiveValue(value) else {
                return String(pair)
            }
            return "\(name)=\(redactionMarker)"
        }
        return redactedPairs.joined(separator: "&")
    }

    /// Redacts credentials carried in the query string of a URL
    ///
    /// Strings that hold no query string are returned unchanged, so this is safe
    /// to run over free-form text such as a log line or a breadcrumb message.
    /// - Parameter urlString: A URL, or text that may contain one
    /// - Returns: The same string with every credential query value replaced
    public static func redactSensitiveQueryItems(in urlString: String) -> String {
        guard let queryStart = urlString.firstIndex(of: "?") else {
            return urlString
        }
        let base = String(urlString[...queryStart])
        let remainder = String(urlString[urlString.index(after: queryStart)...])
        let parts = remainder.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let query = redactSensitiveQueryString(String(parts[0]))
        let fragment = parts.count > 1 ? "#\(parts[1])" : ""
        return base + query + fragment
    }

    /// Redacts every credential in a nested payload of arbitrary values
    ///
    /// Use this for structures the app does not control field by field, such as
    /// crash-report contexts and HTTP breadcrumb data. A value is replaced when
    /// its key is a known credential name, or when the value itself looks like a
    /// credential. Strings are also scanned for credentials in a URL query.
    /// - Parameter payload: Nested dictionary of headers, contexts or free-form data
    /// - Returns: The payload with every credential value replaced
    public static func fullyRedactSensitiveValues(in payload: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in payload {
            if isSensitiveKey(key) || isSensitiveQueryItemName(key) {
                result[key] = redactionMarker
            } else {
                result[key] = redactSensitiveValue(value)
            }
        }
        return result
    }

    /// Redacts a single value of unknown type, recursing into collections
    private static func redactSensitiveValue(_ value: Any) -> Any {
        if let nested = value as? [String: Any] {
            return fullyRedactSensitiveValues(in: nested)
        }
        if let list = value as? [Any] {
            return list.map { redactSensitiveValue($0) }
        }
        if let text = value as? String {
            let withoutQueryCredentials = redactSensitiveQueryItems(in: text)
            return isSensitiveValue(withoutQueryCredentials) ? redactionMarker : withoutQueryCredentials
        }
        return value
    }

    /// Checks if a value appears to be sensitive (e.g., API key, token)
    /// - Parameter value: Header value to check
    /// - Returns: True if the value matches common sensitive patterns
    private static func isSensitiveValue(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)

        // Common API key patterns
        let patterns = [
            "^sk-[A-Za-z0-9]{20,}$",           // OpenAI style: sk-...
            "^Bearer .+$",                       // Bearer tokens
            "^[A-Za-z0-9]{32,}$",               // Long alphanumeric strings (likely keys)
            "^[A-Za-z0-9_-]{40,}$"              // JWT-style tokens
        ]

        for pattern in patterns where trimmed.range(of: pattern, options: .regularExpression) != nil {
            return true
        }

        return false
    }

    /// Redacts a sensitive value by showing only first 3 and last 4 characters
    /// - Parameter value: The sensitive value to redact
    /// - Returns: Redacted string in format "abc...xyz1" or "[REDACTED]" if too short
    public static func redactValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)

        // Handle Bearer tokens specially
        if trimmed.hasPrefix("Bearer ") {
            let token = String(trimmed.dropFirst(7))
            return "Bearer \(redactValue(token))"
        }

        // For very short values, just fully redact
        guard trimmed.count >= 10 else {
            return redactionMarker
        }

        // Show first 3 and last 4 characters with ellipsis in between
        let prefix = String(trimmed.prefix(3))
        let suffix = String(trimmed.suffix(4))
        return "\(prefix)...\(suffix)"
    }
}
