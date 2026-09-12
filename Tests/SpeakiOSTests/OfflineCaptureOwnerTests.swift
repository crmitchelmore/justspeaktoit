#if os(iOS)
import SpeakCore
import XCTest

@testable import SpeakiOSLib

@MainActor
final class OfflineCaptureOwnerTests: XCTestCase {
    func testForegroundOwnerUsesStrictOfflineRouteWithoutMutatingPreference() async throws {
        let settings = AppSettings.shared
        let originalMode = settings.transcriptionMode
        let originalModel = settings.selectedModel
        defer {
            settings.transcriptionMode = originalMode
            settings.selectedModel = originalModel
        }
        settings.transcriptionMode = .streaming
        settings.selectedModel = "deepgram/nova-3-streaming"
        let session = ForegroundTestSession()
        let coordinator = TranscriberCoordinator(
            sharedState: SharedTranscriptionState(defaults: nil),
            historyManager: makeForegroundTestHistory(),
            ownership: ForegroundRecordingOwnership(),
            ensureKeysLoaded: {},
            liveActivitiesEnabled: { false },
            headlessState: { .idle },
            networkSnapshot: { .unavailable },
            localRecognitionCapability: { locale in
                XCTAssertEqual(locale, TranscriptionLanguageCatalog.localeIdentifier(
                    for: settings.preferredLocaleIdentifier
                ))
                return .available
            }
        )
        coordinator.makeSession = { session }

        try await coordinator.start()
        XCTAssertEqual(coordinator.currentModel, AppleLocalModels.legacySpeechModelID)
        XCTAssertEqual(coordinator.recordingWarning, OfflineCaptureRouting.fallbackNotice)
        XCTAssertEqual(settings.selectedModel, "deepgram/nova-3-streaming")
        XCTAssertEqual(session.starts, 1)
        await coordinator.cancelAndWait()
    }

    func testHeadlessOwnerUsesOfflineNoticeAndReconnectDoesNotStartAnotherSession() async throws {
        let settings = AppSettings.shared
        let originalMode = settings.transcriptionMode
        let originalModel = settings.selectedModel
        defer {
            settings.transcriptionMode = originalMode
            settings.selectedModel = originalModel
        }
        settings.transcriptionMode = .streaming
        settings.selectedModel = "deepgram/nova-3-streaming"
        var snapshot: CaptureConnectivitySnapshot = .unavailable
        var snapshotReads = 0
        let session = ForegroundTestSession()
        let service = self.makeService(
            networkSnapshot: {
                snapshotReads += 1
                return snapshot
            },
            capability: { _ in .available }
        )
        service.makeSession = { session }

        try await service.startRecording(requiresLiveActivity: false)
        XCTAssertEqual(service.providerFallbackNotice, OfflineCaptureRouting.fallbackNotice)
        XCTAssertEqual(settings.selectedModel, "deepgram/nova-3-streaming")
        XCTAssertEqual(session.starts, 1)
        XCTAssertEqual(snapshotReads, 1)
        snapshot = .available
        await Task.yield()
        XCTAssertEqual(session.starts, 1)
        XCTAssertEqual(snapshotReads, 1)
        service.cancelRecording()
    }

    func testExplicitOfflineRemoteModelRefusesBeforeAllocatingSession() async throws {
        let settings = AppSettings.shared
        let originalMode = settings.transcriptionMode
        defer { settings.transcriptionMode = originalMode }
        settings.transcriptionMode = .streaming
        var allocations = 0
        let service = self.makeService(
            networkSnapshot: { .unavailable },
            capability: { _ in .available }
        )
        service.makeSession = {
            allocations += 1
            return ForegroundTestSession()
        }

        do {
            try await service.startRecording(
                requiresLiveActivity: false,
                parameters: CaptureRunParameters(modelID: "deepgram/nova-3-streaming")
            )
            XCTFail("Expected exact-model offline refusal")
        } catch {
            guard case CaptureParameterFailure.modelUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(allocations, 0)
        XCTAssertFalse(service.isRunning)
        XCTAssertFalse(service.isActive)
    }

    private func makeService(
        networkSnapshot: @escaping CaptureNetworkPathMonitor.SnapshotProvider,
        capability: @escaping @MainActor (String) -> AppleLocalRecognitionCapability
    ) -> TranscriptionRecordingService {
        TranscriptionRecordingService(
            sharedState: SharedTranscriptionState(defaults: nil),
            historyManager: makeForegroundTestHistory(),
            polishClipboard: PolishClipboard(),
            hasPolishingKey: { false },
            polish: { text, _, _ in text },
            ensureKeysLoaded: {},
            networkSnapshot: networkSnapshot,
            localRecognitionCapability: capability
        )
    }
}
#endif
