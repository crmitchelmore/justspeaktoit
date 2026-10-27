import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

@MainActor
final class GladiaControllerBoundaryFixture {
    struct Stopping {
        let task: Task<Void, Never>
        let done: XCTestExpectation
        let cleanedUp: XCTestExpectation
    }
    let transport = AssemblyAIControllerTransport()
    let clock = AssemblyAIControllerClock()
    let updates = GladiaControllerBoundaryUpdates()
    let delegate = GladiaControllerBoundaryDelegate()
    let client: GladiaLiveClient
    let controller: SharedClientLiveController
    private let defaults: UserDefaults
    private let suite = "gladia-controller-boundaries.\(UUID().uuidString)"
    var socket: AssemblyAIControllerSocket? { transport.sockets.last }

    init() throws {
        let transport = transport, clock = clock, updates = updates
        client = GladiaLiveClient(
            apiKey: "synthetic-unused-key",
            initiateSession: { _, completion in
                let body = Data(#"{"url":"wss://api.gladia.io/v2/live?token=synthetic-unused-token"}"#.utf8)
                completion(.success((statusCode: 201, body: body)))
                return GladiaControllerSessionRequest()
            }, makeConnection: { transport.make($0) }, schedule: { clock.schedule($0, action: $1) }
        )
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        let permissions = PermissionsManager()
        controller = SharedClientLiveController(
            permissionsManager: permissions, audioDeviceManager: AudioInputDeviceManager(appSettings: settings),
            secureStorage: SecureAppStorage(
                permissionsManager: permissions, appSettings: settings,
                keychainService: "com.justspeaktoit.tests.gladia-boundaries.\(UUID().uuidString)"
            ), appSettings: settings
        )
        controller.configure(language: nil, model: "gladia/solaria-1-streaming")
        let client = client
        controller.clientFactory = { client }
        controller.startCaptureAudio = {}
        controller.enqueueClientUpdate = { updates.enqueue($0) }
        controller.delegate = delegate
    }

    func start() async throws {
        try await controller.start()
        let socket = try XCTUnwrap(socket)
        // The generic held socket's Begin is ignored by the Gladia parser.
        socket.openAndBegin()
        client.sendAudio(Data(repeating: 1, count: 3_200))
        try socket.completeSend()
    }

    func stop() -> Stopping {
        let done = XCTestExpectation(description: "Gladia controller stop returned")
        let cleanedUp = XCTestExpectation(description: "owned Gladia stop task exited")
        let task = Task { @MainActor [controller] in
            defer { cleanedUp.fulfill() }
            await controller.stop()
            done.fulfill()
        }
        return Stopping(task: task, done: done, cleanedUp: cleanedUp)
    }

    func cleanup() {
        client.cancel()
        client.onUtteranceBoundary = nil
        delegate.onUpdate = nil
        delegate.onPartial = nil
        defaults.removePersistentDomain(forName: suite)
    }

    static func frame(_ text: String, id: String, final: Bool = true, confidence: Double = 0.8) throws -> String {
        let object: [String: Any] = [
            "type": "transcript",
            "data": ["id": id, "is_final": final, "utterance": ["text": text, "confidence": confidence]]
        ]
        return try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8))
    }
}

private final class GladiaControllerSessionRequest: GladiaLiveSessionRequest {
    func cancel() {}
}

@MainActor
final class GladiaControllerBoundaryDelegate: LiveTranscriptionSessionDelegate {
    enum Event: Equatable { case partial(String), boundary(String), error }
    var events: [Event] = []
    var updates: [LiveTranscriptionUpdate] = []
    var results: [TranscriptionResult] = []
    var errors: [Error] = []
    var onUpdate: (() -> Void)?
    var onPartial: (() -> Void)?

    func liveTranscriber(_ session: any LiveTranscriptionController, didUpdateWith update: LiveTranscriptionUpdate) {
        updates.append(update); onUpdate?()
    }
    func liveTranscriber(_ session: any LiveTranscriptionController, didUpdatePartial text: String) {
        events.append(.partial(text)); onPartial?()
    }
    func liveTranscriber(_ session: any LiveTranscriptionController, didDetectUtteranceBoundary text: String) {
        events.append(.boundary(text))
    }
    func liveTranscriber(_ session: any LiveTranscriptionController, didFinishWith result: TranscriptionResult) {
        results.append(result)
    }
    func liveTranscriber(_ session: any LiveTranscriptionController, didFail error: Error) {
        errors.append(error); events.append(.error)
    }
}

final class GladiaControllerBoundaryUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [@MainActor @Sendable () -> Void] = []
    private var nextHold: (entered: XCTestExpectation, release: DispatchSemaphore)?

    func holdNextEnqueue(entered: XCTestExpectation, release: DispatchSemaphore) {
        lock.withLock { nextHold = (entered, release) }
    }

    func enqueue(_ update: @escaping @MainActor @Sendable () -> Void) {
        let hold = lock.withLock {
            pending.append(update)
            let hold = nextHold
            nextHold = nil
            return hold
        }
        if let hold {
            hold.entered.fulfill()
            XCTAssertEqual(hold.release.wait(timeout: .now() + 2), .success)
        }
    }

    @MainActor func deliverAll(reversed: Bool = false) {
        var work = lock.withLock {
            let work = pending
            pending.removeAll()
            return work
        }
        if reversed { work.reverse() }
        work.forEach { $0() }
    }
}
