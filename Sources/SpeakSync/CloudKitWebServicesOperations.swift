import Foundation

/// Operations take the session they belong to; `nil` means the session
/// current when the call begins. A multi-request operation passes one session
/// to every request so none of them can run after a sign-out or sign-in.
extension CloudKitWebServicesClient {
    /// One page of a custom zone's change feed (`changes/zone`). A page too
    /// large for the response limit is requested again with half the record
    /// limit, down to a single record.
    func fetchZoneChanges(
        zoneName: String,
        syncToken: String?,
        in session: CloudKitWebSession? = nil
    ) async throws -> CloudKitWebZoneChanges {
        let session = session ?? self.session()
        var resultsLimit: Int?
        while true {
            do {
                return try await fetchZoneChangesPage(
                    zoneName: zoneName,
                    syncToken: syncToken,
                    resultsLimit: resultsLimit,
                    in: session
                )
            } catch CloudKitWebServicesError.transport(.responseTooLarge) {
                let current = resultsLimit ?? CloudKitWebServicesLimits.maximumRecordsPerResponse
                guard current > 1 else {
                    throw CloudKitWebServicesError.transport(.responseTooLarge(limit: responseLimit))
                }
                resultsLimit = current / 2
            }
        }
    }

    private func fetchZoneChangesPage(
        zoneName: String,
        syncToken: String?,
        resultsLimit: Int?,
        in session: CloudKitWebSession
    ) async throws -> CloudKitWebZoneChanges {
        let zone = CloudKitWebZoneChangesRequest.Zone(
            zoneID: CloudKitWebZoneID(zoneName: zoneName),
            syncToken: syncToken,
            resultsLimit: resultsLimit
        )
        let body = CloudKitWebZoneChangesRequest(zones: [zone])
        let call = try CloudKitWebCall.post(.privateDatabase, "changes/zone", body: body)
        let response = try await perform(call, in: session, as: CloudKitWebZonesResponse.self)
        let matching = response.zones.first { $0.zoneName == zoneName }
        guard let result = matching ?? (response.zones.count == 1 ? response.zones.first : nil) else {
            throw CloudKitWebServicesError.invalidResponse("The change feed omitted the requested zone.")
        }
        switch result {
        case .failure(_, let error):
            throw CloudKitWebServicesError.server(error)
        case .changes(_, let changes):
            return changes
        }
    }

    /// Fetches records by name (`records/lookup`); each result is a record or a
    /// per-record error such as `NOT_FOUND`.
    func lookupRecords(
        zoneName: String,
        recordNames: [String],
        in session: CloudKitWebSession? = nil
    ) async throws -> [CloudKitWebRecordResult] {
        let body = CloudKitWebLookupRequest(
            records: recordNames.map(CloudKitWebLookupRequest.RecordName.init),
            zoneID: CloudKitWebZoneID(zoneName: zoneName)
        )
        let call = try CloudKitWebCall.post(.privateDatabase, "records/lookup", body: body)
        return try await perform(call, in: session, as: CloudKitWebRecordsResponse.self).records
    }

    /// Applies operations independently (`atomic: false`), so each record
    /// succeeds or fails on its own as native per-record saves do. Record
    /// fields are not echoed back.
    func modifyRecords(
        zoneName: String,
        operations: [CloudKitWebRecordOperation],
        in session: CloudKitWebSession? = nil
    ) async throws -> [CloudKitWebRecordResult] {
        let body = CloudKitWebModifyRequest(
            operations: operations,
            zoneID: CloudKitWebZoneID(zoneName: zoneName),
            atomic: false,
            desiredKeys: []
        )
        let call = try CloudKitWebCall.post(.privateDatabase, "records/modify", body: body)
        return try await perform(call, in: session, as: CloudKitWebRecordsResponse.self).records
    }

    /// Creates a custom zone. An existing zone is success.
    func createZone(zoneName: String, in session: CloudKitWebSession? = nil) async throws {
        let operation = CloudKitWebZonesModifyRequest.Operation(
            operationType: "create",
            zone: CloudKitWebZonesModifyRequest.Zone(zoneID: CloudKitWebZoneID(zoneName: zoneName))
        )
        let body = CloudKitWebZonesModifyRequest(operations: [operation])
        let call = try CloudKitWebCall.post(.privateDatabase, "zones/modify", body: body)
        let response = try await perform(call, in: session, as: CloudKitWebZonesResponse.self)
        for case .failure(_, let error) in response.zones where error.code != .exists {
            throw CloudKitWebServicesError.server(error)
        }
    }

    /// The signed-in user's container-scoped record name (`users/caller`), the
    /// same value a native client reads from `userRecordID()`.
    public func currentUserRecordName(in session: CloudKitWebSession? = nil) async throws -> String {
        let call = CloudKitWebCall.get(.publicDatabase, "users/caller")
        let response = try await perform(call, in: session, as: CloudKitWebCallerResponse.self)
        guard let name = response.userRecordName, !name.isEmpty else {
            throw CloudKitWebServicesError.invalidResponse("The caller identity had no user record name.")
        }
        return name
    }
}

// MARK: - Request bodies

struct CloudKitWebZoneChangesRequest: Encodable {
    struct Zone: Encodable {
        let zoneID: CloudKitWebZoneID
        let syncToken: String?
        let resultsLimit: Int?
    }

    let zones: [Zone]
}

struct CloudKitWebLookupRequest: Encodable {
    struct RecordName: Encodable {
        let recordName: String
    }

    let records: [RecordName]
    let zoneID: CloudKitWebZoneID
}

struct CloudKitWebModifyRequest: Encodable {
    let operations: [CloudKitWebRecordOperation]
    let zoneID: CloudKitWebZoneID
    let atomic: Bool
    let desiredKeys: [String]?
}

struct CloudKitWebZonesModifyRequest: Encodable {
    struct Zone: Encodable {
        let zoneID: CloudKitWebZoneID
    }

    struct Operation: Encodable {
        let operationType: String
        let zone: Zone
    }

    let operations: [Operation]
}

/// A record field in a request: a typed value, or an explicit null that clears it.
struct CloudKitWebFieldPayload: Encodable, Equatable {
    let value: SyncFieldValue?

    private enum CodingKeys: String, CodingKey {
        case value
        case type
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch value {
        case nil:
            try container.encodeNil(forKey: .value)
        case .string(let text)?:
            try container.encode(text, forKey: .value)
            try container.encode("STRING", forKey: .type)
        case .int64(let integer)?:
            try container.encode(integer, forKey: .value)
            try container.encode("INT64", forKey: .type)
        case .double(let number)?:
            try container.encode(number, forKey: .value)
            try container.encode("DOUBLE", forKey: .type)
        case .timestamp(let date)?:
            guard let milliseconds = CloudKitWebTimestamp.milliseconds(date) else { throw SyncError.encodingFailed }
            try container.encode(milliseconds, forKey: .value)
            try container.encode("TIMESTAMP", forKey: .type)
        case .bytes(let bytes)?:
            try container.encode(bytes.base64EncodedString(), forKey: .value)
            try container.encode("BYTES", forKey: .type)
        }
    }
}

struct CloudKitWebRecordOperation: Encodable, Equatable {
    enum Kind: String, Encodable {
        case create
        case update
        case forceDelete
    }

    struct Record: Encodable, Equatable {
        let recordName: String
        let recordType: String?
        let recordChangeTag: String?
        let fields: [String: CloudKitWebFieldPayload]?
    }

    let operationType: Kind
    let record: Record
}
