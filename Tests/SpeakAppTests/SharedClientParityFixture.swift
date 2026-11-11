import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

/// Drives `SharedClientLiveController` with a real SpeakCore client over a
/// scripted socket, so a provider's former bespoke-controller behaviour can be
/// proven on the shared Mac path. Capture is stubbed; PCM goes straight to the
/// client, as the processor would hand it over.
@MainActor
final class SharedClientParityFixture {
    let socket = SharedClientParitySocket()
    let clock = AssemblyAIControllerClock()
    let updates = AssemblyAIControllerUpdates()
    let delegate = AssemblyAIControllerDelegate()
    let settings: AppSettings
    let controller: SharedClientLiveController
    private(set) var client: StreamingTranscriptionClient?

    struct Context {
        let route: LiveTranscriptionRoute
        let language: String?
        let options: LiveClientOptions
        let socket: SharedClientParitySocket
        let clock: AssemblyAIControllerClock
    }

    init(
        model: String, language: String? = nil, stopGrace: TimeInterval = 0,
        makeClient: @escaping (Context) -> StreamingTranscriptionClient
    ) throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "shared-client-parity.\(UUID().uuidString)"))
        settings = AppSettings(defaults: defaults)
        settings.liveStopGracePeriod = stopGrace
        let permissions = PermissionsManager()
        controller = SharedClientLiveController(
            permissionsManager: permissions, audioDeviceManager: AudioInputDeviceManager(appSettings: settings),
            secureStorage: SecureAppStorage(
                permissionsManager: permissions, appSettings: settings,
                keychainService: "com.justspeaktoit.tests.shared-parity.\(UUID().uuidString)"
            ), appSettings: settings
        )
        controller.configure(language: language, model: model)
        let socket = socket, clock = clock, updates = updates
        controller.configuredClientFactory = { [weak self] route, language, options in
            let client = makeClient(Context(
                route: route, language: language, options: options, socket: socket, clock: clock
            ))
            self?.client = client
            return client
        }
        controller.startCaptureAudio = {}
        controller.enqueueClientUpdate = { updates.enqueue($0) }
        controller.delegate = delegate
    }

    func start() async throws {
        try await controller.start()
        socket.open()
    }

    func send(_ audio: Data) { client?.sendAudio(audio) }

    /// Starts the controller's stop and returns once `isReady` holds, so a test
    /// can script the provider's finalisation while the stop is in flight.
    func beginStop(until isReady: @escaping @Sendable () -> Bool) async -> Task<Void, Never> {
        let task = Task { @MainActor [controller] in await controller.stop() }
        var ready = isReady()
        for _ in 0..<300 where !ready {
            try? await Task.sleep(for: .milliseconds(10))
            ready = isReady()
        }
        XCTAssertTrue(ready, "The stop never reached the scripted finalisation point")
        return task
    }
}

final class SharedClientParitySocket: StreamingWebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var opener: (@Sendable () -> Void)?
    private var receiver: (@Sendable (Result<StreamingWebSocketMessage, Error>) -> Void)?
    private var pending: [@Sendable (Error?) -> Void] = []
    private var messages: [StreamingWebSocketMessage] = []
    private var cancelCount = 0
    var binary: [Data] {
        lock.withLock { messages.compactMap { if case .binary(let data) = $0 { data } else { nil } } }
    }
    var text: [String] {
        lock.withLock { messages.compactMap { if case .text(let text) = $0 { text } else { nil } } }
    }
    var pendingSends: Int { lock.withLock { pending.count } }
    var cancels: Int { lock.withLock { cancelCount } }
    var isReceiving: Bool { lock.withLock { receiver != nil } }

    func resume(onOpen: @escaping @Sendable () -> Void) { lock.withLock { opener = onOpen } }
    func open() { lock.withLock { opener }?() }
    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        lock.withLock { messages.append(message); pending.append(completion) }
    }
    func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {
        lock.withLock { receiver = completion }
    }
    /// Completes every admitted send, including ones each completion admits.
    func completeSends(error: Error? = nil) {
        while let completion = lock.withLock({ pending.isEmpty ? nil : pending.removeFirst() }) {
            completion(error)
        }
    }
    func emit(_ text: String) { deliver(.success(.text(text))) }
    func fail(_ error: Error = URLError(.networkConnectionLost)) { deliver(.failure(error)) }
    func cancel() { lock.withLock { cancelCount += 1 } }
    private func deliver(_ result: Result<StreamingWebSocketMessage, Error>) {
        let callback = lock.withLock { let callback = receiver; receiver = nil; return callback }
        callback?(result)
    }
}
