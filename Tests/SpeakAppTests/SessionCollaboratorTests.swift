import AppKit
import SpeakCore
import XCTest

@testable import SpeakApp

final class SilenceAutoStopTests: XCTestCase {
    private let settings = SilenceAutoStop.Settings(enabled: true, threshold: 0.1, duration: 2)
    private let start = Date(timeIntervalSince1970: 1_000)

    func testObserve_firesOnceAfterSustainedSilence() {
        var monitor = SilenceAutoStop()
        monitor.begin(settings)

        XCTAssertNil(monitor.observe(level: 0.01, eligible: true, now: start))
        XCTAssertNil(monitor.observe(level: 0.01, eligible: true, now: start.addingTimeInterval(1.9)))
        XCTAssertEqual(monitor.observe(level: 0.01, eligible: true, now: start.addingTimeInterval(2.5)), 2.5)
        XCTAssertNil(monitor.silenceStartedAt, "Firing forgets the silence so it fires once")
    }

    func testObserve_speechResetsTheSilenceClock() {
        var monitor = SilenceAutoStop()
        monitor.begin(settings)

        _ = monitor.observe(level: 0.01, eligible: true, now: start)
        _ = monitor.observe(level: 0.5, eligible: true, now: start.addingTimeInterval(1))
        XCTAssertNil(monitor.observe(level: 0.01, eligible: true, now: start.addingTimeInterval(2.5)))
        XCTAssertEqual(monitor.silenceStartedAt, start.addingTimeInterval(2.5))
    }

    func testObserve_neverFiresWhenDisabledOrIneligible() {
        var disabled = SilenceAutoStop()
        disabled.begin(.off)
        var handsFree = SilenceAutoStop()
        handsFree.begin(settings)

        for offset in [0.0, 5, 10] {
            XCTAssertNil(disabled.observe(level: 0, eligible: true, now: start.addingTimeInterval(offset)))
            XCTAssertNil(handsFree.observe(level: 0, eligible: false, now: start.addingTimeInterval(offset)))
        }
        XCTAssertNil(handsFree.silenceStartedAt)
    }
}

@MainActor
final class HUDOcclusionObserverTests: XCTestCase {
    func testObserver_tracksVisibilityAndStopsListening() {
        let center = NotificationCenter()
        var visible = true
        let observer = HUDOcclusionObserver(notificationCenter: center, isAppVisible: { visible })

        observer.start()
        XCTAssertFalse(observer.isOccluded)

        visible = false
        center.post(name: NSApplication.didChangeOcclusionStateNotification, object: nil)
        XCTAssertTrue(observer.isOccluded)

        observer.stop()
        XCTAssertFalse(observer.isOccluded)
        center.post(name: NSApplication.didChangeOcclusionStateNotification, object: nil)
        XCTAssertFalse(observer.isOccluded, "No observer survives stop()")
    }

    func testRepeatedStart_doesNotStackObservers() {
        let center = NotificationCenter()
        var reads = 0
        let observer = HUDOcclusionObserver(notificationCenter: center, isAppVisible: {
            reads += 1
            return true
        })

        observer.start()
        observer.start()
        reads = 0
        center.post(name: NSApplication.didChangeOcclusionStateNotification, object: nil)

        XCTAssertEqual(reads, 1)
    }
}

final class PostProcessingRetryStoreTests: XCTestCase {
    private func result(_ text: String) -> TranscriptionResult {
        TranscriptionResult(
            text: text, segments: [], confidence: nil, duration: 1, modelIdentifier: "m",
            cost: nil, rawPayload: nil, debugInfo: nil
        )
    }

    func testOffer_requiresATranscript() {
        var store = PostProcessingRetryStore()
        let session = ActiveSession(gesture: .uiButton, hotKeyDescription: "")

        XCTAssertFalse(store.offer(for: session))
        XCTAssertFalse(store.canRetry)

        session.transcriptionResult = result("hello")
        XCTAssertTrue(store.offer(for: session))
        XCTAssertTrue(store.canRetry)
        XCTAssertEqual(store.pending?.originalHistoryItemID, session.id)
    }

    func testEntryToRetry_waitsForTheActiveSessionAndClearForgets() {
        var store = PostProcessingRetryStore()
        let session = ActiveSession(gesture: .uiButton, hotKeyDescription: "")
        session.transcriptionResult = result("hello")
        _ = store.offer(for: session)

        XCTAssertNil(store.entryToRetry(sessionActive: true))
        XCTAssertEqual(store.entryToRetry(sessionActive: false)?.transcriptionResult.text, "hello")

        store.clear()
        XCTAssertNil(store.entryToRetry(sessionActive: false))
    }
}

final class SessionNetworkExchangesTests: XCTestCase {
    private func result(model: String, payload: String? = nil) -> TranscriptionResult {
        TranscriptionResult(
            text: "words", segments: [], confidence: nil, duration: 2, modelIdentifier: model,
            cost: nil, rawPayload: payload, debugInfo: nil
        )
    }

    func testLiveTranscription_rowsForLocalDeepgramAndApple() {
        let local = SessionNetworkExchanges.liveTranscription(result(model: "local/streaming/custom"))
        XCTAssertEqual(local?.method, "On-Device")
        XCTAssertEqual(local?.url.scheme, "local")

        let deepgram = SessionNetworkExchanges.liveTranscription(result(model: "deepgram/nova-3", payload: "{}"))
        XCTAssertEqual(deepgram?.url.absoluteString, "wss://api.deepgram.com/v1/listen")
        XCTAssertEqual(deepgram?.responseBodyPreview, "{}")

        let apple = SessionNetworkExchanges.liveTranscription(result(model: "apple/local/speech"))
        XCTAssertEqual(apple?.url.absoluteString, "local://SFSpeechRecognizer")

        XCTAssertNil(SessionNetworkExchanges.liveTranscription(result(model: "soniox/stt-rt")))
    }

