import Foundation
import XCTest
@testable import SpeakCore

final class AzureMAIStreamingTests: XCTestCase {
    private let streamingModel = "mai-transcribe-2-streaming"

    func testDedicatedStreamingRoutePreservesItsAPISuffixAndLegacySelection() throws {
        let route = try XCTUnwrap(LiveTranscriptionRouting.route(for: AzureTranscriptionModels.mai2Streaming))
        XCTAssertEqual(route.apiModelName, streamingModel)
        XCTAssertEqual(route.provider, .azure)
        XCTAssertEqual(route.apiKeyIdentifier, AzureSpeechConfiguration.credentialIdentifier)
        XCTAssertTrue(route.isSupportedOnIOS)
        XCTAssertEqual(
            LiveTranscriptionRouting.route(for: AzureTranscriptionModels.maiLive)?.apiModelName, "mai-transcribe"
        )
        let streaming = try XCTUnwrap(
            ModelCatalog.liveTranscription.first { $0.id == AzureTranscriptionModels.mai2Streaming }
        )
        XCTAssertTrue(streaming.displayName.contains("MAI-Transcribe-2-Streaming"))
        XCTAssertTrue(try XCTUnwrap(streaming.description).contains("Incremental"))
        let legacy = try XCTUnwrap(ModelCatalog.liveTranscription.first { $0.id == AzureTranscriptionModels.maiLive })
        XCTAssertTrue(legacy.displayName.contains("Turn-based"))
        XCTAssertEqual(AzureTranscriptionModels.maiLive, "azure/mai-transcribe-streaming")
    }

