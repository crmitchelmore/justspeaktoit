import Foundation

/// A stateful, in-memory stand-in for CloudKit Web Services, so sync tests
/// need no Apple ID, API token or network.
///
/// It keeps one container's private database: custom zones, records with
/// change tags, tombstones and an ordered change feed, and the rotating
/// `ckWebAuthToken` session. It implements the documented shapes of the
/// endpoints the client uses — `changes/zone`, `records/lookup`,
/// `records/modify` (create, update with `recordChangeTag`, forceDelete),
/// `zones/modify` and `users/caller` — with their `NOT_FOUND`, `EXISTS`,
/// `CONFLICT`, `ZONE_NOT_FOUND` and `AUTHENTICATION_REQUIRED` answers.
///
/// Every value here is synthetic. Two ways in: `handle(method:url:body:)` for
/// an in-process transport, and `handle(rawRequest:)` for a real HTTP client
/// talking to a loopback socket.
public final class FakeCloudKitWebServer: @unchecked Sendable {
    public struct Response: Sendable {
        public let status: Int
        public let headers: [String: String]
        public let body: Data
    }

    public static let webAuthTokenHeader = "X-Apple-CloudKit-Web-Auth-Token"
    public static let signInURL = "https://idmsa.apple.com/appleauth/auth/authorize/signin?synthetic=1"

    struct StoredRecord {
        var recordType: String
        var fields: [String: Any]
        var changeTag: Int
        var changeSequence: Int
        var deleted: Bool
    }

    let lock = NSLock()
    let apiToken: String
    let containerIdentifier: String
    var userRecordName: String
    var validTokens: Set<String> = []
    var tokenCounter = 0
    /// Each Apple ID has its own private database.
    var zonesByUser: [String: Set<String>] = [:]
    var recordsByUser: [String: [String: [String: StoredRecord]]] = [:]
    var zones: Set<String> {
        get { zonesByUser[userRecordName] ?? [] }
        set { zonesByUser[userRecordName] = newValue }
    }
    var records: [String: [String: StoredRecord]] {
        get { recordsByUser[userRecordName] ?? [:] }
        set { recordsByUser[userRecordName] = newValue }
    }
    var sequence = 0
    var changeTagCounter = 0
    var log: [String] = []
    var pageLimit: Int

    public init(
        apiToken: String,
        containerIdentifier: String,
        userRecordName: String = "_synthetic-user-a",
        pageLimit: Int = 200
    ) {
        self.apiToken = apiToken
        self.containerIdentifier = containerIdentifier
        self.userRecordName = userRecordName
        self.pageLimit = pageLimit
    }

    // MARK: - Test controls

    /// Simulates a completed Apple ID web sign-in and returns its token.
    public func completeSignIn() -> String {
        lock.withLock { newToken() }
    }

    /// Every token issued so far stops working, as when a session expires.
    public func expireSessions() {
        lock.withLock { validTokens.removeAll() }
    }

    /// Another Apple ID signs in: its private database is separate and every
    /// earlier session ends.
    public func switchUser(to name: String) {
        lock.withLock {
            userRecordName = name
            validTokens.removeAll()
        }
    }

    public func setPageLimit(_ limit: Int) {
        lock.withLock { pageLimit = max(1, limit) }
    }

    public func createZone(_ name: String) {
        lock.withLock { _ = zones.insert(name) }
    }

    /// Writes a record exactly as another client (for example a Mac) would.
    /// `fields` maps names to `(value, type)` in the wire representation.
    public func seedRecord(
        zone: String,
        recordName: String,
        recordType: String,
        fields: [String: (value: Any, type: String)]
    ) {
        lock.withLock {
            zones.insert(zone)
            var wire: [String: Any] = [:]
            for (key, field) in fields {
                wire[key] = ["value": field.value, "type": field.type]
            }
            store(zone: zone, name: recordName, type: recordType, fields: wire, deleted: false)
        }
    }

    /// Deletes a record as another client would, leaving a tombstone in the feed.
    public func seedDeletion(zone: String, recordName: String) {
        lock.withLock {
            guard let existing = records[zone]?[recordName] else { return }
            store(zone: zone, name: recordName, type: existing.recordType, fields: [:], deleted: true)
        }
    }

    /// The live fields of a record, as `name: (value, type)`, or `nil` when absent or deleted.
    public func recordFields(zone: String, recordName: String) -> [String: (value: Any, type: String)]? {
        lock.withLock {
            guard let record = records[zone]?[recordName], !record.deleted else { return nil }
            var result: [String: (value: Any, type: String)] = [:]
            for (key, field) in record.fields {
                if let dictionary = field as? [String: Any], let type = dictionary["type"] as? String,
                   let value = dictionary["value"] {
                    result[key] = (value, type)
                }
            }
            return result
        }
    }

    public func recordType(zone: String, recordName: String) -> String? {
        lock.withLock { records[zone]?[recordName].flatMap { $0.deleted ? nil : $0.recordType } }
    }

    public func liveRecordNames(zone: String) -> [String] {
        lock.withLock { (records[zone] ?? [:]).filter { !$0.value.deleted }.keys.sorted() }
    }

    /// Operation paths of every request, for example `private/records/modify`.
    public var requestLog: [String] { lock.withLock { log } }

    // MARK: - HTTP entry points

    public func handle(method: String, url: URL, body: Data?) -> Response {
        lock.withLock { route(method: method, url: url, body: body ?? Data()) }
    }

    /// Parses one HTTP/1.1 request and returns the complete HTTP response bytes.
    public func handle(rawRequest: Data) -> Data {
        guard let request = Self.parse(rawRequest),
              let url = URL(string: "http://127.0.0.1" + request.target) else {
            return Self.serialise(Response(status: 400, headers: [:], body: Data()))
        }
        return Self.serialise(handle(method: request.method, url: url, body: request.body))
    }

    /// The number of bytes a complete request occupies once its headers are
    /// read, or `nil` while the header block is incomplete.
    public static func expectedRequestLength(_ bytes: Data) -> Int? {
        guard let end = bytes.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(bytes: bytes[bytes.startIndex..<end.lowerBound], encoding: .utf8) ?? ""
        var length = 0
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return end.upperBound - bytes.startIndex + length
    }
}
