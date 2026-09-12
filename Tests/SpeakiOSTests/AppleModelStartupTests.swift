#if os(iOS)
@testable import SpeakCore
import XCTest
@testable import SpeakiOSLib

@MainActor
final class AppleModelStartupTests: XCTestCase {
    func testMissingAssets_allowedFallbackReportsLegacyWithoutChangingSelection() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("SpeechAnalyzer requires iOS 26") }
        let manager = AudioSessionManager()
        manager.configureRecording = {}
        var releases = 0
        manager.deactivateRecording = { releases += 1 }
        let transcriber = iOSLiveTranscriber(audioSessionManager: manager)
        transcriber.permissionCheck = { true }
        transcriber.modelID = AppleLocalModels.speechTranscriberModelID
        var legacyStarts = 0
        transcriber.analyzerStart = { throw AppleLocalModelError.modelAssetsUnavailable }
        transcriber.legacyStart = { legacyStarts += 1 }

        try await transcriber.start()
        XCTAssertTrue(transcriber.isRunning)
        XCTAssertEqual(legacyStarts, 1)
        XCTAssertEqual(transcriber.modelID, AppleLocalModels.speechTranscriberModelID)
        let result = await transcriber.stop()
        XCTAssertEqual(result.modelIdentifier, AppleLocalModels.legacySpeechModelID)
        XCTAssertEqual(releases, 1)
        XCTAssertFalse(manager.isConfigured)
    }

    func testMissingAssets_prohibitedOrUnavailableFallbackReleasesAndCanRestart() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("SpeechAnalyzer requires iOS 26") }
        for fallbackAllowed in [false, true] {
            let manager = AudioSessionManager()
            manager.configureRecording = {}
            var releases = 0
            manager.deactivateRecording = { releases += 1 }
            let transcriber = iOSLiveTranscriber(audioSessionManager: manager)
            transcriber.permissionCheck = { true }
            transcriber.modelID = AppleLocalModels.speechTranscriberModelID
            var legacyStarts = 0
            transcriber.analyzerStart = { throw AppleLocalModelError.modelAssetsUnavailable }
            transcriber.legacyStart = {
                legacyStarts += 1
                throw iOSTranscriptionError.recognizerUnavailable
            }
            do {
                try await transcriber.start(preRollBuffers: [], analyzerFallbackAllowed: fallbackAllowed)
                XCTFail("Expected actionable not-ready error")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Settings"))
                XCTAssertTrue(error.localizedDescription.contains("Prepare Apple model"))
            }
            XCTAssertEqual(legacyStarts, fallbackAllowed ? 1 : 0)
            XCTAssertFalse(transcriber.isRunning)
            XCTAssertFalse(manager.isConfigured)
            XCTAssertFalse(transcriber.audioRecorder.isRecording)
            XCTAssertEqual(releases, 1)
            XCTAssertEqual(transcriber.modelID, AppleLocalModels.speechTranscriberModelID)

            transcriber.analyzerStart = {}
            try await transcriber.start()
            XCTAssertTrue(transcriber.isRunning, "Failed startup must relinquish ownership")
            transcriber.cancel()
            XCTAssertFalse(manager.isConfigured)
            XCTAssertEqual(releases, 2)
        }
    }

    func testMissingAssets_unrelatedFallbackErrorKeepsItsCause() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("SpeechAnalyzer requires iOS 26") }
        let manager = AudioSessionManager()
        manager.configureRecording = {}
        manager.deactivateRecording = {}
        let transcriber = iOSLiveTranscriber(audioSessionManager: manager)
        transcriber.permissionCheck = { true }
        transcriber.modelID = AppleLocalModels.speechTranscriberModelID
        transcriber.analyzerStart = { throw AppleLocalModelError.modelAssetsUnavailable }
        let engineError = NSError(domain: "TestAudioEngine", code: 42)
        transcriber.legacyStart = { throw engineError }
        do {
            try await transcriber.start()
            XCTFail("Expected audio engine failure")
        } catch { XCTAssertEqual(error as NSError, engineError) }
        XCTAssertFalse(manager.isConfigured)
        XCTAssertFalse(transcriber.isRunning)
    }

    func testCancellationDuringAnalyzerCheck_noFallbackAfterLateUnavailableReply() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("SpeechAnalyzer requires iOS 26") }
        let manager = AudioSessionManager()
        manager.configureRecording = {}
        var releases = 0
        manager.deactivateRecording = { releases += 1 }
        let transcriber = iOSLiveTranscriber(audioSessionManager: manager)
        transcriber.permissionCheck = { true }
        transcriber.modelID = AppleLocalModels.speechTranscriberModelID
        let checking = expectation(description: "Asset check suspended")
        let inventory = SuspendedInventory(checking: checking)
        transcriber.analyzerStart = {
            try await AppleSpeechAssets.ensure(
                policy: .installedOnly, status: { await inventory.status() }, install: { false }
            )
        }
        transcriber.legacyStart = { XCTFail("Cancelled startup must never fall back") }
        let cancelled = expectation(description: "Startup cancelled before inventory replies")
        let task = Task {
            do {
                try await transcriber.start()
                XCTFail("Cancelled startup unexpectedly succeeded")
            } catch { XCTAssertTrue(error is CancellationError) }
            cancelled.fulfill()
        }
        await fulfillment(of: [checking], timeout: 2)
        transcriber.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        await task.value
        XCTAssertEqual(releases, 1)
        XCTAssertFalse(transcriber.isRunning)
        XCTAssertFalse(manager.isConfigured)
        XCTAssertFalse(transcriber.audioRecorder.isRecording)
        XCTAssertNil(transcriber.error)
        transcriber.analyzerStart = {}
        try await transcriber.start()
        XCTAssertTrue(transcriber.isRunning)
        transcriber.cancel()
        XCTAssertEqual(releases, 2)
        inventory.reply?.resume(returning: .installed)
    }
}