    func testStreamingConfigurationUsesTheActualStreamingModelWithoutAssistantResponses() throws {
        let fixture = AzureVoiceLiveFixture(model: streamingModel, language: "en_GB")
        fixture.start()
        fixture.socket.open()
        let session = try XCTUnwrap(fixture.socket.sessionUpdate?["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, streamingModel)
        XCTAssertEqual(transcription["language"] as? String, "en")
        XCTAssertEqual(session["type"] as? String, "transcription")
        XCTAssertTrue(input["turn_detection"] is NSNull)
        XCTAssertTrue(input["noise_reduction"] is NSNull)
        XCTAssertNil(session["modalities"])
        XCTAssertEqual(fixture.factory.requests.first?.url?.path, "/mai/v1/realtime")
        XCTAssertEqual(fixture.factory.requests.first?.url?.query, "intent=transcription")
        XCTAssertEqual(
            fixture.client.finalisationBudget,
            ModelCatalog.liveCapabilities(for: AzureTranscriptionModels.mai2Streaming).postStopFinalizeBudget
        )
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testIntermediatesReplaceTheirSuffixAndDeltasAdvanceItBeforeAnyTurnCommit() {
        let fixture = AzureVoiceLiveFixture(model: streamingModel)
        fixture.start()
        fixture.becomeReady()
        fixture.socket.delta("Hello", item: "a")
        intermediate(" world", item: "a", socket: fixture.socket)
        intermediate(" there", item: "a", socket: fixture.socket)
        intermediate("", item: "a", socket: fixture.socket)
        intermediate(" there", item: "a", socket: fixture.socket)
        fixture.socket.delta(" there!", item: "a")
        XCTAssertEqual(fixture.events.texts, [
            "Hello", "Hello world", "Hello there", "Hello", "Hello there", "Hello there!"
        ])
        XCTAssertTrue(fixture.events.finals.allSatisfy { !$0 })
        XCTAssertTrue(fixture.socket.azureCommits.isEmpty, "Incremental text does not wait for a client commit")
    }

    func testIntermediateOnlyTextAndUnicodeDeltasDoNotInventWordSeparators() {
        let fixture = AzureVoiceLiveFixture(model: streamingModel)
        fixture.start()
        fixture.becomeReady()
        intermediate("こんにちは", item: "a", socket: fixture.socket)
        fixture.socket.delta("お", item: "a")
        fixture.socket.delta("は", item: "a")
        intermediate("よう", item: "a", socket: fixture.socket)
        intermediate("ようございます", item: "a", socket: fixture.socket)
        fixture.socket.delta("ようございます", item: "a")
        XCTAssertEqual(fixture.events.texts, [
            "こんにちは", "お", "おは", "おはよう", "おはようございます"
        ])
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testAnEmptyIntermediateRetractsAProvisionalOnlyHypothesis() {
        let fixture = AzureVoiceLiveFixture(model: streamingModel)
        fixture.start()
        fixture.becomeReady()
        intermediate("provisional", item: "a", socket: fixture.socket)
        intermediate("", item: "a", socket: fixture.socket)
        XCTAssertEqual(fixture.events.texts, ["provisional", ""])
        XCTAssertEqual(fixture.events.finals, [false, false])
        let snapshot = fixture.client.transcriptSnapshot(captureDuration: 1)
        XCTAssertEqual(snapshot.confirmedText, "")
        XCTAssertEqual(snapshot.resolvedDisplayText, "", "Hosts can apply an authoritative empty display")
        XCTAssertFalse(snapshot.isTerminal)
    }

    func testLateIntermediatesCannotReviveCompletedOrFailedItems() {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.socket.completed("First.", item: "a")
        intermediate("stale", item: "a", socket: fixture.socket)
        intermediate("provisional", item: "b", socket: fixture.socket)
        fixture.socket.transcriptionFailed(item: "b", message: "Synthetic failure")
        intermediate("stale", item: "b", socket: fixture.socket)
        XCTAssertEqual(fixture.events.texts, ["First.", "First. provisional", "First."])
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testAReplacedRunCannotDeliverAnOldIntermediate() {
        let fixture = AzureVoiceLiveFixture(model: streamingModel)
        fixture.start()
        fixture.becomeReady()
        let old = fixture.socket
        intermediate("old", item: "a", socket: old)
        fixture.start()
        let current = fixture.factory.sockets[1]
        current.open()
        current.completeSend()
        current.acknowledge(sessionType: nil)
        intermediate("new", item: "a", socket: current)
        intermediate("stale", item: "a", socket: old)
        XCTAssertEqual(fixture.events.texts, ["old", "new"])
    }

    func testUnavailableStreamingBackendFailsWithoutSilentlyOpeningTheTurnBasedModel() {
        let fixture = AzureVoiceLiveFixture(model: streamingModel)
        fixture.start()
        fixture.socket.open()
        fixture.socket.completeSend()
        fixture.socket.azureError(code: "transcription_upstream_not_configured")
        XCTAssertEqual(fixture.events.errors.first as? AzureVoiceLiveError,
                       .sessionRejected(code: "transcription_upstream_not_configured"))
        XCTAssertTrue(fixture.events.errors.first?.localizedDescription.contains("resource region") == true)
        XCTAssertEqual(fixture.factory.sockets.count, 1)
        XCTAssertEqual(fixture.socket.cancels, 1)
        XCTAssertFalse(fixture.client.isSessionReady)
    }

    func testFinishWaitsForTheCompletedTranscriptRatherThanAcceptingAnIntermediate() async {
        let fixture = AzureVoiceLiveFixture(model: streamingModel)
        fixture.start()
        fixture.becomeReady()
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        fixture.socket.delta("Hello", item: "a")
        intermediate(" provisional", item: "a", socket: fixture.socket)
        let finish = fixture.finish()
        await fixture.waitForFinishers()
        fixture.completeSends(until: "input_audio_buffer.commit")
        fixture.socket.completeSend()
        fixture.socket.azureEmit(["type": "input_audio_buffer.committed"])
        XCTAssertEqual(fixture.client.pendingFinishCount, 1)
        XCTAssertEqual(fixture.socket.azureSessionUpdates.count, 1, "No unsupported post-audio session update")
        intermediate(" revised", item: "a", socket: fixture.socket)
        XCTAssertEqual(fixture.events.texts.last, "Hello provisional", "Finish withholds further callbacks")
        fixture.socket.azureEmit([
            "type": "conversation.item.input_audio_transcription.completed", "transcript": "Hello final."
        ])
        let result = await finish.value
        XCTAssertEqual(result, "Hello final.")
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testCommitAcknowledgementAloneCannotCompleteAnEmptyTranscription() async {
        let fixture = AzureVoiceLiveFixture(model: streamingModel)
        fixture.start()
        fixture.becomeReady()
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        let finish = fixture.finish()
        await fixture.waitForFinishers()
        fixture.completeSends(until: "input_audio_buffer.commit")
        fixture.socket.completeSend()
        fixture.socket.azureEmit(["type": "input_audio_buffer.committed"])
        XCTAssertEqual(fixture.client.pendingFinishCount, 1)
        fixture.clock.fire(5)
        let result = await finish.value
        XCTAssertNil(result)
        guard case .timedOut? = fixture.events.errors.first as? AzureSpeechError else {
            return XCTFail("Missing completion must produce the bounded timeout error")
        }
    }

    func testCompletionBeforeOurCommitAndMalformedCompletionAreNotSuccess() {
        for beforeCommit in [true, false] {
            let fixture = AzureVoiceLiveFixture(model: streamingModel)
            fixture.start()
            fixture.becomeReady()
            let event: [String: Any] = beforeCommit
                ? ["type": "conversation.item.input_audio_transcription.completed", "transcript": "Unsolicited"]
                : ["type": "conversation.item.input_audio_transcription.completed"]
            fixture.socket.azureEmit(event)
            guard case .invalidResponse? = fixture.events.errors.first as? AzureSpeechError else {
                return XCTFail("An unsolicited or malformed completion must be a protocol error")
            }
            XCTAssertTrue(fixture.events.texts.isEmpty)
        }
    }

    func testDedicatedItemFailureStopsTheRunAndKeepsTheLastDraftAsRecovery() {
        let fixture = AzureVoiceLiveFixture(model: streamingModel)
        fixture.start()
        fixture.becomeReady()
        intermediate("Recovery draft", item: "a", socket: fixture.socket)
        fixture.socket.transcriptionFailed(item: "a", message: "Synthetic failure")
        guard case .transcriptionFailed? = fixture.events.errors.first as? AzureSpeechError else {
            return XCTFail("A dedicated single-interval failure must be published immediately")
        }
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertEqual(fixture.events.texts, ["Recovery draft"])
        XCTAssertTrue(fixture.events.finals.allSatisfy { !$0 })
        XCTAssertEqual(fixture.socket.cancels, 1)
        XCTAssertEqual(fixture.client.transcriptSnapshot(captureDuration: 1).resolvedDisplayText, "Recovery draft")
    }

    private func intermediate(_ suffix: String, item: String, socket: AssemblyAITestSocket) {
        socket.azureEmit([
            "type": "conversation.item.input_audio_transcription.intermediate",
            "item_id": item, "intermediate": suffix
        ])
    }
}
