import SpeakCore
import XCTest

@testable import SpeakApp

/// SpeechAnalyzer model warm-up (issue #614), driven through the shared harness.
extension CaptureWarmCoordinatorTests {
    func testSpeechAnalyzerModel_IsWarmedOncePerSelectionAndNotDuringASession() async {
        self.defaults.set(AppleLocalModels.speechTranscriberModelID, forKey: "liveTranscriptionModel")
        let harness = self.makeHarness(speechStatus: .granted)
        harness.coordinator.start()
        await self.waitUntil { harness.speechWarms.calls.count == 1 }
        XCTAssertEqual(harness.speechWarms.calls.first?.model, AppleLocalModels.speechTranscriberModelID)
        XCTAssertEqual(
            harness.speechWarms.calls.first?.locale,
            harness.settings.preferredModelLanguage ?? harness.settings.resolvedPreferredLocaleIdentifier
        )

        harness.coordinator.sessionWillBegin()
        harness.settings.liveTranscriptionModel = AppleLocalModels.dictationTranscriberModelID
        await self.drainTasks()
        XCTAssertEqual(harness.speechWarms.calls.count, 1, "warm-up must not compete with a live capture")

        harness.coordinator.sessionDidEnd()
        harness.coordinator.warmUp()
        await self.drainTasks()
        XCTAssertEqual(harness.speechWarms.calls.map(\.model), [
            AppleLocalModels.speechTranscriberModelID,
            AppleLocalModels.dictationTranscriberModelID
        ])
        await harness.coordinator.invalidate()
    }

    func testSpeechAnalyzerWarmUp_FailureIsRetriedOnTheNextIdleTrigger() async {
        self.defaults.set(AppleLocalModels.speechTranscriberModelID, forKey: "liveTranscriptionModel")
        let harness = self.makeHarness(speechStatus: .granted)
        harness.speechWarms.succeeds = false
        harness.coordinator.start()
        await self.waitUntil { harness.speechWarms.calls.count == 1 }

        harness.speechWarms.succeeds = true
        harness.coordinator.warmUp()
        await self.waitUntil { harness.speechWarms.calls.count == 2 }
        harness.coordinator.warmUp()
        await self.drainTasks()
        XCTAssertEqual(harness.speechWarms.calls.count, 2, "a successful warm-up is not repeated")
        await harness.coordinator.invalidate()
    }

    func testSpeechAnalyzerWarmUp_InFlightPreparationIsCancelledWhenASessionBegins() async {
        self.defaults.set(AppleLocalModels.speechTranscriberModelID, forKey: "liveTranscriptionModel")
        let harness = self.makeHarness(speechStatus: .granted)
        harness.speechWarms.holdsUntilReleased = true
        harness.coordinator.start()
        await self.waitUntil { harness.speechWarms.calls.count == 1 }

        harness.coordinator.sessionWillBegin()
        await self.waitUntil { harness.speechWarms.cancelled == 1 }
        XCTAssertEqual(harness.speechWarms.cancelled, 1)

        harness.speechWarms.holdsUntilReleased = false
        harness.coordinator.sessionDidEnd()
        await self.waitUntil { harness.speechWarms.calls.count == 2 }
        XCTAssertEqual(harness.speechWarms.calls.count, 2, "a cancelled warm-up is retried once idle")
        await harness.coordinator.invalidate()
    }

    func testSpeechAnalyzerModel_IsNotWarmedWithoutSpeechPermissionOrForCloudModels() async {
        self.defaults.set(AppleLocalModels.speechTranscriberModelID, forKey: "liveTranscriptionModel")
        let denied = self.makeHarness(speechStatus: .denied)
        denied.coordinator.start()
        await self.drainTasks()
        XCTAssertTrue(denied.speechWarms.calls.isEmpty)
        await denied.coordinator.invalidate()

        self.defaults.set("deepgram/nova-3-streaming", forKey: "liveTranscriptionModel")
        let cloud = self.makeHarness(speechStatus: .granted)
        cloud.coordinator.start()
        await self.drainTasks(untilProbeCount: 1, in: cloud.warmer)
        XCTAssertTrue(cloud.speechWarms.calls.isEmpty)
        await cloud.coordinator.invalidate()
    }
}

@MainActor
final class SpeechAnalyzerWarmSpy {
    private(set) var calls: [(model: String, locale: String)] = []
    private(set) var cancelled = 0
    var succeeds = true
    var holdsUntilReleased = false
    private var release: CheckedContinuation<Void, Never>?

    func warm(model: String, locale: String) async -> Bool {
        self.calls.append((model, locale))
        if self.holdsUntilReleased {
            await withTaskCancellationHandler {
                await withCheckedContinuation { self.release = $0 }
            } onCancel: {
                Task { @MainActor in self.cancelHeld() }
            }
        }
        return self.succeeds && !Task.isCancelled
    }

    private func cancelHeld() {
        guard let release else { return }
        self.release = nil
        self.cancelled += 1
        release.resume()
    }
}
