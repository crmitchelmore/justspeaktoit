import Foundation

// The keychain payload format.
//
// Mixed-version contract (issue #672). Two keychain items per store:
//
// | Account                     | Format          | Contents                        |
// |-----------------------------|-----------------|---------------------------------|
// | masterAccount               | legacy `k=v;`   | every legacy-representable entry|
// | masterAccount.v2            | versioned v2    | entries legacy cannot represent |
// | masterAccount.unsupported-… | opaque          | backup of a newer-version item  |
//
// The master account stays in the legacy interchange format so *every*
// shipped parser — including pre-versioning builds after a rollback —
// reads correct plaintext values and never sees percent-encoded secrets
// or a version marker as an identifier. Values the legacy format cannot
// carry (containing `;`, or edge whitespace the legacy parser trims)
// live only in the versioned overflow item, which legacy builds never
// read. On load the two are merged with the master account winning per
// key. A payload carrying a *newer* version marker than this build
// understands is preserved to a backup account and never parsed as
// legacy or overwritten silently.
//
// Version migration table — extend this (and the fixtures in
// SecureStoragePayloadFormatTests) whenever a version is added; never
// change an existing format in place:
//
// | Marker  | Body                                   | Introduced |
// |---------|----------------------------------------|------------|
// | (none)  | raw `key=value;key=value`              | v1 (legacy)|
// | `v2:;`  | percent-encoded `key=value;` pairs     | #631       |

extension SecureStorage {
    /// The payload version this build writes for the overflow item.
    static let currentPayloadVersion = 2

    /// Prefix identifying the current payload format. The trailing `;` makes the marker
    /// unforgeable by the legacy serializer: a legacy payload always begins with an
    /// identifier followed by `=`, so it can never start with `v2:;`. A legacy identifier
    /// that merely starts with `v2:` therefore still parses as legacy data.
    static let payloadVersionPrefix = "v2:;"

    /// Characters that may appear unescaped in an encoded payload key or value.
    /// The structural characters `;` and `=`, and the escape character `%`, are excluded.
    private static let payloadComponentAllowedCharacters: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ";=%&+")
        return allowed
    }()

    /// Explicit format-detection result: secrets, or a version this build
    /// does not understand (never interpreted as legacy data).
    enum ParsedPayload: Equatable {
        case secrets([String: String])
        case unsupportedVersion(String)
    }

    /// The `v<digits>:;` marker version, or `nil` for legacy payloads. The
    /// mandatory `;` directly after the colon keeps legacy identifiers that
    /// merely start with `v2:` parsing as legacy data.
    static func versionMarker(of payload: String) -> Int? {
        guard payload.first == "v", let colon = payload.firstIndex(of: ":") else { return nil }
        let digits = payload[payload.index(after: payload.startIndex)..<colon]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        let afterColon = payload.index(after: colon)
        guard afterColon < payload.endIndex, payload[afterColon] == ";" else { return nil }
        return Int(digits)
    }

    static func parsePayload(_ payload: String) -> ParsedPayload {
        guard let version = versionMarker(of: payload) else {
            return .secrets(parseLegacyPayload(payload))
        }
        guard version == currentPayloadVersion else {
            return .unsupportedVersion("v\(version)")
        }
        return .secrets(parseVersionedBody(payload))
    }

    /// Convenience for callers that treat an unsupported version as empty.
    /// The load path uses `parsePayload` so it can preserve a backup first.
    static func parse(payload: String) -> [String: String] {
        guard case .secrets(let secrets) = parsePayload(payload) else { return [:] }
        return secrets
    }

    private static func parseVersionedBody(_ payload: String) -> [String: String] {
        payload
            .dropFirst(payloadVersionPrefix.count)
            .split(separator: ";")
            .reduce(into: [String: String]()) { partialResult, item in
                let components = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let keyComponent = components.first else { return }
                let key = String(keyComponent).removingPercentEncoding ?? String(keyComponent)
                guard !key.isEmpty else { return }
                let rawValue = components.count > 1 ? String(components[1]) : ""
                partialResult[key] = rawValue.removingPercentEncoding ?? rawValue
            }
    }

    private static func parseLegacyPayload(_ payload: String) -> [String: String] {
        payload
            .split(separator: ";")
            .reduce(into: [String: String]()) { partialResult, item in
                let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                let components = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let keyComponent = components.first else { return }
                let key = String(keyComponent)
                let value = components.count > 1 ? String(components[1]) : ""
                partialResult[key] = value
            }
    }

    /// Serializes to the current versioned format. An empty cache serializes to an empty
    /// string (not a bare version prefix) so `writePayload` still deletes the item.
    static func serialize(cache: [String: String]) -> String {
        guard !cache.isEmpty else { return "" }

        let body = cache
            .sorted { $0.key < $1.key }
            .map { "\(encodePayloadComponent($0.key))=\(encodePayloadComponent($0.value))" }
            .joined(separator: ";")
        return payloadVersionPrefix + body
    }

    /// Whether the legacy `key=value;` format can carry this entry verbatim:
    /// the identifier must survive the `;`/first-`=` splits and the legacy
    /// parser's pair trimming unchanged, and the value must survive the `;`
    /// split and trailing trim. Anything else belongs to the overflow item —
    /// a legacy reader must never receive a percent-encoded stand-in.
    static func isLegacyRepresentable(identifier: String, value: String) -> Bool {
        guard !identifier.isEmpty,
              !identifier.contains(";"), !identifier.contains("="),
              identifier.trimmingCharacters(in: .whitespacesAndNewlines) == identifier
        else { return false }
        guard !value.contains(";"),
              value.trimmingCharacters(in: .whitespacesAndNewlines) == value
        else { return false }
        return true
    }

    /// The legacy-format compatibility record for the master account.
    static func serializeLegacyCompatibilityRecord(cache: [String: String]) -> String {
        cache
            .filter { isLegacyRepresentable(identifier: $0.key, value: $0.value) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ";")
    }

    /// The versioned payload for entries the legacy format cannot represent.
    static func serializeOverflowPayload(cache: [String: String]) -> String {
        serialize(cache: cache.filter { !isLegacyRepresentable(identifier: $0.key, value: $0.value) })
    }

    private static func encodePayloadComponent(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: payloadComponentAllowedCharacters) ?? component
    }
}
