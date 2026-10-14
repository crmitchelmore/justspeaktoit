import Foundation

public enum VocabularyMigrationFixtures {
    public static let firstID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    public static let secondID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    public static func data(kind: String) throws -> Data {
        let payload: String
        switch kind {
        case "pronunciation":
            payload = """
            {"id":"\(firstID)","word":"Fixture","pronunciation":"fix chur","replacement":null,
             "category":"Synthetic","isRegex":false,"caseSensitive":true}
            """
        case "lexicon":
            payload = """
            {"id":"\(firstID)","displayName":"Fixture","canonical":"Fixture","aliases":["fixture typo"],
             "activation":"manual","contextTags":["Synthetic"],"confidence":"low","notes":null,"source":"manual",
             "createdAt":"2000-01-01T00:00:00Z","updatedAt":"2001-01-01T00:00:00Z",
             "timestamp":"2024-01-01T00:00:00Z"}
            """
        case "correction":
            payload = """
            {"id":"\(firstID)","original":"fixture typo","corrected":"Fixture","seenCount":1,
             "firstSeenAt":"2000-01-01T00:00:00Z","lastSeenAt":"2000-01-02T00:00:00Z",
             "sourceApps":["Synthetic"],"dismissed":true}
            """
        default:
            throw CocoaError(.coderInvalidValue)
        }
        guard var object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        object["future"] = ["nested": ["flag": true, "value": NSNull(), "items": [1, "retained"]]]
        let first = object
        object["id"] = secondID
        if kind == "correction" { object["dismissed"] = false }
        return try JSONSerialization.data(withJSONObject: [first, object], options: [.sortedKeys])
    }
}