    func testFileTranscription_localAlwaysRecordsRemoteOnlyWithPayload() {
        let local = SessionNetworkExchanges.fileTranscription(
            result(model: "local/x"), fileName: "a.wav", isLocal: true
        )
        XCTAssertEqual(local?.requestBodyPreview, "Local audio file: a.wav")

        XCTAssertNil(
            SessionNetworkExchanges.fileTranscription(result(model: "remote"), fileName: "a.wav", isLocal: false)
        )
        let remote = SessionNetworkExchanges.fileTranscription(
            result(model: "remote", payload: String(repeating: "x", count: 900)), fileName: "a.wav", isLocal: false
        )
        XCTAssertEqual(remote?.responseBodyPreview.count, 800)
        XCTAssertEqual(remote?.requestHeaders["Model"], "remote")
    }

    func testPostProcessing_truncatesPayload() {
        let row = SessionNetworkExchanges.postProcessing(
            model: "m", requestPreview: "p", payload: String(repeating: "y", count: 1_000)
        )
        XCTAssertEqual(row.responseBodyPreview.count, 800)
        XCTAssertEqual(row.requestHeaders, ["Model": "m"])
    }
}

final class FirstTranscriptionAnalyticsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "FirstTranscriptionAnalyticsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testEventIfFirst_emitsOnceWithInstallAgeBucket() {
        let installed = Date(timeIntervalSince1970: 0)
        defaults.set(installed, forKey: FirstTranscriptionAnalytics.installDateKey)
        let analytics = FirstTranscriptionAnalytics(
            defaults: defaults, now: { installed.addingTimeInterval(3 * 86_400) }
        )

        XCTAssertEqual(
            analytics.eventIfFirst(modelIdentifier: "Deepgram/Nova-3", isOnDevice: false),
            .firstTranscriptionSucceeded(provider: .deepgram, engine: .cloud, daysSinceInstall: .twoToSeven)
        )
        XCTAssertNil(analytics.eventIfFirst(modelIdentifier: "deepgram/nova-3", isOnDevice: false))
    }

    func testEventIfFirst_recordsInstallDateWhenMissing() {
        let now = Date(timeIntervalSince1970: 500)
        let analytics = FirstTranscriptionAnalytics(defaults: defaults, now: { now })

        XCTAssertEqual(
            analytics.eventIfFirst(modelIdentifier: "local/whisper", isOnDevice: true),
            .firstTranscriptionSucceeded(provider: .local, engine: .onDevice, daysSinceInstall: .zero)
        )
        XCTAssertEqual(defaults.object(forKey: FirstTranscriptionAnalytics.installDateKey) as? Date, now)
    }

    func testBuckets() {
        XCTAssertEqual(FirstTranscriptionAnalytics.bucket(forDaysSinceInstall: 1), .one)
        XCTAssertEqual(FirstTranscriptionAnalytics.bucket(forDaysSinceInstall: 30), .eightToThirty)
        XCTAssertEqual(FirstTranscriptionAnalytics.bucket(forDaysSinceInstall: 31), .overThirty)
        XCTAssertEqual(FirstTranscriptionAnalytics.provider(for: "openai/gpt-4o"), .openAI)
        XCTAssertEqual(FirstTranscriptionAnalytics.provider(for: "fluid/parakeet"), .local)
        XCTAssertEqual(FirstTranscriptionAnalytics.provider(for: "mystery"), .other)
    }
}

@MainActor
final class SessionRetirementTests: XCTestCase {
    private var log: [String] = []

    private func makeRetirement() -> SessionRetirement {
        SessionRetirement(steps: SessionRetirement.Steps(
            finishAutomationCapture: { [unowned self] id in self.log.append("automation \(id)") },
            restoreProfile: { [unowned self] in self.log.append("profile") },
            resumeCaptureWarming: { [unowned self] in self.log.append("warming") },
            releaseDictationCapture: { [unowned self] in self.log.append("capture") },
            resumeKeyPressPriming: { [unowned self] in self.log.append("primer") }
        ))
    }

    func testRetire_runsEveryStepInOrder() {
        let session = ActiveSession(gesture: .uiButton, hotKeyDescription: "Fn")

        makeRetirement().retire(session)

        XCTAssertEqual(log, ["profile", "warming", "capture", "primer"])
    }

    func testRetire_finishesALocalAutomationCaptureFirst() {
        let session = ActiveSession(gesture: .uiButton, hotKeyDescription: "Fn", trigger: .automation)
        session.isLocalAutomationCapture = true

        makeRetirement().retire(session)

        XCTAssertEqual(log, ["automation \(session.id)", "profile", "warming", "capture", "primer"])
    }

    func testRetire_withoutASessionStillRestoresAndReleases() {
        makeRetirement().retire(nil)

        XCTAssertEqual(log, ["profile", "warming", "capture", "primer"])
    }

    func testAbandonStart_onlyUndoesWhatAStartTookBeforeASessionExisted() {
        makeRetirement().abandonStart()

        XCTAssertEqual(log, ["profile", "warming"], "Nothing was reserved, so capture and the primer are untouched")
    }
}
