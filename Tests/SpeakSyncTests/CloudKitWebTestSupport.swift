import Foundation
import XCTest

@testable import SpeakSync

/// Synthetic configuration only. No value here is, or resembles, a real
/// container API token or Apple ID session.
enum CloudKitWebFixture {
    static let apiToken = "synthetic-api-token"
    static let containerIdentifier = "iCloud.com.example.synthetic"

    static func configuration() throws -> CloudKitWebServicesConfiguration {
        try CloudKitWebServicesConfiguration(
            containerIdentifier: containerIdentifier,
            environment: .development,
            apiToken: apiToken
        )
    }

    static func data(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    static func response(
        status: Int = 200,
        _ object: Any,
        rotatedToken: String? = nil,
        header: String = CloudKitWebServicesClient.webAuthTokenHeader
    ) -> CloudKitWebServicesHTTPResponse {
        var headers = ["Content-Type": "application/json"]
        if let rotatedToken {
            headers[header] = rotatedToken
        }
        return CloudKitWebServicesHTTPResponse(statusCode: status, headers: headers, body: data(object))
    }

    static func serverError(
        _ code: String,
        status: Int,
        retryAfter: Double? = nil,
        rotatedToken: String? = nil
    ) -> CloudKitWebServicesHTTPResponse {
        var body: [String: Any] = ["serverErrorCode": code, "reason": "synthetic \(code)", "uuid": "synthetic-uuid"]
        if let retryAfter {
            body["retryAfter"] = retryAfter
        }
        return response(status: status, body, rotatedToken: rotatedToken)
    }

    static func records(_ records: [[String: Any]]) -> CloudKitWebServicesHTTPResponse {
        response(["records": records])
    }

    static func recordError(_ code: String, recordName: String) -> [String: Any] {
        ["recordName": recordName, "serverErrorCode": code, "reason": "synthetic \(code)"]
    }

    static func field(_ value: Any, _ type: String) -> [String: Any] {
        ["value": value, "type": type]
    }

    static func milliseconds(_ date: Date) -> Int64 {
        CloudKitWebTimestamp.milliseconds(date) ?? 0
    }
}

/// Records every request and answers from a script. It can hold requests
/// until released and honours cancellation while holding, like a real client.
actor ScriptedCloudKitTransport: CloudKitWebServicesHTTPTransport {
    private struct Held {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var scripted: [Result<CloudKitWebServicesHTTPResponse, Error>] = []
    private var fallback = CloudKitWebFixture.records([])
    private var holdsRequests = false
    private var held: [Held] = []
    private(set) var requests: [CloudKitWebServicesHTTPRequest] = []

    var heldCount: Int { held.count }

    func enqueue(_ response: CloudKitWebServicesHTTPResponse) {
        scripted.append(.success(response))
    }

    func enqueue(failure: Error) {
        scripted.append(.failure(failure))
    }

    func setFallback(_ response: CloudKitWebServicesHTTPResponse) {
        fallback = response
    }

    func holdRequests() {
        holdsRequests = true
    }

    func releaseHeldRequests() {
        holdsRequests = false
        let waiting = held
        held.removeAll()
        waiting.forEach { $0.continuation.resume() }
    }

    func send(
        _ request: CloudKitWebServicesHTTPRequest,
        responseLimit: Int
    ) async throws -> CloudKitWebServicesHTTPResponse {
        requests.append(request)
        if holdsRequests {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    held.append(Held(id: id, continuation: continuation))
                    if Task.isCancelled {
                        cancelHeld(id)
                    }
                }
            } onCancel: {
                Task { await self.cancelHeld(id) }
            }
        }
        let response = try (scripted.isEmpty ? .success(fallback) : scripted.removeFirst()).get()
        guard response.body.count <= responseLimit else {
            throw CloudKitWebServicesTransportError.responseTooLarge(limit: responseLimit)
        }
        return response
    }

    private func cancelHeld(_ id: UUID) {
        guard let index = held.firstIndex(where: { $0.id == id }) else { return }
        held.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

/// A token store whose initial reads can be held. A held read captures the
/// value it read and delivers it late, as a slow credential store would.
actor HeldTokenStore: CloudKitWebAuthTokenStore {
    private struct HeldLoad {
        let value: String?
        let continuation: CheckedContinuation<String?, Never>
    }

    private(set) var token: String?
    private(set) var loadCount = 0
    private(set) var saved: [String] = []
    private(set) var clearCount = 0
    private var holdsLoads = false
    private var heldLoads: [HeldLoad] = []
    private var failsSaves = false

    init(token: String?) {
        self.token = token
    }

    func failSaves() {
        failsSaves = true
    }

    var pendingLoadCount: Int { heldLoads.count }

    func holdLoads() {
        holdsLoads = true
    }

    /// Delivers the most recent held read first, so an earlier read lands last.
    func releaseNewestLoad() {
        guard let load = heldLoads.popLast() else { return }
        if heldLoads.isEmpty {
            holdsLoads = false
        }
        load.continuation.resume(returning: load.value)
    }

    func loadWebAuthToken() async throws -> String? {
        loadCount += 1
        let value = token
        guard holdsLoads else { return value }
        return await withCheckedContinuation { heldLoads.append(HeldLoad(value: value, continuation: $0)) }
    }

    func saveWebAuthToken(_ token: String) async throws {
        if failsSaves { throw CloudKitWebTestError.injected }
        self.token = token
        saved.append(token)
    }

    func clearWebAuthToken() async throws {
        token = nil
        clearCount += 1
    }
}

/// A backoff clock that holds every sleep until the test resumes it.
actor HeldSleeper {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var waiters: [Waiter] = []
    private(set) var requested: [Duration] = []

    var waiterCount: Int { waiters.count }

    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                requested.append(duration)
                waiters.append(Waiter(id: id, continuation: continuation))
                if Task.isCancelled {
                    cancel(id)
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func resumeAll() {
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.continuation.resume() }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

extension CloudKitWebServicesHTTPRequest {
    /// The decoded `ckWebAuthToken` query value, if the request carried one.
    var webAuthToken: String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "ckWebAuthToken" }?
            .value
    }

    var bodyText: String {
        body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    var jsonBody: [String: Any] {
        body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
}

enum CloudKitWebTestError: Error {
    case conditionNotMet
    case injected
}

/// A backoff clock that records each wait and returns at once.
actor RecordingSleeper {
    private(set) var requested: [Duration] = []

    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        requested.append(duration)
    }
}

/// Polls an asynchronous condition, yielding between checks.
func eventually(
    attempts: Int = 5_000,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () async -> Bool
) async throws {
    for _ in 0..<attempts {
        if await condition() { return }
        await Task.yield()
    }
    XCTFail("Condition was not satisfied after \(attempts) attempts", file: file, line: line)
    throw CloudKitWebTestError.conditionNotMet
}

func makeTestClient(
    store: HeldTokenStore,
    transport: ScriptedCloudKitTransport,
    sleeper: HeldSleeper? = nil,
    recorder: RecordingSleeper? = nil,
    responseLimit: Int = CloudKitWebServicesClient.defaultResponseLimit
) throws -> CloudKitWebServicesClient {
    let sleep: @Sendable (Duration) async throws -> Void
    if let sleeper {
        sleep = { try await sleeper.sleep($0) }
    } else if let recorder {
        sleep = { try await recorder.sleep($0) }
    } else {
        sleep = { _ in }
    }
    return CloudKitWebServicesClient(
        configuration: try CloudKitWebFixture.configuration(),
        tokenStore: store,
        transport: transport,
        responseLimit: responseLimit,
        sleep: sleep
    )
}
