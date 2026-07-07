import XCTest

@testable import SpeakCore

final class LiveTranscriptionRoutingTests: XCTestCase {

    // MARK: - Model id -> provider + API model name

    func testRoute_deepgramNova_stripsStreamingSuffix() {
        // Arrange
        let modelID = "deepgram/nova-3-streaming"

        // Act
        let route = LiveTranscriptionRouting.route(for: modelID)

        // Assert
        XCTAssertEqual(route?.provider, .deepgram)
        XCTAssertEqual(route?.apiModelName, "nova-3")
        XCTAssertEqual(route?.sampleRate, 16_000)
        XCTAssertEqual(route?.apiKeyIdentifier, "deepgram.apiKey")
    }

    func testRoute_deepgramFlux_keepsModelStem() {
        // Act
        let route = LiveTranscriptionRouting.route(for: "deepgram/flux-general-en-streaming")

        // Assert
        XCTAssertEqual(route?.apiModelName, "flux-general-en")
    }

    func testRoute_elevenLabs_mapsToRealtimeModelName() {
        // Act
        let route = LiveTranscriptionRouting.route(for: "elevenlabs/scribe-v2-streaming")

        // Assert
        XCTAssertEqual(route?.provider, .elevenlabs)
        XCTAssertEqual(route?.apiModelName, "scribe_v2_realtime")
    }

    func testRoute_openAI_uses24kHzAndStripsSuffix() {
        // Act
        let whisper = LiveTranscriptionRouting.route(for: "openai/gpt-realtime-whisper-streaming")
        let mini = LiveTranscriptionRouting.route(for: "openai/gpt-4o-mini-transcribe-streaming")

        // Assert
        XCTAssertEqual(whisper?.apiModelName, "gpt-realtime-whisper")
        XCTAssertEqual(whisper?.sampleRate, 24_000)
        XCTAssertEqual(mini?.apiModelName, "gpt-4o-mini-transcribe")
    }

    func testRoute_apple_hasNoAPIKeyAndPreservesID() {
        // Act
        let route = LiveTranscriptionRouting.route(for: "apple/local/SFSpeechRecognizer")

        // Assert
        XCTAssertEqual(route?.provider, .apple)
        XCTAssertNil(route?.apiKeyIdentifier)
        XCTAssertEqual(route?.apiModelName, "apple/local/SFSpeechRecognizer")
    }

    func testRoute_unknownOrMalformedID_returnsNil() {
        // Assert
        XCTAssertNil(LiveTranscriptionRouting.route(for: "not-a-model"))
        XCTAssertNil(LiveTranscriptionRouting.route(for: "mysteryprovider/foo-streaming"))
    }

    // MARK: - Catalogue coverage (single source of truth)

    func testAllRoutes_coverEveryCatalogLiveModel() {
        // Act
        let routes = LiveTranscriptionRouting.allRoutes

        // Assert: every catalogue live model resolves to a route.
        XCTAssertEqual(routes.count, ModelCatalog.liveTranscription.count)
    }

    // MARK: - iOS availability

    func testIsSupportedOnIOS_reflectsWiredProviders() {
        // Assert
        XCTAssertTrue(LiveTranscriptionProviderID.deepgram.isSupportedOnIOS)
        XCTAssertTrue(LiveTranscriptionProviderID.elevenlabs.isSupportedOnIOS)
        XCTAssertTrue(LiveTranscriptionProviderID.openai.isSupportedOnIOS)
        XCTAssertTrue(LiveTranscriptionProviderID.apple.isSupportedOnIOS)
        XCTAssertFalse(LiveTranscriptionProviderID.cartesia.isSupportedOnIOS)
        XCTAssertFalse(LiveTranscriptionProviderID.gladia.isSupportedOnIOS)
    }

    // MARK: - Factory

    func testFactory_buildsSharedClientForPortedProviders() {
        // Arrange
        let deepgram = LiveTranscriptionRouting.route(for: "deepgram/nova-3-streaming")!
        let elevenlabs = LiveTranscriptionRouting.route(for: "elevenlabs/scribe-v2-streaming")!

        // Act / Assert
        XCTAssertNotNil(
            LiveTranscriptionClientFactory.makeClient(for: deepgram, apiKey: "k", language: nil)
        )
        XCTAssertNotNil(
            LiveTranscriptionClientFactory.makeClient(for: elevenlabs, apiKey: "k", language: nil)
        )
    }

    func testFactory_returnsNilForUnportedProvider() {
        // Arrange
        let cartesia = LiveTranscriptionRouting.route(for: "cartesia/ink-2-streaming")!

        // Act / Assert
        XCTAssertNil(
            LiveTranscriptionClientFactory.makeClient(for: cartesia, apiKey: "k", language: nil)
        )
    }
}
