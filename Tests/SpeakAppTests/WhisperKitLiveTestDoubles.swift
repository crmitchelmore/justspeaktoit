import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

// MARK: - Test doubles

/// Stands in for WhisperKit behind `WhisperKitLiveStreaming`: the test drives
/// stream events, stream termination and the stop-time tail decode directly.
@MainActor
final class MockWhisperKitStream: WhisperKitLiveStreaming {
    var onEvent: WhisperKitStreamEventHandler?
    /// Thrown from `startStream()` before any audio, like a capture failure.
    var startError: (any Error)?
    var tailText = ""
    var tailError: (any Error)?
    var tailGate: TestGate?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var tailRequests: [Float] = []
    private var streamContinuation: CheckedContinuation<Void, any Error>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    func startStream() async throws {
        startCount += 1
        let waiters = startedWaiters
        startedWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
        if let startError {
            throw startError
        }
        try await withCheckedThrowingContinuation { continuation in
            streamContinuation = continuation
        }
    }

    func stopStream() async {
        stopCount += 1
        endStream()
    }

    func decodeTail(after confirmedEndSeconds: Float) async throws -> String {
        tailRequests.append(confirmedEndSeconds)
        if let tailGate {
            await tailGate.wait()
        }
        if let tailError {
            throw tailError
        }
        return tailText
    }

    /// Suspends until `startStream()` has been entered more than
    /// `previousCount` times, so a reused stream waits for its *new* run.
    func waitUntilStarted(after previousCount: Int) async {
        guard startCount <= previousCount else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func emit(_ event: WhisperKitStreamEvent) {
        onEvent?(event)
    }

    /// Ends `startStream()` the way WhisperKit's loop does after an internal
    /// decode error: by returning normally while still "recording".
    func endStream() {
        streamContinuation?.resume()
        streamContinuation = nil
    }

    func fail(_ error: any Error) {
        streamContinuation?.resume(throwing: error)
        streamContinuation = nil
    }
}

@MainActor
final class WhisperKitStreamBox {
    private var stream: MockWhisperKitStream

    init(_ stream: MockWhisperKitStream) {
        self.stream = stream
    }

    func set(_ stream: MockWhisperKitStream) {
        self.stream = stream
    }

    func take() -> MockWhisperKitStream {
        stream
    }
}

// MARK: - Harness

struct WhisperKitLiveHarness {
    let controller: WhisperKitLiveController
    let delegate: RecordingDelegate

    @MainActor
    static func make(
        stream: MockWhisperKitStream,
        startupTimeout: Duration = .seconds(5),
        finalisationTimeout: Duration = .seconds(5)
    ) -> WhisperKitLiveHarness {
        make(startupTimeout: startupTimeout, finalisationTimeout: finalisationTimeout) { _, onEvent in
            stream.onEvent = onEvent
            return stream
        }
    }

    @MainActor
    static func make(
        startupTimeout: Duration = .seconds(5),
        finalisationTimeout: Duration = .seconds(5),
        provider: @escaping WhisperKitLiveController.StreamProvider
    ) -> WhisperKitLiveHarness {
        let defaults = UserDefaults(suiteName: "whisperkit-live-tests-\(UUID().uuidString)") ?? .standard
        let settings = AppSettings(defaults: defaults)
        let permissions = PermissionsManager(statusProvider: { _ in .granted })
        let audioDevices = AudioInputDeviceManager(appSettings: settings)
        let delegate = RecordingDelegate()
        let controller = WhisperKitLiveController(
            permissionsManager: permissions,
            audioDeviceManager: audioDevices,
            modelManager: LocalModelManager.shared,
            streamProvider: provider,
            startupTimeout: startupTimeout,
            finalisationTimeout: finalisationTimeout
        )
        controller.delegate = delegate
        return WhisperKitLiveHarness(controller: controller, delegate: delegate)
    }

    /// Starts the controller and delivers the first audio so it reaches
    /// `.running`.
    @MainActor
    func startRunning(with stream: MockWhisperKitStream) async throws {
        let previousStarts = stream.startCount
        let task = Task { try await controller.start() }
        await stream.waitUntilStarted(after: previousStarts)
        stream.emit(.audioArrived)
        try await task.value
    }
}

func whisperKitSegment(_ start: Float, _ end: Float, _ text: String) -> WhisperKitSegment {
    WhisperKitSegment(start: start, end: end, text: text)
}

func drainWhisperKitAsyncWork() async {
    for _ in 0..<20 {
        await Task.yield()
    }
}

@MainActor
func waitUntilWhisperKit(
    _ condition: @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    for _ in 0..<200 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Condition not met in time", file: file, line: line)
}
