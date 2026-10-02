#if os(iOS)
import AVFoundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

/// A recording session with no microphone, provider or persistence.
///
/// It conforms to the one lifecycle boundary both owners route on
/// (`IOSRecordingSession`), so the ownership tests exercise the same seam the
/// headless service and the interruption tests use.
@MainActor
final class ForegroundTestSession: IOSRecordingSession {
    var isBatch = false
    /// Apple leaves the startup backend unresolved, which is what this double
    /// reports for the startup diagnostics boundary.
    let resolution = IOSTranscriptionSession.Resolution(modelID: "test", backend: .apple, route: nil)
    var partialText = ""
    var confidence: Double? = 0.8
    var onPartialResult: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?
    var onFirstInputBuffer: (() -> Void)?
    var onStartupObservation: ((StartupObservation) -> Void)?
    var onRecordingWarning: ((String) -> Void)?
    /// This double persists nothing, so it never reports a loss (#950).
    var recordingLossSummary: String? { nil }
    var inputLevelSample = CaptureInputLevelSample(levelDBFS: -160, sequence: 0)
    let safetyRecordingID: UUID? = nil
    var startOperation: @MainActor () async throws -> Void = {}
    var stopOperation: @MainActor () async throws -> TranscriptionResult = {
        ForegroundTestSession.result("final words")
    }
    var cancellationSettlement: @MainActor () async -> Void = {}
    var cancellations = 0
    var starts = 0
    var stops = 0

    func start() async throws {
        try await start(preRollBuffers: [], analyzerFallbackAllowed: true)
    }

    func start(preRollBuffers: [AVAudioPCMBuffer], analyzerFallbackAllowed: Bool) async throws {
        starts += 1
        try await startOperation()
    }

    func stop() async throws -> TranscriptionResult {
        stops += 1
        return try await stopOperation()
    }

    func awaitCancellationSettled() async { await cancellationSettlement() }
    func cancel() { cancellations += 1 }
    func resetInputLevel() {}
    @discardableResult
    func discardTemporaryRecording() -> Bool { true }

    static func result(_ text: String) -> TranscriptionResult {
        TranscriptionResult(text: text, segments: [], confidence: nil, duration: 1,
                            modelIdentifier: "test", cost: nil, rawPayload: nil, debugInfo: nil)
    }
}

/// Deliberately ignores cancellation until released, modelling slow provider unwind.
@MainActor
final class ForegroundTestSuspension {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ name: String) { entered = XCTestExpectation(description: name) }

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.fulfill()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

/// History on a throwaway file, so a test can read exactly what a run recorded
/// without touching the shared store — and assert that a cancelled or refused
/// run recorded nothing at all.
@MainActor
func makeForegroundTestHistory() -> iOSHistoryManager {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("foreground-ownership-\(UUID()).json")
    let defaults = UserDefaults(suiteName: "ForegroundOwnership.\(UUID())") ?? .standard
    return iOSHistoryManager(fileURL: fileURL, syncEnabled: false, userDefaults: defaults)
}

/// A coordinator whose microphone, credentials, Live Activity and History are
/// all synthetic. `makeSession` is the existing injection seam (#936) rather
/// than a second one added for these tests.
@MainActor
func makeForegroundTestCoordinator(
    sharedState: SharedTranscriptionState = SharedTranscriptionState(defaults: nil),
    historyManager: iOSHistoryManager,
    ownership: ForegroundRecordingOwnership,
    ensureKeysLoaded: @escaping @MainActor () async -> Void = {},
    headlessState: @escaping @MainActor () -> RecordingServiceState = { .idle },
    session: @escaping @MainActor () throws -> any IOSRecordingSession
) -> TranscriberCoordinator {
    let coordinator = TranscriberCoordinator(
        sharedState: sharedState,
        historyManager: historyManager,
        ownership: ownership,
        ensureKeysLoaded: ensureKeysLoaded,
        liveActivitiesEnabled: { false },
        headlessState: headlessState,
        networkSnapshot: { .unknown },
        localRecognitionCapability: { _ in .available }
    )
    coordinator.makeSession = { try session() }
    return coordinator
}
#endif
