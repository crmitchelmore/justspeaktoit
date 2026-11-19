import SpeakCore
import XCTest

@testable import SpeakApp

final class VoiceEditCloudSharingTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.speakapp.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testVoiceEditAsksForTheInstructionAudioAndTheRewrite() {
        defaults.set("groq/whisper-large-v3-turbo", forKey: "batchTranscriptionModel")
        defaults.set("anthropic/claude-haiku-5.5", forKey: "postProcessingModel")
        let settings = AppSettings(defaults: defaults)
        settings.transcriptionMode = .batchRemote
        settings.postProcessingEnabled = false

        let requests = settings.voiceEditCloudSharingRequests

        // The rewrite goes to the cleanup model even when dictation cleanup is off.
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: requests.map { ($0.provider.id, $0.kinds) }),
            ["groq": [.audio], "openrouter": [.transcriptText]]
        )
    }

    @MainActor
    func testVoiceEditAllowedProvidersNeedNoSheet() {
        defaults.set("groq/whisper-large-v3-turbo", forKey: "batchTranscriptionModel")
        defaults.set("anthropic/claude-haiku-5.5", forKey: "postProcessingModel")
        let settings = AppSettings(defaults: defaults)
        settings.transcriptionMode = .batchRemote
        let store = CloudSharingConsentStore(defaults: defaults)
        store.grant(settings.voiceEditCloudSharingRequests)

        XCTAssertTrue(store.missing(settings.voiceEditCloudSharingRequests).isEmpty)
        settings.batchTranscriptionModel = "deepgram/nova-3"
        XCTAssertEqual(store.missing(settings.voiceEditCloudSharingRequests).map(\.provider.id), ["deepgram"])
    }
}
