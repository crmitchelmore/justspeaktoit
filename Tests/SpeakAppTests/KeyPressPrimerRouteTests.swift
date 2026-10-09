import SpeakCore
import XCTest

@testable import SpeakApp

@MainActor
final class KeyPressPrimerRouteTests: XCTestCase {
    private let bundleID = "com.example.editor"

    private func makeManager(settings: AppSettings, host: WireUpTestHost) -> TranscriptionManager {
        let permissions = host.makePermissions()
        let devices = AudioInputDeviceManager(appSettings: settings)
        let storage = SecureAppStorage(
            permissionsManager: permissions, appSettings: settings, keychainService: host.name
        )
        let openRouter = OpenRouterAPIClient(secureStorage: storage)
        return TranscriptionManager(
            appSettings: settings,
            permissionsManager: permissions,
            audioDeviceManager: devices,
            batchClient: RemoteAudioTranscriber(client: openRouter),
            openRouter: openRouter,
            secureStorage: storage
        )
    }

    func testBatchDefault_WithStreamingAppProfile_PrimesTheEffectiveRouteWithoutMutatingSettings() throws {
        let host = try makeWireUpTestHost()
        let settings = host.makeSettings()
        settings.transcriptionMode = .batchRemote
        let originalLiveModel = settings.liveTranscriptionModel
        let manager = makeManager(settings: settings, host: host)
        let profile = DictationProfile(
            name: "Live", matchers: [.bundleID(bundleID)],
            transcriptionModelID: "deepgram/nova-3-streaming", transcriptionRouting: .remoteStreaming
        )

        XCTAssertFalse(manager.liveRouteUsesLiveInputEngine)
        XCTAssertTrue(manager.liveRouteUsesLiveInputEngine(profiles: [profile], frontmostBundleID: bundleID))
        XCTAssertEqual(settings.transcriptionMode, .batchRemote)
        XCTAssertEqual(settings.liveTranscriptionModel, originalLiveModel)
        XCTAssertEqual(host.makeSettings().transcriptionMode, .batchRemote)
    }

    func testStreamingDefault_WithBatchAppProfiles_DoesNotPrime() throws {
        let host = try makeWireUpTestHost()
        let settings = host.makeSettings()
        settings.transcriptionMode = .liveNative
        settings.liveTranscriptionModel = "deepgram/nova-3-streaming"
        let manager = makeManager(settings: settings, host: host)
        for routing in [DictationProfileTranscriptionRouting.remoteBatch, .localBatch] {
            let profile = DictationProfile(
                name: "Batch", matchers: [.bundleID(bundleID)],
                transcriptionModelID: "openai/whisper-1", transcriptionRouting: routing
            )

            XCTAssertFalse(manager.liveRouteUsesLiveInputEngine(profiles: [profile], frontmostBundleID: bundleID))
        }
        XCTAssertEqual(settings.transcriptionMode, .liveNative)
    }

    func testLegacyStreamingProfile_UsesCanonicalDerivedRouting() throws {
        let host = try makeWireUpTestHost()
        let settings = host.makeSettings()
        settings.transcriptionMode = .batchRemote
        let manager = makeManager(settings: settings, host: host)
        let profile = DictationProfile(
            name: "Legacy live", matchers: [.bundleID(bundleID)], transcriptionModelID: "deepgram/nova-3-streaming"
        )

        XCTAssertTrue(manager.liveRouteUsesLiveInputEngine(profiles: [profile], frontmostBundleID: bundleID))
        XCTAssertFalse(manager.liveRouteUsesLiveInputEngine(profiles: [profile], frontmostBundleID: "com.other.app"))
    }

    func testStreamingProfile_WhoseControllerOwnsItsInput_DoesNotPrime() throws {
        let host = try makeWireUpTestHost()
        let settings = host.makeSettings()
        let manager = makeManager(settings: settings, host: host)
        let profile = DictationProfile(
            name: "Own input", matchers: [.bundleID(bundleID)],
            transcriptionModelID: "local/streaming/whisperkit/tiny", transcriptionRouting: .remoteStreaming
        )

        XCTAssertFalse(manager.liveRouteUsesLiveInputEngine(profiles: [profile], frontmostBundleID: bundleID))
    }
}
