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

    func testIsSupportedOnIOS_allCatalogueProvidersWired() {
        // Assert: every provider the catalogue exposes now runs on iOS.
        for provider in LiveTranscriptionProviderID.allCases {
            XCTAssertTrue(provider.isSupportedOnIOS, "\(provider) should be iOS-supported")
        }
    }

    // MARK: - Factory

    func testFactory_buildsSharedClientForShippedProviders() {
        // Arrange
        let shared = [
            "deepgram/nova-3-streaming",
            "elevenlabs/scribe-v2-streaming",
            "cartesia/ink-2-streaming",
            "soniox/stt-rt-v5-streaming",
            "modulate/velma-2-stt-streaming",
            "assemblyai/u3-rt-pro-streaming",
            "gladia/solaria-1-streaming"
        ]

        // Act / Assert
        for id in shared {
            let route = LiveTranscriptionRouting.route(for: id)!
            XCTAssertNotNil(
                LiveTranscriptionClientFactory.makeClient(for: route, apiKey: "k", language: nil),
                "expected a shared client for \(id)"
            )
        }
    }

    func testFactory_returnsNilForNativeProviders() {
        // Apple (on-device) and OpenAI (platform-native transcriber) have no
        // shared factory client.
        let apple = LiveTranscriptionRouting.route(for: "apple/local/SFSpeechRecognizer")!
        let openai = LiveTranscriptionRouting.route(for: "openai/gpt-realtime-whisper-streaming")!

        XCTAssertNil(LiveTranscriptionClientFactory.makeClient(for: apple, apiKey: "k", language: nil))
        XCTAssertNil(LiveTranscriptionClientFactory.makeClient(for: openai, apiKey: "k", language: nil))
    }
}
