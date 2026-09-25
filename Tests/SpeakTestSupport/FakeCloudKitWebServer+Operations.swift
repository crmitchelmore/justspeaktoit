import Foundation

// Endpoint behaviour and HTTP framing for `FakeCloudKitWebServer`. Every
// method here runs with the server's lock held.
extension FakeCloudKitWebServer {
    // MARK: - Routing (lock held)

    func route(method: String, url: URL, body: Data) -> Response {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            query[item.name] = item.value
        }
        let path = url.path.split(separator: "/").map(String.init)
        guard path.count >= 6, path[0] == "database", path[1] == "1", path[2] == containerIdentifier,
              ["development", "production"].contains(path[3]) else {
            return error(status: 404, code: "NOT_FOUND", reason: "unknown path")
        }
        let database = path[4]
        let operation = path[5...].joined(separator: "/")
        log.append(database + "/" + operation)
        guard query["ckAPIToken"] == apiToken else {
            return error(status: 401, code: "AUTHENTICATION_FAILED", reason: "invalid API token")
        }
        guard let token = query["ckWebAuthToken"], validTokens.contains(token) else {
            var body = errorBody(code: "AUTHENTICATION_REQUIRED", reason: "sign in required")
            body["redirectURL"] = Self.signInURL
            return json(status: 421, body, rotating: nil)
        }
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        guard let result = dispatch(method: method, database: database, operation: operation, body: object) else {
            return error(status: 400, code: "BAD_REQUEST", reason: "unsupported operation")
        }
        return json(status: 200, result, rotating: token)
    }

    func dispatch(method: String, database: String, operation: String, body: [String: Any]) -> [String: Any]? {
        switch (method, database, operation) {
        case ("GET", "public", "users/caller"): return ["users": [["userRecordName": userRecordName]]]
        case ("POST", "private", "zones/modify"): return modifyZones(body)
        case ("POST", "private", "changes/zone"): return zoneChanges(body)
        case ("POST", "private", "records/lookup"): return lookup(body)
        case ("POST", "private", "records/modify"): return modify(body)
        default: return nil
        }
    }

    func modifyZones(_ body: [String: Any]) -> [String: Any] {
        var results: [[String: Any]] = []
        for operation in body["operations"] as? [[String: Any]] ?? [] {
            let zoneID = (operation["zone"] as? [String: Any])?["zoneID"] as? [String: Any]
            let name = zoneID?["zoneName"] as? String ?? ""
            zones.insert(name)
            results.append(["zoneID": ["zoneName": name]])
        }
        return ["zones": results]
    }

    func zoneChanges(_ body: [String: Any]) -> [String: Any] {
        var results: [[String: Any]] = []
        for zone in body["zones"] as? [[String: Any]] ?? [] {
            let name = (zone["zoneID"] as? [String: Any])?["zoneName"] as? String ?? ""
            guard zones.contains(name) else {
                var failure = errorBody(code: "ZONE_NOT_FOUND", reason: "zone not found")
                failure["zoneID"] = ["zoneName": name]
                results.append(failure)
                continue
            }
            let after = (zone["syncToken"] as? String).flatMap { Int($0.dropFirst("seq-".count)) } ?? 0
            let limit = min(pageLimit, (zone["resultsLimit"] as? Int) ?? pageLimit)
            let changed = (records[name] ?? [:])
                .filter { $0.value.changeSequence > after }
                .sorted { $0.value.changeSequence < $1.value.changeSequence }
            let page = changed.prefix(limit)
            let last = page.last?.value.changeSequence ?? after
            results.append([
                "zoneID": ["zoneName": name],
                "syncToken": "seq-\(last)",
                "moreComing": changed.count > page.count,
                "records": page.map { wire(name: $0.key, record: $0.value, includeFields: true) }
            ])
        }
        return ["zones": results]
    }

    func lookup(_ body: [String: Any]) -> [String: Any] {
        let zone = (body["zoneID"] as? [String: Any])?["zoneName"] as? String ?? ""
        var results: [[String: Any]] = []
        for entry in body["records"] as? [[String: Any]] ?? [] {
            let name = entry["recordName"] as? String ?? ""
            if let record = records[zone]?[name], !record.deleted {
                results.append(wire(name: name, record: record, includeFields: true))
            } else {
                results.append(recordError(name, code: "NOT_FOUND"))
            }
        }
        return ["records": results]
    }

    func modify(_ body: [String: Any]) -> [String: Any] {
        let zone = (body["zoneID"] as? [String: Any])?["zoneName"] as? String ?? ""
        guard zones.contains(zone) else {
            return ["records": (body["operations"] as? [[String: Any]] ?? []).map { operation in
                recordError(((operation["record"] as? [String: Any])?["recordName"] as? String) ?? "",
                            code: "ZONE_NOT_FOUND")
            }]
        }
        let operations = body["operations"] as? [[String: Any]] ?? []
        return ["records": operations.map { apply($0, zone: zone) }]
    }

    /// One `records/modify` operation: the saved record, or a per-record error.
    func apply(_ operation: [String: Any], zone: String) -> [String: Any] {
        let record = operation["record"] as? [String: Any] ?? [:]
        let name = record["recordName"] as? String ?? ""
        let existing = records[zone]?[name].flatMap { $0.deleted ? nil : $0 }
        let fields = record["fields"] as? [String: Any] ?? [:]
        switch operation["operationType"] as? String ?? "" {
        case "create":
            guard existing == nil else { return recordError(name, code: "EXISTS") }
            let live = fields.filter { !Self.isNull($0.value) }
            store(zone: zone, name: name, type: record["recordType"] as? String ?? "", fields: live, deleted: false)
        case "update":
            guard let existing else { return recordError(name, code: "NOT_FOUND") }
            guard record["recordChangeTag"] as? String == String(existing.changeTag) else {
                return recordError(name, code: "CONFLICT")
            }
            var merged = existing.fields
            for (key, value) in fields {
                merged[key] = Self.isNull(value) ? nil : value
            }
            store(zone: zone, name: name, type: existing.recordType, fields: merged, deleted: false)
        case "forceDelete":
            guard let existing else { return recordError(name, code: "NOT_FOUND") }
            store(zone: zone, name: name, type: existing.recordType, fields: [:], deleted: true)
        default:
            return recordError(name, code: "BAD_REQUEST")
        }
        return records[zone]?[name].map { wire(name: name, record: $0, includeFields: false) } ?? [:]
    }

    // MARK: - Helpers (lock held)

    func store(zone: String, name: String, type: String, fields: [String: Any], deleted: Bool) {
        sequence += 1
        changeTagCounter += 1
        var zoneRecords = records[zone] ?? [:]
        zoneRecords[name] = StoredRecord(
            recordType: type,
            fields: fields,
            changeTag: changeTagCounter,
            changeSequence: sequence,
            deleted: deleted
        )
        records[zone] = zoneRecords
    }

    func wire(name: String, record: StoredRecord, includeFields: Bool) -> [String: Any] {
        if record.deleted {
            return ["recordName": name, "recordType": record.recordType, "deleted": true]
        }
        var result: [String: Any] = [
            "recordName": name,
            "recordType": record.recordType,
            "recordChangeTag": String(record.changeTag)
        ]
        if includeFields {
            result["fields"] = record.fields
        }
        return result
    }

    func newToken() -> String {
        tokenCounter += 1
        let token = "synthetic+web/auth=\(tokenCounter)"
        validTokens.insert(token)
        return token
    }

    func json(status: Int, _ object: [String: Any], rotating token: String?) -> Response {
        var headers = ["Content-Type": "application/json"]
        if let token {
            validTokens.remove(token)
            headers[Self.webAuthTokenHeader] = newToken()
        }
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return Response(status: status, headers: headers, body: body)
    }

    func errorBody(code: String, reason: String) -> [String: Any] {
        ["serverErrorCode": code, "reason": reason, "uuid": "synthetic-uuid"]
    }

    func error(status: Int, code: String, reason: String) -> Response {
        json(status: status, errorBody(code: code, reason: reason), rotating: nil)
    }

    func recordError(_ name: String, code: String) -> [String: Any] {
        var body = errorBody(code: code, reason: "synthetic \(code)")
        body["recordName"] = name
        return body
    }

    static func isNull(_ value: Any) -> Bool {
        guard let dictionary = value as? [String: Any] else { return value is NSNull }
        return dictionary["value"] == nil || dictionary["value"] is NSNull
    }

    // MARK: - HTTP/1.1 framing

    struct ParsedRequest {
        let method: String
        let target: String
        let body: Data
    }

    static func parse(_ bytes: Data) -> ParsedRequest? {
        guard let end = bytes.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(bytes: bytes[bytes.startIndex..<end.lowerBound], encoding: .utf8) ?? ""
        let requestLine = head.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
        guard requestLine.count == 3 else { return nil }
        return ParsedRequest(
            method: String(requestLine[0]),
            target: String(requestLine[1]),
            body: Data(bytes[end.upperBound...])
        )
    }

    static func serialise(_ response: Response) -> Data {
        var head = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Error")\r\n"
        for (name, value) in response.headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + response.body
    }
}
