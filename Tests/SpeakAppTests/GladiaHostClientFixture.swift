import Foundation
import SpeakCore
import XCTest
@testable import SpeakApp

/// Actual configured client with synthetic HTTP/socket/clock. Host lifecycle
/// seams using it bypass credentials and the public factory; pure factory
/// construction has separate tests and no provider request is ever made.
@MainActor
final class GladiaHostClientFixture {
    let transport = AssemblyAIControllerTransport()
    let clock = AssemblyAIControllerClock()
    let requests = GladiaHostRequests()

    func make(language: String? = nil, options: LiveClientOptions = LiveClientOptions()) -> GladiaLiveClient {
        let transport = transport, clock = clock, requests = requests
        return GladiaLiveClient(
            apiKey: "synthetic-unused-key", language: language, options: options,
            initiateSession: { request, completion in
                requests.record(request)
                let body = Data(#"{"url":"wss://api.gladia.io/v2/live?token=synthetic-unused-token"}"#.utf8)
                completion(.success((statusCode: 201, body: body)))
                return GladiaHostRequest()
            }, makeConnection: { transport.make($0) }, schedule: { clock.schedule($0, action: $1) }
        )
    }
}

final class GladiaHostRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    var all: [URLRequest] { lock.withLock { values } }
    func record(_ request: URLRequest) { lock.withLock { values.append(request) } }
}
private final class GladiaHostRequest: GladiaLiveSessionRequest {
    func cancel() {}
}
