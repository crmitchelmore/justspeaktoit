import Foundation
import XCTest
@testable import SpeakCore

final class AzureSpeechTests: XCTestCase {
    func testCredentials_preserveLegacyAndRejectHostInjection() throws {
        XCTAssertEqual(try AzureSpeechConfiguration(credentials: "key").region, "eastus")
        XCTAssertEqual(try AzureSpeechConfiguration(credentials: " key: UKSouth ").region, "uksouth")
        for value in ["", "key:", "key:evil.example/path", "key:uksouth@evil",
                      "key:" + String(repeating: "a", count: 64)] {
            XCTAssertThrowsError(try AzureSpeechConfiguration(credentials: value), value)
        }
    }

    func testRegionalURLs_areBuiltFromComponentsNotInterpolation() throws {
        let config = try AzureSpeechConfiguration(credentials: "key:UKSouth")
        XCTAssertEqual(config.voicesURL.absoluteString,
                       "https://uksouth.tts.speech.microsoft.com/cognitiveservices/voices/list")
        XCTAssertEqual(config.synthesisURL.absoluteString,
                       "https://uksouth.tts.speech.microsoft.com/cognitiveservices/v1")
        XCTAssertEqual(config.transcriptionURL.absoluteString, "https://uksouth.api.cognitive.microsoft.com")
    }

    func testEndpoint_rejectsCredentialsPathsAndUntrustedHosts() throws {
        for endpoint in ["http://demo.cognitiveservices.azure.com", "https://evil.example",
                         "https://demo.cognitiveservices.azure.com.evil.example",
                         "https://key@demo.cognitiveservices.azure.com",
                         "https://demo.cognitiveservices.azure.com/path",
                         "https://demo.cognitiveservices.azure.com/?key=test"] {
            XCTAssertThrowsError(try AzureSpeechConfiguration.resourceURL(endpoint), endpoint)
        }
        XCTAssertEqual(try AzureSpeechConfiguration.resourceURL("https://demo.services.ai.azure.com/").host,
                       "demo.services.ai.azure.com")
    }

