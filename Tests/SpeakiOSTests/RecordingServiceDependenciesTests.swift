#if os(iOS) && DEBUG && targetEnvironment(simulator)
import AVFoundation
import Combine
import SpeakCore
import UIKit
import XCTest

@testable import SpeakiOSLib

@MainActor
final class RecordingServiceDependenciesTests: XCTestCase {
    func testInjectedSettingsAndActivity_OwnStartAndCompletion() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        harness.settings.hardwareTriggerDestination = .historyOnly
        harness.settings.autoPostProcess = true
        harness.defaults.set("Isolated transcript", forKey: "simulatorValidationTranscript")
        let service = harness.makeService()

        XCTAssertEqual(service.resolvedStopDestination(), .historyOnly)
        harness.settings.autoPostProcess = false
        try await service.startRecording(requiresLiveActivity: false, trigger: .shortcut)
        XCTAssertEqual(service.automaticStopDestination, .historyOnly)
        XCTAssertEqual(harness.activityStarts, [.arming])
        let result = await service.stopRecording(destination: .historyOnly)

        XCTAssertEqual(result.text, "Isolated transcript")
        XCTAssertEqual(harness.history.items.map(\.transcription), ["Isolated transcript"])
        XCTAssertEqual(harness.dictations.map(\.0), [.shortcut])
        XCTAssertEqual(harness.dictations.map(\.1), ["Isolated transcript"])
        XCTAssertEqual(harness.completions, [.ready])
        XCTAssertTrue(harness.activityUpdates.contains(.finalising))
        XCTAssertTrue(harness.pasteboard.writes.isEmpty)
        XCTAssertTrue(harness.deliveredRecordings.isEmpty, "The simulator stub has no safety recording")
    }

    func testInjectedSettings_ControlAutomaticPolishAndItsModel() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        harness.defaults.set("Raw transcript", forKey: "simulatorValidationTranscript")
        harness.settings.autoPostProcess = true
        harness.settings.postProcessingModel = "openai/gpt-4o-mini"
        let service = harness.makeService()
        try await service.startRecording(requiresLiveActivity: false)
        _ = await service.stopRecording()
        let polished = expectation(description: "Automatic polish completed")
        let observation = service.$isPostProcessing.filter { !$0 }.prefix(1).sink { _ in polished.fulfill() }
        defer { observation.cancel() }
        guard await XCTWaiter.fulfillment(of: [polished], timeout: 2) == .completed else {
            return XCTFail("Automatic polish did not complete before the timeout")
        }

        XCTAssertEqual(harness.polishRequests.map(\.0), ["Raw transcript"])
        XCTAssertEqual(harness.polishRequests.map(\.1), ["openai/gpt-4o-mini"])
        XCTAssertEqual(harness.history.items.first?.postProcessedTranscription, "Polished transcript")
        XCTAssertEqual(harness.pasteboard.writes, ["Raw transcript"])
        harness.settings.autoPostProcess = false
        try await service.startRecording(requiresLiveActivity: false)
        _ = await service.stopRecording()
        XCTAssertEqual(harness.polishRequests.count, 1)
    }

    func testInjectedApplicationState_RequiresActivityOnlyInBackground() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        harness.defaults.set("Transcript", forKey: "simulatorValidationTranscript")
        harness.applicationState = .background
        harness.activityStartsSuccessfully = false
        let service = harness.makeService()

        do {
            try await service.startRecording(requiresLiveActivity: true)
            XCTFail("Background capture requires a Live Activity")
        } catch {
            guard case .liveActivityUnavailable = error as? iOSTranscriptionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(service.isActive)
        harness.applicationState = .active
        try await service.startRecording(requiresLiveActivity: true)
        XCTAssertTrue(service.isRunning)
        XCTAssertEqual(harness.activityStarts, [.arming, .arming])
        service.cancelRecording()
    }

    func testInjectedKeyboardStore_PublishesLatePickupAndReceipt() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        harness.defaults.set("Keyboard transcript", forKey: "simulatorValidationTranscript")
        let service = harness.makeService()
        try await service.startRecording(requiresLiveActivity: false)
        _ = await service.stopRecording(destination: .auto)

        XCTAssertEqual(harness.keyboard.pendingOffer()?.text, "Keyboard transcript")
        XCTAssertEqual(harness.keyboard.pendingOffer()?.mode, .latePickup)
        XCTAssertEqual(harness.pasteboard.writes, ["Keyboard transcript"])
        XCTAssertNotNil(service.lastCaptureReceipt)
    }

    func testSuccessfulDelivery_MarksOnlyTheInjectedSessionsSafetyRecording() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        let session = DependencySession()
        let service = harness.makeService()
        service.makeSession = { session }
        try await service.startRecording(requiresLiveActivity: false)
        _ = await service.stopRecording(destination: .historyOnly)

        XCTAssertEqual(harness.deliveredRecordings, [try XCTUnwrap(session.safetyRecordingID)])
        XCTAssertEqual(harness.history.items.map(\.transcription), ["Safety transcript"])
        XCTAssertTrue(harness.pasteboard.writes.isEmpty)
    }

    func testCancellationDuringInjectedKeyLoad_PreventsSessionAllocation() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        let keys = DependencyKeyLoadGate(entered: expectation(description: "Key loading entered"))
        var allocations = 0
        let service = harness.makeService(ensureKeysLoaded: { await keys.wait() })
        service.makeSession = {
            allocations += 1
            throw CancellationError()
        }
        let completed = expectation(description: "Cancelled startup completed")
        var startError: Error?
        let start = Task {
            do {
                try await service.startRecording(requiresLiveActivity: false)
            } catch {
                startError = error
            }
            completed.fulfill()
        }
        defer {
            start.cancel()
            service.cancelRecording()
            keys.release()
        }
        guard await XCTWaiter.fulfillment(of: [keys.entered], timeout: 2) == .completed else {
            return XCTFail("Startup did not enter key loading before the timeout")
        }
        service.cancelRecording()
        keys.release()
        guard await XCTWaiter.fulfillment(of: [completed], timeout: 2) == .completed else {
            return XCTFail("Cancelled startup did not complete before the timeout")
        }
        XCTAssertTrue(startError is CancellationError, "Cancelled startup must throw CancellationError")
        XCTAssertEqual(allocations, 0)
        XCTAssertTrue(harness.activityStarts.isEmpty)
        XCTAssertTrue(harness.dictations.isEmpty)
        XCTAssertTrue(harness.deliveredRecordings.isEmpty)
    }

}