extension AppleModelStartupTests {
    func testStrictLegacyStartRefusesBeforeInjectedRecognizerCanUseServer() async {
        let manager = AudioSessionManager()
        manager.configureRecording = {}
        var releases = 0
        manager.deactivateRecording = { releases += 1 }
        let transcriber = iOSLiveTranscriber(audioSessionManager: manager)
        transcriber.permissionCheck = { true }
        transcriber.modelID = AppleLocalModels.legacySpeechModelID
        transcriber.requiresStrictOnDeviceRecognition = true
        transcriber.injectedLegacyCapability = { .unavailable }
        transcriber.legacyStart = { XCTFail("Strict capture must not begin an unsupported recognizer") }

        do {
            try await transcriber.start()
            XCTFail("Expected strict local capability refusal")
        } catch {
            guard case iOSTranscriptionError.offlineLocalRecognitionUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(transcriber.isRunning)
        XCTAssertFalse(manager.isConfigured)
        XCTAssertEqual(releases, 1)
    }

    func testStrictAnalyzerMissingAssetsDoesNotFallThroughToUnsupportedLegacyRecognition() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("SpeechAnalyzer requires iOS 26") }
        let manager = AudioSessionManager()
        manager.configureRecording = {}
        manager.deactivateRecording = {}
        let transcriber = iOSLiveTranscriber(audioSessionManager: manager)
        transcriber.permissionCheck = { true }
        transcriber.modelID = AppleLocalModels.speechTranscriberModelID
        transcriber.requiresStrictOnDeviceRecognition = true
        transcriber.analyzerStart = { throw AppleLocalModelError.modelAssetsUnavailable }
        transcriber.injectedLegacyCapability = { .unavailable }
        transcriber.legacyStart = { XCTFail("Unsupported legacy recognition must not start") }

        do {
            try await transcriber.start()
            XCTFail("Expected strict local capability refusal")
        } catch {
            guard case iOSTranscriptionError.offlineLocalRecognitionUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(transcriber.isRunning)
        XCTAssertFalse(manager.isConfigured)
    }

    func testStrictRollingRestartRechecksCapabilityAndDoesNotBeginServerTask() async throws {
        let manager = AudioSessionManager()
        manager.configureRecording = {}
        manager.deactivateRecording = {}
        let transcriber = iOSLiveTranscriber(audioSessionManager: manager)
        transcriber.permissionCheck = { true }
        transcriber.modelID = AppleLocalModels.legacySpeechModelID
        transcriber.requiresStrictOnDeviceRecognition = true
        var capability: AppleLocalRecognitionCapability = .available
        var capabilityChecks = 0
        transcriber.injectedLegacyCapability = {
            capabilityChecks += 1
            return capability
        }
        var callbacks: [(LegacyAppleRecognitionUpdate?, Error?) -> Void] = []
        transcriber.legacyRecognitionStart = { callback in
            callbacks.append(callback)
            return LegacyAppleRecognitionTask(endAudio: {}, finish: {}, cancel: {})
        }
        var errors: [Error] = []
        transcriber.onError = { errors.append($0) }

        try await transcriber.start()
        XCTAssertEqual(callbacks.count, 1)
        XCTAssertEqual(capabilityChecks, 1)
        capability = .unavailable
        callbacks[0](
            LegacyAppleRecognitionUpdate(text: "first", isFinal: true, segments: [], confidence: 1),
            nil
        )

        XCTAssertEqual(callbacks.count, 1)
        XCTAssertEqual(capabilityChecks, 2)
        guard let error = errors.first else { return XCTFail("Expected strict restart refusal") }
        guard case iOSTranscriptionError.offlineLocalRecognitionUnavailable = error else {
            return XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(TranscriberCoordinator.requiresControlledStop(error))
        transcriber.cancel()
    }

    @MainActor
    private final class SuspendedInventory {
        let checking: XCTestExpectation
        var reply: CheckedContinuation<AppleSpeechAssetStatus, Never>?

        init(checking: XCTestExpectation) { self.checking = checking }

        func status() async -> AppleSpeechAssetStatus {
            await withCheckedContinuation { reply = $0; checking.fulfill() }
        }
    }
}
#endif
