#if os(iOS) && DEBUG && targetEnvironment(simulator)
import AVFoundation
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
        for _ in 0..<1_000 where service.isPostProcessing { await Task.yield() }

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
        var resumeKeys: CheckedContinuation<Void, Never>?
        var allocations = 0
        let service = harness.makeService(ensureKeysLoaded: {
            await withCheckedContinuation { resumeKeys = $0 }
        })
        service.makeSession = {
            allocations += 1
            throw CancellationError()
        }
        let start = Task { try await service.startRecording(requiresLiveActivity: false) }
        for _ in 0..<1_000 where resumeKeys == nil { await Task.yield() }
        XCTAssertNotNil(resumeKeys)
        service.cancelRecording()
        resumeKeys?.resume()
        do {
            try await start.value
            XCTFail("Cancelled startup must not complete")
        } catch is CancellationError {
            // Expected: the retired run cannot acquire a microphone.
        }
        XCTAssertEqual(allocations, 0)
        XCTAssertTrue(harness.activityStarts.isEmpty)
        XCTAssertTrue(harness.dictations.isEmpty)
        XCTAssertTrue(harness.deliveredRecordings.isEmpty)
    }
}

@MainActor
private final class DependencyHarness {
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
    var completions: [TranscriptionCompletionOutcome] = []
    var dictations: [(CaptureTrigger, String)] = []
    var deliveredRecordings: [UUID] = []
    var polishRequests: [(String, String)] = []
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

    func makeService(ensureKeysLoaded: (@MainActor () async -> Void)? = nil) -> TranscriptionRecordingService {
        let dependencies = RecordingServiceDependencies(
            settings: self.settings,
            activity: RecordingServiceActivity(
                start: { [unowned self] _, status in
                    self.activityStarts.append(status)
                    return self.activityStartsSuccessfully
                },
                update: { [unowned self] status, _, _, _ in self.activityUpdates.append(status) },
                endActivity: {},
                reportError: { message in XCTFail("Unexpected activity error: \(message)") },
                complete: { [unowned self] _, _, _, outcome, _, _, _ in self.completions.append(outcome) }
            ),
            keyboardDelivery: self.keyboard,
            recordDictation: { [unowned self] in self.dictations.append(($0, $1)) },
            markDelivered: { [unowned self] in self.deliveredRecordings.append($0) },
            applicationState: { [unowned self] in self.applicationState }
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
private final class DependencySession: IOSRecordingSession {
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
    func stop() async throws -> TranscriptionResult {
        TranscriptionResult(
            text: self.partialText, segments: [], confidence: nil, duration: 1,
            modelIdentifier: "test", cost: nil, rawPayload: nil, debugInfo: nil
        )
    }
    func cancel() {}
    func awaitCancellationSettled() async {}
}

@MainActor
private final class DependencyPasteboard: PolishPasteboard {
    var writes: [String] = []
    func write(_ text: String) { self.writes.append(text) }
}
#endif
