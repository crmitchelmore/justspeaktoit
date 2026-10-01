import SpeakCore
import XCTest

@testable import SpeakApp

final class ComparisonCandidateResolverTests: XCTestCase {
    private func environment(
        keys: Set<String> = [],
        installed: Set<String> = [],
        azure: Bool = true,
        speech: Bool = true,
        dictation: Bool = true
    ) -> ComparisonCandidateResolver.Environment {
        ComparisonCandidateResolver.Environment(
            storedAPIKeyIdentifiers: keys,
            installedLocalModelIDs: installed,
            azureEndpointConfigured: azure,
            supportsSpeechTranscriber: speech,
            supportsDictationTranscriber: dictation
        )
    }

    func testCandidates_coverEveryCatalogueTranscriptionModelOnce() {
        let candidates = ComparisonCandidateResolver.candidates(in: environment())
        let ids = candidates.map(\.modelID)
        XCTAssertEqual(ids.count, Set(ids).count, "No duplicate candidates")
        for option in ModelCatalog.batchTranscription + ModelCatalog.localTranscriptionOptions {
            XCTAssertTrue(ids.contains(option.id), "\(option.id) should be offered for file mode")
        }
        for option in ModelCatalog.remoteLiveTranscription where !option.id.hasPrefix("openai/") {
            XCTAssertTrue(ids.contains(option.id), "\(option.id) should be offered for streaming")
        }
        XCTAssertTrue(ids.contains(AppleLocalModels.speechTranscriberModelID))
        XCTAssertTrue(ids.contains(AppleLocalModels.dictationTranscriberModelID))
    }

    func testCloudModels_areGatedOnTheirAPIKey() {
        let without = ComparisonCandidateResolver.candidates(in: environment())
        let with = ComparisonCandidateResolver.candidates(in: environment(keys: ["deepgram.apiKey"]))

        let deepgramLive = "deepgram/nova-3-streaming"
        XCTAssertEqual(without.first { $0.modelID == deepgramLive }?.unavailableReason, "No Deepgram API key")
        XCTAssertTrue(with.first { $0.modelID == deepgramLive }?.isUsable == true)
        XCTAssertTrue(with.first { $0.modelID == "deepgram/nova-3" }?.isUsable == true, "Batch shares the key")
        XCTAssertFalse(with.first { $0.modelID == "openai/whisper-1" }?.isUsable == true)
    }

    func testAzureStreaming_alsoNeedsItsEndpoint() {
        let candidates = ComparisonCandidateResolver.candidates(
            in: environment(keys: ["azure.speech.apiKey"], azure: false)
        )
        let azure = candidates.first { $0.modelID.hasPrefix("azure/") && $0.supportsStreaming }
        XCTAssertNotNil(azure)
        XCTAssertEqual(azure?.unavailableReason, "Add the Azure Speech endpoint in Settings › API Keys")
    }

    func testLocalModels_areFileOnlyAndGatedOnInstall() {
        let candidates = ComparisonCandidateResolver.candidates(
            in: environment(installed: ["local/whisperkit/tiny"])
        )
        let tiny = candidates.first { $0.modelID == "local/whisperkit/tiny" }
        let base = candidates.first { $0.modelID == "local/whisperkit/base" }
        XCTAssertTrue(tiny?.isUsable == true)
        XCTAssertEqual(tiny?.supportsFile, true)
        XCTAssertEqual(tiny?.supportsStreaming, false)
        XCTAssertEqual(tiny?.providerDisplayName, "On this Mac")
        XCTAssertEqual(base?.unavailableReason, "Not downloaded")
    }

    func testAppleTranscribers_followOSSupportAndWorkInBothModes() {
        let capable = ComparisonCandidateResolver.candidates(in: environment())
        let speech = capable.first { $0.modelID == AppleLocalModels.speechTranscriberModelID }
        XCTAssertTrue(speech?.isUsable == true)
        XCTAssertTrue(speech?.supportsStreaming == true && speech?.supportsFile == true)

        let older = ComparisonCandidateResolver.candidates(in: environment(speech: false, dictation: false))
        XCTAssertNotNil(older.first { $0.modelID == AppleLocalModels.speechTranscriberModelID }?.unavailableReason)
        XCTAssertNotNil(older.first { $0.modelID == AppleLocalModels.dictationTranscriberModelID }?.unavailableReason)
    }

    func testStreamingCandidates_areTheSharedClientRoutes() {
        let candidates = ComparisonCandidateResolver.candidates(in: environment())
        for candidate in candidates where candidate.supportsStreaming {
            switch candidate.engine {
            case .sharedStreamingClient(let route):
                XCTAssertNotEqual(route.provider, .openai)
                XCTAssertNotEqual(route.provider, .apple)
            case .appleSpeechAnalyzer:
                break
            case .cloudBatch, .downloadedLocal:
                XCTFail("\(candidate.modelID) cannot stream")
            }
        }
    }

    func testProviderNames_comeFromTheLiveProviderTableWithACapitalisedFallback() {
        XCTAssertEqual(ComparisonCandidateResolver.providerName(for: "deepgram/nova-3"), "Deepgram")
        XCTAssertEqual(ComparisonCandidateResolver.providerName(for: "groq/whisper-large-v3-turbo"), "Groq")
        XCTAssertEqual(ComparisonCandidateResolver.providerName(for: "something/model"), "Something")
    }
}
