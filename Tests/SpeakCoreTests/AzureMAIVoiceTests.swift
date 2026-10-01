import Foundation
import SpeakTestSupport
import XCTest

@testable import SpeakCore

/// Covers the shared MAI voice catalogue and what travels to Azure for an MAI
/// voice: the regional endpoint, headers, the SSML voice name that selects the
/// model, and how the voice listing and failures come back. Every call goes
/// through a stubbed `URLProtocol`, so no Azure credit is spent.
final class AzureMAIVoiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Catalogue invariants

    func testModels_areTheDocumentedMAIVoice21Pair() {
        XCTAssertEqual(AzureMAIVoiceModel.allCases.map(\.rawValue), ["MAI-Voice-2.1", "MAI-Voice-2.1-Flash"])
        XCTAssertTrue(AzureMAIVoiceModel.voice21Flash.isLowLatency)
        XCTAssertFalse(AzureMAIVoiceModel.voice21.isLowLatency)
    }

    func testEveryCuratedSpeaker_isOfferedWithEveryModelExactlyOnce() {
        let voices = AzureMAIVoiceCatalog.voices
        XCTAssertFalse(voices.isEmpty)
        XCTAssertEqual(Set(voices.map(\.id)).count, voices.count, "voice identifiers must be unique")
        let speakers = Set(voices.map { "\($0.locale)-\($0.speaker)" })
        for speaker in speakers {
            let models = voices.filter { "\($0.locale)-\($0.speaker)" == speaker }.map(\.model)
            XCTAssertEqual(models, AzureMAIVoiceModel.allCases, speaker)
        }
        for voice in voices {
            XCTAssertTrue(voice.id.hasPrefix(AzureMAIVoiceCatalog.voiceIDPrefix))
            XCTAssertTrue(AzureMAIVoiceCatalog.isMAIVoice(voice.id))
            XCTAssertEqual(AzureMAIVoiceCatalog.model(forVoiceID: voice.id), voice.model)
            XCTAssertEqual(AzureMAIVoiceCatalog.displayName(forVoiceID: voice.id), voice.displayName)
        }
    }

    func testCuratedIdentifiers_matchWhatAResourceListingProduces() throws {
        let harper = try XCTUnwrap(AzureMAIVoiceCatalog.voices.first {
            $0.speaker == "Harper" && $0.model == .voice21Flash
        })
        let listed = try decodeVoices(#"""
        [{"ShortName":"en-US-Harper:MAI-Voice-2.1-Flash","DisplayName":"Harper","Locale":"en-US","Gender":"Female"}]
        """#)
        XCTAssertEqual(harper.id, "azure/en-US-Harper:MAI-Voice-2.1-Flash")
        XCTAssertEqual(listed.first?.id, harper.id)
        XCTAssertEqual(listed.first?.name, harper.displayName)
        XCTAssertEqual(harper.displayName, "Harper (en-US, MAI-Voice-2.1-Flash)")
    }

    func testDisplayName_isReadFromTheIdentifierForListedOnlyVoices() {
        XCTAssertEqual(
            AzureMAIVoiceCatalog.displayName(forVoiceID: "azure/de-DE-Klaus:MAI-Voice-2.1"),
            "Klaus (de-DE, MAI-Voice-2.1)"
        )
        // An older model keeps a friendly name even though it has no price.
        XCTAssertEqual(
            AzureMAIVoiceCatalog.displayName(forVoiceID: "azure/en-US-Harper:MAI-Voice-2"),
            "Harper (en-US, MAI-Voice-2)"
        )
        // A locale with a script or variant: the speaker is the last component.
        XCTAssertEqual(
            AzureMAIVoiceCatalog.displayName(forVoiceID: "azure/zh-Hans-CN-Xiaoxiao:MAI-Voice-2.1"),
            "Xiaoxiao (zh-Hans-CN, MAI-Voice-2.1)"
        )
        XCTAssertEqual(
            AzureMAIVoiceCatalog.displayName(forVoiceID: "azure/zh-CN-sichuan-Yunxi:MAI-Voice-2.1-Flash"),
            "Yunxi (zh-CN-sichuan, MAI-Voice-2.1-Flash)"
        )
        XCTAssertNil(AzureMAIVoiceCatalog.displayName(forVoiceID: "azure/en-GB-SoniaNeural"))
        XCTAssertNil(AzureMAIVoiceCatalog.displayName(forVoiceID: "azure/Harper:MAI-Voice-2.1"))
    }

    func testPricing_followsTheModelAndStaysUnknownForUnpricedVoices() {
        XCTAssertEqual(
            AzureMAIVoiceCatalog.estimatedCost(forVoiceID: "azure/en-US-Harper:MAI-Voice-2.1", characterCount: 1000),
            Decimal(string: "0.022")
        )
        XCTAssertEqual(
            AzureMAIVoiceCatalog.estimatedCost(
                forVoiceID: "azure/en-US-Harper:MAI-Voice-2.1-Flash", characterCount: 1000
            ),
            Decimal(string: "0.015")
        )
        XCTAssertNil(AzureMAIVoiceCatalog.model(forVoiceID: "azure/en-US-Harper:MAI-Voice-2"))
        XCTAssertNil(AzureMAIVoiceCatalog.estimatedCost(
            forVoiceID: "azure/en-US-Harper:MAI-Voice-2", characterCount: 1000
        ))
        XCTAssertNil(AzureMAIVoiceCatalog.estimatedCost(forVoiceID: "azure/en-GB-SoniaNeural", characterCount: 1000))
    }

    func testVoicesMissingFromAListing_keepCatalogueOrderAndSkipListedOnes() {
        let first = AzureMAIVoiceCatalog.voices[0]
        let missing = AzureMAIVoiceCatalog.voicesMissing(fromListedIDs: [first.id, "azure/en-GB-SoniaNeural"])
        XCTAssertEqual(missing, Array(AzureMAIVoiceCatalog.voices.dropFirst()))
        XCTAssertTrue(AzureMAIVoiceCatalog.voicesMissing(
            fromListedIDs: Set(AzureMAIVoiceCatalog.voices.map(\.id))
        ).isEmpty)
    }

    // MARK: - Transport

    func testSynthesize_postsTheMAIVoiceNameAsSSMLToTheRegionalEndpoint() async throws {
        let audio = Data("ID3fake".utf8)
        StubURLProtocol.handler = { _ in .status(200, audio) }

        let data = try await AzureSpeechVoiceAPI(session: StubURLProtocol.makeSession()).synthesize(
            credentials: "secret:EastUS", text: "Fish & chips", voice: "azure/en-GB-Emily:MAI-Voice-2.1",
            format: "audio-24khz-160kbitrate-mono-mp3"
        )

        XCTAssertEqual(data, audio)
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://eastus.tts.speech.microsoft.com/cognitiveservices/v1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key"), "secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/ssml+xml")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Microsoft-OutputFormat"), "audio-24khz-160kbitrate-mono-mp3"
        )
        let body = try XCTUnwrap(String(data: StubURLProtocol.body(of: request), encoding: .utf8))
        XCTAssertTrue(body.contains("xml:lang='en-GB'"), body)
        XCTAssertTrue(body.contains("<voice name='en-GB-Emily:MAI-Voice-2.1'>Fish &amp; chips</voice>"), body)
        XCTAssertFalse(body.contains("prosody"), "MAI voices are sent without prosody controls")
    }

    func testSynthesize_keepsAzuresDiagnosticForARejectedRequest() async {
        let reply = Data("Unsupported voice en-US-Harper:MAI-Voice-2.1-Flash.\n".utf8)
        StubURLProtocol.handler = { _ in .status(400, reply) }
        let api = AzureSpeechVoiceAPI(session: StubURLProtocol.makeSession())

        do {
            _ = try await api.synthesize(
                credentials: "secret:eastus", text: "Hello", voice: "azure/en-US-Harper:MAI-Voice-2.1-Flash",
                format: "riff-24khz-16bit-mono-pcm"
            )
            XCTFail("A 400 must not be returned as audio")
        } catch let error as AzureSpeechSynthesisError {
            XCTAssertEqual(error.statusCode, 400)
            XCTAssertEqual(error.detail, "Unsupported voice en-US-Harper:MAI-Voice-2.1-Flash.")
            XCTAssertTrue(error.indicatesUnavailableVoice)
            XCTAssertEqual(
                error.localizedDescription,
                "Azure Speech returned HTTP 400. Unsupported voice en-US-Harper:MAI-Voice-2.1-Flash."
            )
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testSynthesize_keepsCredentialGuidanceForARejectedKey() async {
        StubURLProtocol.handler = { _ in .status(401, Data("Access denied".utf8)) }
        let api = AzureSpeechVoiceAPI(session: StubURLProtocol.makeSession())

        do {
            _ = try await api.synthesize(
                credentials: "secret:eastus", text: "Hello", voice: "azure/en-GB-SoniaNeural",
                format: "riff-24khz-16bit-mono-pcm"
            )
            XCTFail("A 401 must not be returned as audio")
        } catch AzureSpeechError.service(let status) {
            XCTAssertEqual(status, 401)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testSynthesisError_truncatesAndRedactsTheResponseText() {
        let body = "Key secret-key was rejected. " + String(repeating: "padding ", count: 100)
        let error = AzureSpeechSynthesisError(statusCode: 429, body: Data(body.utf8), apiKey: "secret-key")

        XCTAssertFalse(error.detail.contains("secret-key"))
        XCTAssertTrue(error.detail.hasPrefix("Key [redacted] was rejected."))
        XCTAssertEqual(error.detail.count, AzureSpeechSynthesisError.detailLimit + 1)
        XCTAssertTrue(error.detail.hasSuffix("…"))
        XCTAssertTrue(error.localizedDescription.hasPrefix("Azure quota or rate limit reached."))
    }

    func testSynthesisError_onlyClaimsAnUnavailableVoiceWhenAzureSaysSo() {
        func error(_ text: String) -> AzureSpeechSynthesisError {
            AzureSpeechSynthesisError(statusCode: 400, body: Data(text.utf8), apiKey: "")
        }
        XCTAssertTrue(error("The voice MAI-Voice-2.1 is not available in this region.").indicatesUnavailableVoice)
        XCTAssertTrue(error("Model not supported for this resource").indicatesUnavailableVoice)
        // A malformed request names neither an unavailable voice nor model.
        XCTAssertFalse(error("SSML parsing error: 0x80045003 - Unexpected element.").indicatesUnavailableVoice)
        XCTAssertFalse(error("").indicatesUnavailableVoice)
        XCTAssertEqual(error("").localizedDescription, "Azure Speech returned HTTP 400.")
    }

    func testSynthesize_treatsAnEmptySuccessAsInvalid() async {
        StubURLProtocol.handler = { _ in .status(200, Data()) }
        let api = AzureSpeechVoiceAPI(session: StubURLProtocol.makeSession())

        do {
            _ = try await api.synthesize(
                credentials: "secret:eastus", text: "Hello", voice: "azure/en-US-Harper:MAI-Voice-2.1",
                format: "riff-24khz-16bit-mono-pcm"
            )
            XCTFail("An empty body is not audio")
        } catch AzureSpeechError.invalidResponse {
            // Expected.
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testSynthesize_rejectsProsodyForMAIBeforeSendingAnything() async {
        StubURLProtocol.handler = { _ in .status(200, Data("ID3".utf8)) }
        let api = AzureSpeechVoiceAPI(session: StubURLProtocol.makeSession())

        do {
            _ = try await api.synthesize(
                credentials: "secret:eastus", text: "Hello", voice: "azure/en-US-Harper:MAI-Voice-2.1",
                format: "riff-24khz-16bit-mono-pcm", speed: 1.25
            )
            XCTFail("MAI voices must not silently drop the speed setting")
        } catch AzureSpeechError.configuration {
            XCTAssertNil(StubURLProtocol.lastRequest)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testListVoices_namesMAIVoicesByLocaleAndModel() async throws {
        let listing = Data(#"""
        [
          {"ShortName":"en-US-Harper:MAI-Voice-2.1","DisplayName":"Harper","Locale":"en-US","Gender":"Female"},
          {"ShortName":"es-MX-Harper:MAI-Voice-2.1-Flash","DisplayName":"Harper","Locale":"es-MX","Gender":"Female"},
          {"ShortName":"en-GB-SoniaNeural","DisplayName":"Sonia","Locale":"en-GB","Gender":"Female"}
        ]
        """#.utf8)
        StubURLProtocol.handler = { _ in .status(200, listing) }

        let voices = try await AzureSpeechVoiceAPI(session: StubURLProtocol.makeSession())
            .listVoices(credentials: "secret:eastus")

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(
            request.url?.absoluteString, "https://eastus.tts.speech.microsoft.com/cognitiveservices/voices/list"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key"), "secret")
        XCTAssertEqual(voices.map(\.isMAI), [true, true, false])
        XCTAssertEqual(voices.map(\.name), [
            "Harper (en-US, MAI-Voice-2.1)", "Harper (es-MX, MAI-Voice-2.1-Flash)", "Sonia"
        ])
        XCTAssertEqual(voices.first?.id, "azure/en-US-Harper:MAI-Voice-2.1")
    }

    // MARK: - Helpers

    private func decodeVoices(_ json: String) throws -> [AzureSpeechVoice] {
        try JSONDecoder().decode([AzureSpeechVoice].self, from: Data(json.utf8))
    }
}
