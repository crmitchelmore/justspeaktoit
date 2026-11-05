#if os(iOS)
import SpeakCore
import XCTest

@testable import SpeakiOSLib

/// Offline transcript upgrades (issue #999): policy, History and capture wiring.
@MainActor
final class OfflineTranscriptUpgradeHistoryTests: XCTestCase {
    func testHistoryWorkerRefusesReplacementOfAdmittedEdit() async throws {
        let history = makeForegroundTestHistory()
        await history.loadIfNeededAndWait()
        let filedRow = await history.recordTranscriptionAndWait(
            text: "on device words", model: AppleLocalModels.legacySpeechModelID, duration: 1
        )
        let filed = try XCTUnwrap(filedRow)
        let fingerprint = OfflineTranscriptUpgradePolicy.fingerprint(filed.transcription)
        let cloud = OfflineTranscriptUpgradePolicy.upgraded(filed, text: "cloud words", model: "m", now: Date())

        // The worker, not the caller's snapshot, decides: an earlier edit wins.
        let edited = await history.upsertAndWait(filed.withPostProcessed("polished", updatedAt: Date()))
        XCTAssertTrue(edited)
        let didReplace = await history.replaceIfUntouchedAndWait(
            cloud, fingerprint: fingerprint, filedAt: filed.updatedAt
        )
        XCTAssertFalse(didReplace)
        XCTAssertEqual(history.items.first { $0.id == filed.id }?.postProcessedTranscription, "polished")

        let untouchedRow = await history.recordTranscriptionAndWait(
            text: "more words", model: AppleLocalModels.legacySpeechModelID, duration: 1
        )
        let untouched = try XCTUnwrap(untouchedRow)
        let didReplaceUntouched = await history.replaceIfUntouchedAndWait(
            OfflineTranscriptUpgradePolicy.upgraded(untouched, text: "cloud words", model: "m", now: Date()),
            fingerprint: OfflineTranscriptUpgradePolicy.fingerprint(untouched.transcription),
            filedAt: untouched.updatedAt
        )
        XCTAssertTrue(didReplaceUntouched)
        XCTAssertEqual(history.items.first { $0.id == untouched.id }?.transcription, "cloud words")
        XCTAssertEqual(history.items.count, 2)
    }
    func testHistoryDeletionRetiresTickets() {
        let store = OfflineTranscriptUpgradeStore(
            defaults: UserDefaults(suiteName: "OfflineUpgradeStore.\(UUID())") ?? .standard
        )
        let kept = UUID()
        let gone = UUID()
        for id in [kept, gone] {
            store.save(OfflineTranscriptUpgradeTicket(
                historyID: id, recordingID: UUID(), targetModelID: "m", onDeviceFingerprint: "f", filedUpdatedAt: Date()
            ))
        }
        store.remove(historyIDs: [gone])
        XCTAssertEqual(store.tickets().map(\.historyID), [kept])
        store.removeAll()
        XCTAssertTrue(store.tickets().isEmpty)
    }

    func testSettingDefaultsOff() {
        let suite = UserDefaults(suiteName: "OfflineUpgradeDefault.\(UUID())")!
        XCTAssertFalse(suite.bool(forKey: AppSettings.DefaultsKey.upgradeOfflineTranscriptsWhenOnline.storageKey))
        XCTAssertFalse(AppSettings(defaults: suite, loadsSecureStorage: false).upgradeOfflineTranscriptsWhenOnline)
    }
    func testLiveModelResolvesToItsBatchCounterpart() {
        XCTAssertTrue(AppSettings.supportedBatchModels.contains { $0.id == "openai/gpt-4o-transcribe" })
        XCTAssertEqual(
            OfflineTranscriptUpgradePolicy.targetModel(forIntended: "openai/gpt-4o-transcribe-streaming"),
            "openai/gpt-4o-transcribe"
        )
    }
    func testWholeSecondHistoryTimestampStillCountsAsUntouched() {
        let filed = Date(timeIntervalSince1970: 1_000.75)
        let ticket = OfflineTranscriptUpgradeTicket(
            historyID: UUID(), recordingID: UUID(), targetModelID: "m",
            onDeviceFingerprint: OfflineTranscriptUpgradePolicy.fingerprint("words"), filedUpdatedAt: filed
        )
        let reloaded = iOSHistoryItem(
            createdAt: Date(timeIntervalSince1970: 1_000), transcription: "words",
            model: "apple", duration: 1, wordCount: 1
        )
        XCTAssertTrue(OfflineTranscriptUpgradePolicy.isUntouched(reloaded, since: ticket))
    }
    func testForegroundOfflineCaptureTagsIntendedModelAndRecording() async throws {
        let recordingID = UUID()
        let settings = AppSettings.shared
        let originalMode = settings.transcriptionMode
        let originalModel = settings.selectedModel
        defer {
            settings.transcriptionMode = originalMode
            settings.selectedModel = originalModel
        }
        settings.transcriptionMode = .streaming
        settings.selectedModel = "deepgram/nova-3-streaming"

        for snapshot in [CaptureConnectivitySnapshot.unavailable, .available] {
            let session = ForegroundTestSession()
            session.safetyRecordingID = recordingID
            let coordinator = TranscriberCoordinator(
                sharedState: SharedTranscriptionState(defaults: nil),
                historyManager: makeForegroundTestHistory(),
                ownership: ForegroundRecordingOwnership(),
                ensureKeysLoaded: {},
                liveActivitiesEnabled: { false },
                headlessState: { .idle },
                networkSnapshot: { snapshot },
                localRecognitionCapability: { _ in .available }
            )
            coordinator.makeSession = { session }
            var tags: [(UUID, String)] = []
            coordinator.tagOfflineCapture = { _, recording, intended in tags.append((recording, intended)) }

            try await coordinator.start()
            _ = await coordinator.stop()

            if snapshot == .unavailable {
                XCTAssertEqual(tags.count, 1)
                XCTAssertEqual(tags.first?.0, recordingID)
                XCTAssertEqual(tags.first?.1, "deepgram/nova-3-streaming")
            } else {
                XCTAssertTrue(tags.isEmpty, "An online capture is never queued for an upgrade")
            }
        }
    }

    func testUnloadedHistoryKeepsTickets() async {
        let item = iOSHistoryItem(transcription: "words", model: "apple", duration: 1, wordCount: 1)
        let store = OfflineTranscriptUpgradeStore(
            defaults: UserDefaults(suiteName: "OfflineUpgradeUnloaded.\(UUID())") ?? .standard
        )
        let recordingID = UUID()
        let recordingURL = URL(fileURLWithPath: "/tmp/offline-upgrade.m4a")
        let batchModel = AppSettings.supportedBatchModels.first { !AppleLocalModels.isSpeechAnalyzerModel($0.id) }!.id
        let upgrader = OfflineTranscriptUpgrader(store: store, dependencies: .init(
            isEnabled: { true },
            connectivity: { .available },
            prepareHistory: { false },
            historyItem: { _ in nil },
            replaceIfUntouched: { _, _ in XCTFail("no write without History"); return false },
            recordingURLs: { [recordingID: recordingURL] },
            transcribe: { _, _, _ in XCTFail("no transcription without History"); return "" }
        ))
        upgrader.tag(item: item, recordingID: recordingID, intendedModelID: batchModel)
        await upgrader.run()
        XCTAssertEqual(store.tickets().count, 1)
    }
}
#endif