@MainActor
final class DependencyKeyLoadGate {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    init(entered: XCTestExpectation) {
        self.entered = entered
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            // Timeout cleanup can run before startup reaches this suspension point.
            if self.isReleased {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
            self.entered.fulfill()
        }
    }

    func release() {
        self.isReleased = true
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume()
    }
}

@MainActor
final class DependencyHarness {
    let suite = "RecordingServiceDependencies.\(UUID())"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults: UserDefaults
    let settings: AppSettings
    let history: iOSHistoryManager
    let keyboard: KeyboardDeliveryStore
    let pasteboard = DependencyPasteboard()
    var applicationState = UIApplication.State.active
    var activityStartsSuccessfully = true
    var activityStarts: [TranscriptionActivityAttributes.TranscriptionStatus] = []
    var activityUpdates: [TranscriptionActivityAttributes.TranscriptionStatus] = []
    var activitySnippets: [String] = []
    var resultPreviews: [String] = []
    var completions: [TranscriptionCompletionOutcome] = []
    var dictations: [(CaptureTrigger, String)] = []
    var deliveredRecordings: [UUID] = []
    var polishRequests: [(String, String)] = []
    var focus: FocusCaptureOverride = .none
    var focusReads = 0
    var focusGate: DependencyKeyLoadGate?
    private var service: TranscriptionRecordingService?

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        settings = AppSettings(defaults: defaults, loadsSecureStorage: false)
        settings.transcriptionMode = .streaming
        settings.selectedModel = AppleLocalModels.legacySpeechModelID
        keyboard = KeyboardDeliveryStore(defaults: defaults, announceStatusChange: {})
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        history = iOSHistoryManager(
            fileURL: directory.appendingPathComponent("history.json"), syncEnabled: false, userDefaults: defaults
        )
    }

    func makeService(
        ensureKeysLoaded: (@MainActor () async -> Void)? = nil,
        networkSnapshot: @escaping CaptureNetworkPathMonitor.SnapshotProvider = { .unknown },
        capability: @escaping @MainActor (String) -> AppleLocalRecognitionCapability = { _ in .available }
    ) -> TranscriptionRecordingService {
        let dependencies = RecordingServiceDependencies(
            settings: self.settings,
            activity: RecordingServiceActivity(
                start: { [unowned self] _, status in
                    self.activityStarts.append(status)
                    return self.activityStartsSuccessfully
                },
                update: { [unowned self] status, snippet, _, _ in
                    self.activityUpdates.append(status)
                    self.activitySnippets.append(snippet)
                },
                endActivity: {},
                reportError: { message in XCTFail("Unexpected activity error: \(message)") },
                complete: { [unowned self] _, _, _, outcome, preview, _, _ in
                    self.completions.append(outcome)
                    self.resultPreviews.append(preview)
                }
            ),
            keyboardDelivery: self.keyboard,
            recordDictation: { [unowned self] in self.dictations.append(($0, $1)) },
            markDelivered: { [unowned self] in self.deliveredRecordings.append($0) },
            applicationState: { [unowned self] in self.applicationState },
            focusOverride: { [unowned self] _ in
                self.focusReads += 1
                if let gate = self.focusGate { await gate.wait() }
                return self.focus
            }
        )
        let service = TranscriptionRecordingService(
            sharedState: SharedTranscriptionState(defaults: self.defaults),
            historyManager: self.history,
            polishClipboard: PolishClipboard(pasteboard: self.pasteboard),
            hasPolishingKey: { true },
            polish: { [unowned self] text, model, _ in
                self.polishRequests.append((text, model))
                return "Polished transcript"
            },
            foregroundOwnership: ForegroundRecordingOwnership(),
            ensureKeysLoaded: ensureKeysLoaded,
            networkSnapshot: networkSnapshot,
            localRecognitionCapability: capability,
            dependencies: dependencies
        )
        self.service = service
        return service
    }

    func cleanUp() {
        self.service?.cancelRecording()
        self.defaults.removePersistentDomain(forName: self.suite)
        try? FileManager.default.removeItem(at: self.directory)
    }
}

