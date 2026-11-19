#if os(iOS) && DEBUG && targetEnvironment(simulator)
import AVFoundation
import Combine
import SpeakCore
import UIKit
import XCTest

@testable import SpeakiOSLib

// The recording-service harness shared by the dependency, focus, watchdog and
// diagnostic tests: injected settings, activity, keyboard store and sessions.

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
    var notifications: [TranscriptReadyNotificationInput] = []
    var expectsActivityError = false
    var activityErrors: [String] = []
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

    private func makeDependencies(activity: RecordingServiceActivity?) -> RecordingServiceDependencies {
        RecordingServiceDependencies(
            settings: self.settings,
            activity: activity ?? RecordingServiceActivity(
                start: { [unowned self] _, status in
                    self.activityStarts.append(status)
                    return self.activityStartsSuccessfully
                },
                update: { [unowned self] status, snippet, _, _ in
                    self.activityUpdates.append(status)
                    self.activitySnippets.append(snippet)
                },
                endActivity: {},
                reportError: { [unowned self] message in
                    self.activityErrors.append(message)
                    if !self.expectsActivityError { XCTFail("Unexpected activity error: \(message)") }
                },
                complete: { [unowned self] _, _, _, outcome, preview, _, _ in
                    self.completions.append(outcome)
                    self.resultPreviews.append(preview)
                }
            ),
            keyboardDelivery: self.keyboard,
            recordDictation: { [unowned self] in self.dictations.append(($0, $1)) },
            markDelivered: { [unowned self] in self.deliveredRecordings.append($0) },
            applicationState: { [unowned self] in self.applicationState },
            notifyTranscriptReady: { [unowned self] input in
                if let identifier = input.historyID {
                    XCTAssertTrue(self.history.items.contains { $0.id == identifier })
                }
                self.notifications.append(input)
            },
            focusOverride: { [unowned self] _ in
                self.focusReads += 1
                if let gate = self.focusGate { await gate.wait() }
                return self.focus
            }
        )
    }

    func makeService(
        ensureKeysLoaded: (@MainActor () async -> Void)? = nil,
        networkSnapshot: @escaping CaptureNetworkPathMonitor.SnapshotProvider = { .unknown },
        capability: @escaping @MainActor (String) -> AppleLocalRecognitionCapability = { _ in .available },
        activity: RecordingServiceActivity? = nil,
        completion: TranscriptionRecordingService.ActivityCompletion? = nil,
        foregroundOwnership: ForegroundRecordingOwnership? = nil
    ) -> TranscriptionRecordingService {
        let dependencies = self.makeDependencies(activity: activity)
        let service = TranscriptionRecordingService(
            sharedState: SharedTranscriptionState(defaults: self.defaults),
            historyManager: self.history,
            polishClipboard: PolishClipboard(pasteboard: self.pasteboard),
            hasPolishingKey: { true },
            polish: { [unowned self] text, model, _ in
                self.polishRequests.append((text, model))
                return "Polished transcript"
            },
            completeActivity: completion,
            foregroundOwnership: foregroundOwnership ?? ForegroundRecordingOwnership(),
            ensureKeysLoaded: ensureKeysLoaded,
            networkSnapshot: networkSnapshot,
            localRecognitionCapability: capability,
            dependencies: dependencies, outcomeJournalDefaults: { [unowned self] in self.defaults }
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
    var partialText = "Safety transcript"
    var stopError: Error?
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
        if let stopError { throw stopError }
        if let finish { return try await finish() }
        return TranscriptionResult(
            text: self.partialText, segments: [], confidence: nil, duration: 1,
            modelIdentifier: "test", cost: nil, rawPayload: nil, debugInfo: nil)
    }
    func cancel() {}
    func awaitCancellationSettled() async {}
}

@MainActor
final class DependencyPasteboard: PolishPasteboard {
    var writes: [String] = []
    var string: String? { self.writes.last }
    func write(_ text: String) { self.writes.append(text) }
}
#endif
