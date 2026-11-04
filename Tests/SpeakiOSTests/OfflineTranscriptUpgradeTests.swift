#if os(iOS)
import SpeakCore
import XCTest

@testable import SpeakiOSLib

/// Offline transcript upgrades (issue #999), driven with a fake network,
/// a fake History and a fake transcriber. No provider is ever called.
@MainActor
final class OfflineTranscriptUpgradeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: OfflineTranscriptUpgradeStore!
    private var history: [UUID: iOSHistoryItem] = [:]
    private var connectivity: CaptureConnectivitySnapshot = .available
    private var enabled = true
    private var transcribeCalls: [(URL, String)] = []
    private var transcribeResult: Result<String, Error> = .success("cloud words")
    private var upserts = 0
    private var onTranscribe: (() -> Void)?

    private let recordingID = UUID()
    private let recordingURL = URL(fileURLWithPath: "/tmp/offline-upgrade.m4a")
    private var batchModel: String {
        AppSettings.supportedBatchModels.first { !AppleLocalModels.isSpeechAnalyzerModel($0.id) }!.id
    }

    override func setUp() async throws {
        self.defaults = UserDefaults(suiteName: "OfflineTranscriptUpgradeTests.\(UUID())")
        self.store = OfflineTranscriptUpgradeStore(defaults: self.defaults)
    }

    private func makeUpgrader() -> OfflineTranscriptUpgrader {
        OfflineTranscriptUpgrader(store: self.store, dependencies: .init(
            isEnabled: { self.enabled },
            connectivity: { self.connectivity },
            prepareHistory: { true },
            historyItem: { self.history[$0] },
            upsert: { item in
                self.upserts += 1
                self.history[item.id] = item
                return true
            },
            recordingURL: { $0 == self.recordingID ? self.recordingURL : nil },
            transcribe: { url, model in
                self.transcribeCalls.append((url, model))
                self.onTranscribe?()
                return try self.transcribeResult.get()
            },
            now: { Date(timeIntervalSince1970: 2_000_000_000) }
        ))
    }

    private func fileOfflineItem() -> iOSHistoryItem {
        let item = iOSHistoryItem(
            createdAt: Date(timeIntervalSince1970: 1_000),
            transcription: "on device words",
            model: AppleLocalModels.legacySpeechModelID,
            duration: 12,
            wordCount: 3,
            errorMessage: nil
        )
        self.history[item.id] = item
        return item
    }

    func testSettingDefaultsOff() {
        let suite = UserDefaults(suiteName: "OfflineUpgradeDefault.\(UUID())")!
        XCTAssertFalse(suite.bool(forKey: AppSettings.DefaultsKey.upgradeOfflineTranscriptsWhenOnline.storageKey))
        XCTAssertFalse(AppSettings(defaults: suite, loadsSecureStorage: false).upgradeOfflineTranscriptsWhenOnline)
    }

    func testTagIsNoOpWhenSettingOff() {
        self.enabled = false
        let item = self.fileOfflineItem()
        self.makeUpgrader().tag(item: item, recordingID: self.recordingID, intendedModelID: self.batchModel)
        XCTAssertTrue(self.store.tickets().isEmpty)
    }

    func testStreamingOnlyModelIsNotEligible() {
        let streamingOnly = "deepgram/nova-3-streaming"
        XCTAssertFalse(AppSettings.supportedBatchModels.contains { $0.id == streamingOnly })
        XCTAssertNil(OfflineTranscriptUpgradePolicy.targetModel(forIntended: streamingOnly))
        XCTAssertNil(OfflineTranscriptUpgradePolicy.targetModel(forIntended: AppleLocalModels.legacySpeechModelID))
        let item = self.fileOfflineItem()
        self.makeUpgrader().tag(item: item, recordingID: self.recordingID, intendedModelID: streamingOnly)
        XCTAssertTrue(self.store.tickets().isEmpty)
    }

    func testUpgradeReplacesRowInPlaceWithIntendedModel() async {
        let item = self.fileOfflineItem()
        let upgrader = self.makeUpgrader()
        upgrader.tag(item: item, recordingID: self.recordingID, intendedModelID: self.batchModel)
        XCTAssertEqual(self.store.tickets().first?.targetModelID, self.batchModel)

        await upgrader.run()

        XCTAssertEqual(self.transcribeCalls.count, 1)
        XCTAssertEqual(self.transcribeCalls.first?.0, self.recordingURL)
        XCTAssertEqual(self.transcribeCalls.first?.1, self.batchModel)
        let upgraded = self.history[item.id]
        XCTAssertEqual(self.history.count, 1)
        XCTAssertEqual(upgraded?.transcription, "cloud words")
        XCTAssertEqual(upgraded?.model, self.batchModel)
        XCTAssertEqual(upgraded?.createdAt, item.createdAt)
        XCTAssertEqual(upgraded?.duration, item.duration)
        XCTAssertEqual(upgraded?.wordCount, 2)
        XCTAssertTrue(self.store.tickets().isEmpty)

        // Idempotent: a repeat run (or a stale ticket after a kill) never re-runs or re-writes.
        upgrader.tag(item: item, recordingID: self.recordingID, intendedModelID: self.batchModel)
        await upgrader.run()
        XCTAssertEqual(self.transcribeCalls.count, 1)
        XCTAssertEqual(self.upserts, 1)
        XCTAssertTrue(self.store.tickets().isEmpty)
    }

    func testDoesNothingWhileOfflineOrUnknown() async {
        let item = self.fileOfflineItem()
        let upgrader = self.makeUpgrader()
        upgrader.tag(item: item, recordingID: self.recordingID, intendedModelID: self.batchModel)
        for snapshot in [CaptureConnectivitySnapshot.unavailable, .unknown] {
            self.connectivity = snapshot
            await upgrader.run()
        }
        XCTAssertTrue(self.transcribeCalls.isEmpty)
        XCTAssertEqual(self.store.tickets().count, 1)
    }

    func testDisablingSettingStopsPendingUpgrades() async {
        let item = self.fileOfflineItem()
        let upgrader = self.makeUpgrader()
        upgrader.tag(item: item, recordingID: self.recordingID, intendedModelID: self.batchModel)
        self.enabled = false
        await upgrader.run()
        XCTAssertTrue(self.transcribeCalls.isEmpty)
        XCTAssertEqual(self.history[item.id]?.transcription, "on device words")
    }

    func testEditedRowIsNeverOverwritten() async {
        let item = self.fileOfflineItem()
        let upgrader = self.makeUpgrader()
        upgrader.tag(item: item, recordingID: self.recordingID, intendedModelID: self.batchModel)
        self.history[item.id] = item.withPostProcessed("polished by the user", updatedAt: Date())

        await upgrader.run()

        XCTAssertTrue(self.transcribeCalls.isEmpty)
        XCTAssertEqual(self.history[item.id]?.postProcessedTranscription, "polished by the user")
        XCTAssertEqual(self.history[item.id]?.transcription, "on device words")
        XCTAssertTrue(self.store.tickets().isEmpty)
    }

    func testEditDuringTranscriptionWins() async {
        let item = self.fileOfflineItem()
        let upgrader = self.makeUpgrader()
        upgrader.tag(item: item, recordingID: self.recordingID, intendedModelID: self.batchModel)
        self.onTranscribe = {
            self.history[item.id] = item.withPostProcessed("edited meanwhile", updatedAt: Date())
        }

        await upgrader.run()

        XCTAssertEqual(self.transcribeCalls.count, 1)
        XCTAssertEqual(self.upserts, 0)
        XCTAssertEqual(self.history[item.id]?.postProcessedTranscription, "edited meanwhile")
        XCTAssertTrue(self.store.tickets().isEmpty)
    }

    func testDeletedRowOrMissingAudioDropsTicketWithoutTranscribing() async {
        let item = self.fileOfflineItem()
        let upgrader = self.makeUpgrader()
        upgrader.tag(item: item, recordingID: UUID(), intendedModelID: self.batchModel)
        await upgrader.run()
        XCTAssertTrue(self.store.tickets().isEmpty)

        upgrader.tag(item: item, recordingID: self.recordingID, intendedModelID: self.batchModel)
        self.history[item.id] = nil
        await upgrader.run()
        XCTAssertTrue(self.transcribeCalls.isEmpty)
        XCTAssertTrue(self.store.tickets().isEmpty)
    }

    func testFailuresAreRetriedAtMostMaxAttempts() async {
        struct ProviderDown: Error {}
        self.transcribeResult = .failure(ProviderDown())
        let item = self.fileOfflineItem()
        let upgrader = self.makeUpgrader()
        upgrader.tag(item: item, recordingID: self.recordingID, intendedModelID: self.batchModel)

        for _ in 0..<(OfflineTranscriptUpgradePolicy.maxAttempts + 2) {
            await upgrader.run()
        }

        XCTAssertEqual(self.transcribeCalls.count, OfflineTranscriptUpgradePolicy.maxAttempts)
        XCTAssertTrue(self.store.tickets().isEmpty)
        XCTAssertEqual(self.history[item.id]?.transcription, "on device words")
    }

    func testEmptyResultCountsAsFailureAndKeepsOnDeviceText() async {
        self.transcribeResult = .success("   ")
        let item = self.fileOfflineItem()
        let upgrader = self.makeUpgrader()
        upgrader.tag(item: item, recordingID: self.recordingID, intendedModelID: self.batchModel)
        await upgrader.run()
        XCTAssertEqual(self.store.tickets().first?.attempts, 1)
        XCTAssertEqual(self.history[item.id]?.transcription, "on device words")
    }

    func testFailureAfterGoingOfflineCostsNoAttempt() async {
        struct NoRoute: Error {}
        self.transcribeResult = .failure(NoRoute())
        self.onTranscribe = { self.connectivity = .unavailable }
        let item = self.fileOfflineItem()
        let upgrader = self.makeUpgrader()
        upgrader.tag(item: item, recordingID: self.recordingID, intendedModelID: self.batchModel)
        await upgrader.run()
        XCTAssertEqual(self.store.tickets().first?.attempts, 0)
    }

    func testUnloadedHistoryKeepsTickets() async {
        let item = self.fileOfflineItem()
        let upgrader = OfflineTranscriptUpgrader(store: self.store, dependencies: .init(
            isEnabled: { true },
            connectivity: { .available },
            prepareHistory: { false },
            historyItem: { _ in nil },
            upsert: { _ in XCTFail("no write without History"); return false },
            recordingURL: { _ in self.recordingURL },
            transcribe: { _, _ in XCTFail("no transcription without History"); return "" }
        ))
        upgrader.tag(item: item, recordingID: self.recordingID, intendedModelID: self.batchModel)
        await upgrader.run()
        XCTAssertEqual(self.store.tickets().count, 1)
    }

    func testWholeSecondHistoryTimestampStillCountsAsUntouched() {
        let filed = Date(timeIntervalSince1970: 1_000.75)
        let ticket = OfflineTranscriptUpgradeTicket(
            historyID: UUID(), recordingID: UUID(), targetModelID: "m",
            onDeviceText: "words", filedUpdatedAt: filed
        )
        let reloaded = iOSHistoryItem(
            createdAt: Date(timeIntervalSince1970: 1_000), transcription: "words",
            model: "apple", duration: 1, wordCount: 1
        )
        XCTAssertTrue(OfflineTranscriptUpgradePolicy.isUntouched(reloaded, since: ticket))
    }

    func testForegroundOfflineCaptureTagsIntendedModelAndRecording() async throws {
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
            session.safetyRecordingID = self.recordingID
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
                XCTAssertEqual(tags.first?.0, self.recordingID)
                XCTAssertEqual(tags.first?.1, "deepgram/nova-3-streaming")
            } else {
                XCTAssertTrue(tags.isEmpty, "An online capture is never queued for an upgrade")
            }
        }
    }
}
#endif
