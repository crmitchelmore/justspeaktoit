import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore

final class AssemblyAILiveFixture: @unchecked Sendable {
    let factory = AssemblyAISocketFactory()
    let clock = AssemblyAITestClock()
    let events = AssemblyAITestEvents()
    let client: AssemblyAILiveClient
    init(key: String = "synthetic") {
        let factory = factory, clock = clock
        client = AssemblyAILiveClient(apiKey: key, makeConnection: { factory.make($0) },
                                       schedule: { clock.schedule($0, action: $1) })
    }
    func start() {
        client.start(onTranscript: { [events] in events.transcript($0, final: $1) },
                     onError: { [events] in events.fail($0) })
    }
}

final class AssemblyAISocketFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var socketsValue: [AssemblyAITestSocket] = []
    private var requestsValue: [URLRequest] = []
    var sockets: [AssemblyAITestSocket] { lock.withLock { socketsValue } }
    var requests: [URLRequest] { lock.withLock { requestsValue } }
    func make(_ request: URLRequest) -> AssemblyAITestSocket {
        let socket = AssemblyAITestSocket()
        lock.withLock { socketsValue.append(socket); requestsValue.append(request) }
        return socket
    }
}

final class AssemblyAITestSocket: StreamingWebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var opener: (@Sendable () -> Void)?
    private var receiver: (@Sendable (Result<StreamingWebSocketMessage, Error>) -> Void)?
    private var completions: [@Sendable (Error?) -> Void] = []
    private var messages: [StreamingWebSocketMessage] = []
    private var cancelValue = 0
    var onSend: (@Sendable (StreamingWebSocketMessage) -> Void)?
    var binary: [Data] {
        lock.withLock { messages.compactMap { if case .binary(let data) = $0 { data } else { nil } } }
    }
    var controls: [String] {
        lock.withLock { messages.compactMap { if case .text(let text) = $0 { text } else { nil } } }
    }
    var cancels: Int { lock.withLock { cancelValue } }
    func resume(onOpen: @escaping @Sendable () -> Void) { lock.withLock { opener = onOpen } }
    func open() { lock.withLock { opener }?() }
    func begin() { emit(#"{"type":"Begin"}"#) }
    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        lock.withLock { messages.append(message); completions.append(completion) }
        onSend?(message)
    }
    func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {
        lock.withLock { receiver = completion }
    }
    func completeSend(_ error: Error? = nil) {
        let callback = lock.withLock { completions.removeFirst() }
        callback(error)
    }
    func emit(_ text: String) { receiveResult(.success(.text(text))) }
    func fail() { receiveResult(.failure(URLError(.networkConnectionLost))) }
    private func receiveResult(_ result: Result<StreamingWebSocketMessage, Error>) {
        let callback = lock.withLock { let value = receiver; receiver = nil; return value }
        callback?(result)
    }
    func cancel() { lock.withLock { cancelValue += 1 } }
}

final class AssemblyAITestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [(TimeInterval, @Sendable () -> Void)] = []
    func schedule(_ seconds: TimeInterval, action: @escaping @Sendable () -> Void) {
        lock.withLock { actions.append((seconds, action)) }
    }
    func fire(_ seconds: TimeInterval) {
        let selected = lock.withLock {
            let selected = actions.filter { $0.0 == seconds }
            actions.removeAll { $0.0 == seconds }
            return selected
        }
        selected.forEach { $0.1() }
    }
    func drain() -> [@Sendable () -> Void] { lock.withLock { let old = actions; actions = []; return old.map(\.1) } }
    /// Deadlines still armed for exactly this many seconds.
    func pending(_ seconds: TimeInterval) -> Int { lock.withLock { actions.filter { $0.0 == seconds }.count } }
}

final class AssemblyAITestEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var textValues: [String] = []
    private var finalValues: [Bool] = []
    private var failures: [Error] = []
    var texts: [String] { lock.withLock { textValues } }
    var finals: [Bool] { lock.withLock { finalValues } }
    var errors: [Error] { lock.withLock { failures } }
    func transcript(_ text: String, final: Bool) {
        lock.withLock { textValues.append(text); finalValues.append(final) }
    }
    func fail(_ error: Error) { lock.withLock { failures.append(error) } }
}