@MainActor
final class DependencySession: IOSRecordingSession {
    let isBatch = false
    let stopCompletionTimeout: TimeInterval = 1
    let resolution = IOSTranscriptionSession.Resolution(modelID: "test", backend: .apple, route: nil)
    let partialText = "Safety transcript"
    let confidence: Double? = nil
    var onPartialResult: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?
    var onFirstInputBuffer: (() -> Void)?
    var onStartupObservation: ((StartupObservation) -> Void)?
    var onRecordingWarning: ((String) -> Void)?
    let inputLevelSample = CaptureInputLevelSample(levelDBFS: -160, sequence: 0)
    let safetyRecordingID: UUID? = UUID()
    let recordingLossSummary: String? = nil

    func resetInputLevel() {}
    func discardTemporaryRecording() -> Bool { false }
    func start() async throws {}
    func start(preRollBuffers: [AVAudioPCMBuffer], analyzerFallbackAllowed: Bool) async throws {}
    var finish: (() async throws -> TranscriptionResult)?
    func stop() async throws -> TranscriptionResult {
        if let finish { return try await finish() }
        return TranscriptionResult(
            text: self.partialText, segments: [], confidence: nil, duration: 1,
            modelIdentifier: "test", cost: nil, rawPayload: nil, debugInfo: nil
        )
    }
    func cancel() {}
    func awaitCancellationSettled() async {}
}

@MainActor
final class DependencyPasteboard: PolishPasteboard {
    var writes: [String] = []
    func write(_ text: String) { self.writes.append(text) }
}
#endif
