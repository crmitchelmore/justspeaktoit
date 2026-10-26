import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

@MainActor
final class AssemblyAIControllerFixture {
    static let force = #"{"type":"ForceEndpoint"}"#
    static let terminate = #"{"type":"Terminate"}"#
    struct Timeout: Error {}
    struct Stopping {
        let task: Task<Void, Never>
        let done: XCTestExpectation
        let cleanedUp: XCTestExpectation
    }
    let transport = AssemblyAIControllerTransport()
    let clock = AssemblyAIControllerClock()
    let updates = AssemblyAIControllerUpdates()
    let delegate = AssemblyAIControllerDelegate()
    let client: AssemblyAILiveClient
    let controller: SharedClientLiveController
    var sockets: [AssemblyAIControllerSocket] { transport.sockets }

    init() throws {
        let transport = transport, clock = clock, updates = updates
        client = AssemblyAILiveClient(
            apiKey: "synthetic-unused-key", makeConnection: { transport.make($0) },
            schedule: { clock.schedule($0, action: $1) }
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "assemblyai-controller-parity.\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        let permissions = PermissionsManager()
        controller = SharedClientLiveController(
            permissionsManager: permissions, audioDeviceManager: AudioInputDeviceManager(appSettings: settings),
            secureStorage: SecureAppStorage(
                permissionsManager: permissions, appSettings: settings,
                keychainService: "com.justspeaktoit.tests.assemblyai-parity.\(UUID().uuidString)"
            ), appSettings: settings
        )
        controller.configure(language: nil, model: AssemblyAIModels.universal36ProStreamingID)
        let client = client
        controller.clientFactory = { client }
        controller.startCaptureAudio = {}
        controller.enqueueClientUpdate = { updates.enqueue($0) }
        controller.delegate = delegate
    }

    func start() async throws {
        try await controller.start()
        try XCTUnwrap(sockets.last).openAndBegin()
    }

    func stop() -> Stopping {
        let done = XCTestExpectation(description: "controller stop returned")
        let cleanedUp = XCTestExpectation(description: "owned stop task exited")
        let task = Task { @MainActor [controller] in
            defer { cleanedUp.fulfill() }
            await controller.stop()
            done.fulfill()
        }
        return Stopping(task: task, done: done, cleanedUp: cleanedUp)
    }
}

@MainActor
final class AssemblyAIControllerDelegate: LiveTranscriptionSessionDelegate {
    enum Event: Equatable { case boundary(String), partial(String) }
    var events: [Event] = []
    var partials: [String] = []
    var boundaries: [String] = []
    var results: [TranscriptionResult] = []
    var errors: [Error] = []
    func liveTranscriber(_ session: any LiveTranscriptionController, didUpdatePartial text: String) {
        partials.append(text); events.append(.partial(text))
    }
    func liveTranscriber(_ session: any LiveTranscriptionController, didDetectUtteranceBoundary text: String) {
        boundaries.append(text); events.append(.boundary(text))
    }
    func liveTranscriber(_ session: any LiveTranscriptionController, didFinishWith result: TranscriptionResult) {
        results.append(result)
    }
    func liveTranscriber(_ session: any LiveTranscriptionController, didFail error: Error) { errors.append(error) }
    func liveTranscriber(_ session: any LiveTranscriptionController, didUpdateWith update: LiveTranscriptionUpdate) {}
}

final class AssemblyAIControllerUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [@MainActor @Sendable () -> Void] = []
    func enqueue(_ update: @escaping @MainActor @Sendable () -> Void) { lock.withLock { pending.append(update) } }
    @MainActor func deliverAll() {
        let updates = lock.withLock { let updates = pending; pending.removeAll(); return updates }
        updates.forEach { $0() }
    }
}

final class AssemblyAIControllerTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AssemblyAIControllerSocket] = []
    var sockets: [AssemblyAIControllerSocket] { lock.withLock { values } }
    func make(_ request: URLRequest) -> AssemblyAIControllerSocket {
        let socket = AssemblyAIControllerSocket()
        lock.withLock { values.append(socket) }
        return socket
    }
}

final class AssemblyAIControllerSocket: StreamingWebSocketConnection, @unchecked Sendable {
    typealias Receiver = @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void
    private let lock = NSLock()
    private var opener: (@Sendable () -> Void)?
    private var receiver: Receiver?
    private var pending: [@Sendable (Error?) -> Void] = []
    private var messages: [StreamingWebSocketMessage] = []
    private var sendObserver: (@Sendable (StreamingWebSocketMessage) -> Void)?
    private var cancelCount = 0
    var binary: [Data] {
        lock.withLock { messages.compactMap { if case .binary(let data) = $0 { data } else { nil } } }
    }
    var controls: [String] {
        lock.withLock { messages.compactMap { if case .text(let text) = $0 { text } else { nil } } }
    }
    var cancels: Int { lock.withLock { cancelCount } }
    func resume(onOpen: @escaping @Sendable () -> Void) { lock.withLock { opener = onOpen } }
    func openAndBegin() {
        lock.withLock { opener }?()
        emit(#"{"type":"Begin"}"#)
    }
    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        let observer = lock.withLock {
            messages.append(message); pending.append(completion)
            return sendObserver
        }
        observer?(message)
    }
    func observeSends(_ observer: @escaping @Sendable (StreamingWebSocketMessage) -> Void) {
        lock.withLock { sendObserver = observer }
    }
    func receive(completion: @escaping Receiver) { lock.withLock { receiver = completion } }
    func takeReceiver() -> Receiver? {
        lock.withLock { let callback = receiver; receiver = nil; return callback }
    }
    func emit(_ text: String) { takeReceiver()?(.success(.text(text))) }
    func fail() { takeReceiver()?(.failure(URLError(.networkConnectionLost))) }
    func turn(_ order: Int, text: String, utterance: String? = nil, final: Bool = true) throws {
        emit(try Self.turn(order, text: text, utterance: utterance, final: final))
    }
    static func turn(_ order: Int, text: String, utterance: String? = nil, final: Bool = true) throws -> String {
        var fields: [String: Any] = [
            "type": "Turn", "turn_order": order, "turn_is_formatted": final, "end_of_turn": final, "transcript": text
        ]
        fields["utterance"] = utterance
        return try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: fields), encoding: .utf8))
    }
    func completeSend(_ error: Error? = nil) throws {
        let callback = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        try XCTUnwrap(callback, "Expected an admitted send completion")(error)
    }
    func cancel() { lock.withLock { cancelCount += 1 } }
}

final class AssemblyAIControllerClock: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [(TimeInterval, @Sendable () -> Void)] = []
    private var observer: (@Sendable (TimeInterval) -> Void)?
    func observeSchedule(_ observer: @escaping @Sendable (TimeInterval) -> Void) {
        lock.withLock { self.observer = observer }
    }
    func schedule(_ seconds: TimeInterval, action: @escaping @Sendable () -> Void) {
        let observer = lock.withLock { actions.append((seconds, action)); return self.observer }
        observer?(seconds)
    }
    func fire(_ seconds: TimeInterval) -> Int {
        let selected = lock.withLock {
            let selected = actions.filter { $0.0 == seconds }
            actions.removeAll { $0.0 == seconds }
            return selected
        }
        selected.forEach { $0.1() }
        return selected.count
    }
    func takeActions() -> [@Sendable () -> Void] {
        lock.withLock { let old = actions; actions.removeAll(); return old.map(\.1) }
    }
}