    func testRegionalVoiceResponse_keepsMAIModelIdentity() throws {
        let data = Data(#"""
        [
          {
            "ShortName": "en-US-Harper:MAI-Voice-2-Flash",
            "DisplayName": "Harper",
            "Locale": "en-US",
            "Gender": "Female"
          }
        ]
        """#.utf8)
        let voice = try XCTUnwrap(JSONDecoder().decode([AzureSpeechVoice].self, from: data).first)
        XCTAssertTrue(voice.isMAI)
        XCTAssertEqual(voice.id, "azure/en-US-Harper:MAI-Voice-2-Flash")
        XCTAssertEqual(voice.name, "Harper (MAI-Voice-2-Flash)")
    }

    func testMAISynthesis_preservesColonAndEscapesPlainText() throws {
        let request = try AzureSpeechVoiceAPI.synthesisRequest(
            credentials: "secret:uksouth", text: "A & B < C", voice: "azure/en-US-Harper:MAI-Voice-2",
            format: "riff-24khz-16bit-mono-pcm"
        )
        XCTAssertEqual(request.url?.host, "uksouth.tts.speech.microsoft.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key"), "secret")
        XCTAssertFalse(request.url!.absoluteString.contains("secret"))
        let body = try XCTUnwrap(String(data: XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertTrue(body.contains("en-US-Harper:MAI-Voice-2"))
        XCTAssertTrue(body.contains("A &amp; B &lt; C"))
        XCTAssertFalse(body.contains("prosody"))
    }

    func testMAI_rejectsUnsupportedProsodyInsteadOfIgnoringUserSettings() {
        XCTAssertThrowsError(try AzureSpeechVoiceAPI.synthesisRequest(
            credentials: "key:uksouth", text: "Hello", voice: "azure/en-US-Harper:MAI-Voice-2",
            format: "mp3", speed: 1.5
        ))
    }

    func testNeuralVoice_preservesProsodyAndEmptyTextMakesNoRequest() throws {
        let request = try AzureSpeechVoiceAPI.synthesisRequest(
            credentials: "key:uksouth", text: "Hello", voice: "azure/en-GB-SoniaNeural", format: "mp3",
            speed: 1.5
        )
        let body = try XCTUnwrap(String(data: XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertTrue(body.contains("xml:lang='en-GB'"))
        XCTAssertTrue(body.contains("rate='+50%'"))
        XCTAssertTrue(body.contains("pitch='+0st'"))
        XCTAssertThrowsError(try AzureSpeechVoiceAPI.synthesisRequest(
            credentials: "key", text: " \n", voice: "azure/en-GB-SoniaNeural", format: "mp3"
        ))
    }

    func testBatchRequest_pinsMAI2WithoutPretendingItIsStreaming() throws {
        let request = try AzureBatchTranscriptionClient.request(
            origin: URL(string: "https://demo.cognitiveservices.azure.com")!, key: "secret", audio: Data([
                0,
                1
            ]),
            model: AzureTranscriptionModels.mai2, language: nil, keywords: ["Just Speak"]
        )
        XCTAssertEqual(request.url?.path, "/speechtotext/transcriptions:transcribe")
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.query,
                       "api-version=2025-10-15")
        let body = try XCTUnwrap(String(data: XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertTrue(body.contains("MAI-Transcribe-2"))
        XCTAssertTrue(body.contains("enhancedMode"))
        XCTAssertTrue(body.contains("Just Speak"))
        XCTAssertFalse(body.contains("locales"))
        XCTAssertThrowsError(try AzureBatchTranscriptionClient.request(
            origin: URL(string: "https://demo.cognitiveservices.azure.com")!, key: "key", audio: Data(),
            model: AzureTranscriptionModels.maiLive, language: nil, keywords: []
        ))
    }

    func testBatchResponse_preservesTextAndMillisecondTiming() throws {
        let result = try AzureBatchTranscriptionClient.result(data: Data(#"""
        {
          "durationMilliseconds": 2500,
          "combinedPhrases": [
            {
              "text": "Hello world."
            }
          ],
          "phrases": [
            {
              "text": "Hello world.",
              "offsetMilliseconds": 500,
              "durationMilliseconds": 1000
            }
          ]
        }
        """#.utf8), model: AzureTranscriptionModels.mai2)
        XCTAssertEqual(result.text, "Hello world.")
        XCTAssertEqual(result.duration, 2.5)
        XCTAssertEqual(result.segments.first?.startTime, 0.5)
        XCTAssertEqual(result.segments.first?.endTime, 1.5)
        XCTAssertThrowsError(try AzureBatchTranscriptionClient.result(
            data: Data("{}".utf8),
            model: "azure/unknown"
        ))
    }

    func testBatchSilence_remainsEmpty() throws {
        let result = try AzureBatchTranscriptionClient.result(
            data: Data(#"{"combinedPhrases":[],"phrases":[]}"#.utf8),
            model: AzureTranscriptionModels.fast
        )
        XCTAssertEqual(result.text, "")
        XCTAssertTrue(result.segments.isEmpty)
    }

    func testLiveSession_disablesAssistantAndUsesUnversionedLiveMAI() throws {
        let event = try AzureVoiceLiveClient.sessionUpdate(model: "mai-transcribe", language: "en_GB")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any])
        let session = try XCTUnwrap(root["session"] as? [String: Any])
        XCTAssertEqual(session["input_audio_sampling_rate"] as? Int, 24_000)
        XCTAssertEqual((session["turn_detection"] as? [String: Any])?["create_response"] as? Bool, false)
        XCTAssertEqual(
            (session["input_audio_transcription"] as? [String: Any])?["model"] as? String,
            "mai-transcribe"
        )
        XCTAssertEqual(session["modalities"] as? [String], ["text"])
        XCTAssertFalse(event.contains("response.create"))
        XCTAssertThrowsError(try AzureVoiceLiveClient.sessionUpdate(model: "mai-transcribe-2", language: nil))
    }

    func testLiveRequest_keepsKeyOutOfURL() throws {
        let request = try AzureVoiceLiveClient.connectionRequest(
            credentials: "secret:uksouth", endpoint: "https://demo.services.ai.azure.com"
        )
        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertEqual(request.url?.path, "/voice-live/realtime")
        XCTAssertEqual(request.value(forHTTPHeaderField: "api-key"), "secret")
        XCTAssertFalse(request.url!.absoluteString.contains("secret"))
    }

    func testLiveFinalisation_returnsFullTranscriptAndDeduplicatesEventsNotUtterances() async {
        let client = AzureVoiceLiveClient(
            credentials: "key",
            endpoint: "",
            model: "mai-transcribe",
            language: nil
        )
        client.ingest(#"{"type":"input_audio_buffer.committed","item_id":"a"}"#)
        client.ingest(#"{"type":"input_audio_buffer.committed","item_id":"b"}"#)
        client
            .ingest(
                #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"a","delta":"Hel"}"#
            )
        client.ingest(#"""
        {
          "type": "conversation.item.input_audio_transcription.completed",
          "item_id": "b",
          "transcript": "Hello."
        }
        """#)
        client.ingest(#"""
        {
          "type": "conversation.item.input_audio_transcription.completed",
          "item_id": "a",
          "transcript": "Hello."
        }
        """#)
        client.ingest(#"""
        {
          "type": "conversation.item.input_audio_transcription.completed",
          "item_id": "a",
          "transcript": "Hello."
        }
        """#)
        let text = await client.finishAndWait()
        XCTAssertEqual(text, "Hello. Hello.")
    }

    func testModels_useOneCredentialAndSharedClientAcrossPlatforms() throws {
        for option in AzureTranscriptionModels.liveOptions {
            let route = try XCTUnwrap(LiveTranscriptionRouting.route(for: option.id))
            XCTAssertEqual(route.provider, .azure)
            XCTAssertTrue(route.isSupportedOnIOS)
            XCTAssertEqual(route.apiKeyIdentifier, AzureSpeechConfiguration.credentialIdentifier)
            XCTAssertEqual(route.sampleRate, 24_000)
            XCTAssertNotNil(LiveTranscriptionClientFactory.makeClient(
                for: route,
                apiKey: "key",
                language: nil
            ))
            XCTAssertTrue(ModelCatalog.liveCapabilities(for: option.id).supportedSpeedModes
                .contains(.livePolish))
        }
        for model in AzureTranscriptionModels.batchIDs {
            XCTAssertEqual(ModelCredentialResolver.requirement(for: model, purpose: .batchTranscription),
                           .apiKey(
                               identifier: AzureSpeechConfiguration.credentialIdentifier,
                               providerName: "Azure Speech"
                           ))
        }
    }
}

/// Voice Live event handling, driven through `ingest` without a socket.
final class AzureVoiceLiveClientTests: XCTestCase {
    /// Azure reports `input_audio_transcription.failed` per item. One failed
    /// turn must not end the session (later utterances still arrive), but a
    /// finish that yields nothing at all is reported rather than returned as
    /// silence.
    func testLiveFailedItem_keepsSessionAndReportsOnlyWhenNothingWasTranscribed() async {
        let client = AzureVoiceLiveClient(credentials: "key", endpoint: "", model: "azure-speech", language: nil)
        let errors = LockedBox<[Error]>([])
        let partials = LockedBox<[String]>([])
        client.beginSession(
            onTranscript: { text, _ in partials.mutate { $0.append(text) } },
            onError: { error in errors.mutate { $0.append(error) } }
        )
        client.ingest(#"{"type":"input_audio_buffer.committed","item_id":"a"}"#)
        client.ingest(#"{"type":"conversation.item.input_audio_transcription.failed","item_id":"a"}"#)
        client.ingest(#"{"type":"input_audio_buffer.committed","item_id":"b"}"#)
        client.ingest(#"""
        {
          "type": "conversation.item.input_audio_transcription.completed",
          "item_id": "b",
          "transcript": "Still here."
        }
        """#)
        XCTAssertEqual(partials.value, ["Still here."])
        let text = await client.finishAndWait()
        XCTAssertEqual(text, "Still here.")
        XCTAssertTrue(errors.value.isEmpty, "A single failed turn must not surface as a session error")

        let silent = AzureVoiceLiveClient(credentials: "key", endpoint: "", model: "azure-speech", language: nil)
        let silentErrors = LockedBox<[Error]>([])
        silent.beginSession(onTranscript: { _, _ in }, onError: { error in silentErrors.mutate { $0.append(error) } })
        silent.ingest(#"{"type":"input_audio_buffer.committed","item_id":"a"}"#)
        silent.ingest(#"{"type":"conversation.item.input_audio_transcription.failed","item_id":"a"}"#)
        let nothing = await silent.finishAndWait()
        XCTAssertNil(nothing)
        XCTAssertEqual(silentErrors.value.count, 1)
        XCTAssertEqual(
            silentErrors.value.first?.localizedDescription,
            AzureSpeechError.transcriptionFailed.localizedDescription
        )
    }

    /// The first `session.updated` is the handshake the shared readiness gate
    /// tracks; a later one (the finalisation barrier) must not re-arm it.
    func testLiveHandshake_isTheFirstSessionUpdated() {
        let client = AzureVoiceLiveClient(credentials: "key", endpoint: "", model: "azure-speech", language: nil)
        client.beginSession(onTranscript: { _, _ in }, onError: { _ in })
        XCTAssertFalse(client.readiness.isReady)
        XCTAssertEqual(client.preroll.maximumByteCount, 24_000 * 2 * 5)
        client.ingest(#"{"type":"session.updated","session":{}}"#)
        XCTAssertTrue(client.readiness.isReady)
        client.ingest(#"{"type":"session.updated","session":{}}"#)
        XCTAssertTrue(client.readiness.isReady)
    }
}

/// A minimal thread-safe box for callback capture in the tests above.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}
