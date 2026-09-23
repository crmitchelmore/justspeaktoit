import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

/// Outcomes, credentials, failures, cleanup reporting and admission.
final class DeepgramVoiceOutputTests: DeepgramVoiceOutputTestCase {
    func testWhitespaceText_ReturnsNothingToSpeakWithoutCredentialRequestFileOrPlayback() async throws {
        let probe = VoiceOutputProbe(), credential = CredentialProbe()
        let output = DeepgramVoiceOutput(session: session, playback: probe.playback)
        let erase = PronunciationEntry(word: "\\bum\\b", pronunciation: "", replacement: " ", isRegex: true)
        let cases: [(String, [PronunciationEntry])] = [("", []), (" \n\t ", []), ("um um", [erase])]
        for (text, entries) in cases {
            let request = try DeepgramSpeechRequest(text: text, modelID: nil, voiceID: nil, pronunciation: entries)
            let outcome = try await output.speak(request) { try await credential.supply() }
            XCTAssertEqual(outcome, .nothingToSpeak)
        }
        XCTAssertEqual(credential.count, 0)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
        XCTAssertTrue(probe.events.isEmpty)
    }

    func testSpokenRequest_StoresCanonicalAudioPlaysItAndDiscardsItAfterPlayback() async throws {
        respondWithAudio()
        let probe = VoiceOutputProbe(play: .render(0.1)), credential = CredentialProbe(" fixture-key\n")
        let api = PronunciationEntry(word: "API", pronunciation: "A P I", replacement: "A P I")
        let request = try DeepgramSpeechRequest(
            text: "Hello API", modelID: "flux", voiceID: "deepgram/flux-hannah-en", pronunciation: [api]
        )
        let outcome = try await DeepgramVoiceOutput(session: session, playback: probe.playback)
            .speak(request) { try await credential.supply() }

        guard case let .spoken(receipt) = outcome else { return XCTFail("Expected speech, got \(outcome)") }
        XCTAssertEqual(receipt.voice.id, "flux-hannah-en")
        XCTAssertEqual(receipt.characterCount, "Hello A P I".unicodeScalars.count)
        XCTAssertEqual(receipt.audioDuration, 0.1, accuracy: 1e-12)
        XCTAssertEqual(receipt.playedDuration, 0.1)
        XCTAssertTrue(receipt.audioFileRemoved)
        XCTAssertEqual(probe.events, ["store 1", "play 1", "released 1", "discard 1"])
        let canonical = DeepgramSpeechFixture.canonicalWAV(pcm: DeepgramSpeechFixture.pcm(frames: 2_400))
        XCTAssertEqual(probe.storedAudio, [canonical])
        XCTAssertEqual(credential.count, 1)
        let sent = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(sent.url?.path, "/v2/speak")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Token fixture-key")
    }

    func testMissingUnsafeOrFailingCredential_StopsBeforeTheNetwork() async throws {
        respondWithAudio()
        let probe = VoiceOutputProbe()
        let output = DeepgramVoiceOutput(session: session, playback: probe.playback)
        let request = try DeepgramSpeechRequest(text: "Hello", modelID: nil, voiceID: nil)
        let cases: [(String, DeepgramSpeechError)] = [
            ("", .missingCredential), ("  \n", .missingCredential), ("two words", .invalidCredential),
            ("key\r\nX-Injected: 1", .invalidCredential), ("k\u{E9}y", .invalidCredential),
            (String(repeating: "k", count: 4_097), .invalidCredential)
        ]
        for (value, expected) in cases {
            do {
                _ = try await output.speak(request) { value }
                XCTFail("Credential \(expected) was accepted")
            } catch { XCTAssertEqual(error as? DeepgramSpeechError, expected) }
        }
        do {
            _ = try await output.speak(request) { throw CredentialLookupFailure() }
            XCTFail("The host's lookup failure was hidden")
        } catch { XCTAssertEqual(error as? CredentialLookupFailure, CredentialLookupFailure()) }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
        XCTAssertTrue(probe.events.isEmpty)
    }

    func testProviderFailure_StopsBeforeStoringOrPlaying() async throws {
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0, status: 401), Data()) }
        let probe = VoiceOutputProbe()
        do {
            _ = try await speak(probe)
            XCTFail("An unauthorised request reported speech")
        } catch { XCTAssertEqual(error as? DeepgramSpeechError, .unauthorized(statusCode: 401)) }
        XCTAssertTrue(probe.events.isEmpty)
    }

    func testPlaybackFailure_IsReportedAfterTheFileIsDiscarded() async throws {
        respondWithAudio()
        let probe = VoiceOutputProbe(play: .fail)
        do {
            _ = try await speak(probe)
            XCTFail("A failed playback reported speech")
        } catch { XCTAssertEqual(error as? VoiceOutputProbe.PlayerFailure, VoiceOutputProbe.PlayerFailure()) }
        XCTAssertEqual(probe.events, ["store 1", "play 1", "released 1", "discard 1"])
    }

    func testStoreFailure_NeitherPlaysNorDiscardsAnotherFile() async throws {
        respondWithAudio()
        let probe = VoiceOutputProbe(failStore: true)
        do {
            _ = try await speak(probe)
            XCTFail("A failed store reported speech")
        } catch { XCTAssertEqual(error as? VoiceOutputProbe.StoreFailure, VoiceOutputProbe.StoreFailure()) }
        XCTAssertEqual(probe.events, ["store failed"])
    }

    func testPlaybackThatRendersNothing_IsNotReportedAsSpeech() async throws {
        respondWithAudio()
        for rendered in [0, -1, TimeInterval.nan] {
            let probe = VoiceOutputProbe(play: .render(rendered))
            do {
                _ = try await speak(probe)
                XCTFail("\(rendered) seconds were reported as speech")
            } catch { XCTAssertEqual(error as? DeepgramVoiceOutput.Failure, .noAudioPlayed) }
            XCTAssertEqual(probe.events, ["store 1", "play 1", "released 1", "discard 1"])
        }
    }

    func testRemovalFailureAfterSpeech_IsReportedInTheReceiptNotHidden() async throws {
        respondWithAudio()
        let probe = VoiceOutputProbe(play: .render(0.1), discardFails: true)
        guard case let .spoken(receipt) = try await speak(probe) else { return XCTFail("Expected speech") }
        XCTAssertFalse(receipt.audioFileRemoved, "A file the platform still owns was reported removed")
        XCTAssertEqual(probe.events, ["store 1", "play 1", "released 1", "discard 1"])
    }

    func testRemovalFailureAfterFailedPlayback_KeepsThePrimaryErrorAndDiscardsOnce() async throws {
        respondWithAudio()
        let probe = VoiceOutputProbe(play: .fail, discardFails: true)
        do {
            _ = try await speak(probe)
            XCTFail("A failed playback reported speech")
        } catch { XCTAssertEqual(error as? VoiceOutputProbe.PlayerFailure, VoiceOutputProbe.PlayerFailure()) }
        XCTAssertEqual(probe.events, ["store 1", "play 1", "released 1", "discard 1"])
    }

    func testSecondRequestWhileSpeaking_IsRefusedWithoutCredentialOrNetwork() async throws {
        respondWithAudio()
        let probe = VoiceOutputProbe(play: .untilReleased)
        let output = DeepgramVoiceOutput(session: session, playback: probe.playback)
        let request = try DeepgramSpeechRequest(text: "First", modelID: nil, voiceID: nil)
        let first = Task { try await output.speak(request) { "fixture-key" } }
        await eventually { probe.events.contains("play 1") }

        let refused = CredentialProbe()
        do {
            _ = try await output.speak(request) { try await refused.supply() }
            XCTFail("A concurrent request was admitted")
        } catch { XCTAssertEqual(error as? DeepgramVoiceOutput.Failure, .busy) }
        XCTAssertEqual(refused.count, 0)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)

        probe.releasePlayback()
        guard case .spoken = try await first.value else { return XCTFail("The first request did not speak") }
        guard case .spoken = try await output.speak(request, credential: { "fixture-key" }) else {
            return XCTFail("Admission was not released")
        }
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 2)
    }
}

/// Cancellation at every stage wins over speech and never leaks the file.
final class DeepgramVoiceOutputCancellationTests: DeepgramVoiceOutputTestCase {
    func testCancellationBeforeTheRequest_NeverReadsTheCredential() async throws {
        respondWithAudio()
        let probe = VoiceOutputProbe(), credential = CredentialProbe()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await self.speak(probe, credential: credential)
        }
        await assertCancelled(task)
        XCTAssertEqual(credential.count, 0)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
        XCTAssertTrue(probe.events.isEmpty)
    }

    /// `speak(_:credential:)` hands the pronounced utterance to exactly this
    /// stage, so a cancellation observed during pronunciation stops here.
    func testCancellationObservedAfterPronunciation_NeverReadsTheCredential() async throws {
        respondWithAudio()
        let probe = VoiceOutputProbe(), credential = CredentialProbe()
        let output = DeepgramVoiceOutput(session: session, playback: probe.playback)
        let request = try DeepgramSpeechRequest(text: "Hello API", modelID: nil, voiceID: nil)
        let utterance = try XCTUnwrap(try DeepgramSpeechSynthesizer(session: session).utterance(for: request))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await output.speak(utterance) { try await credential.supply() }
        }
        await assertCancelled(task)
        XCTAssertEqual(credential.count, 0)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
        XCTAssertTrue(probe.events.isEmpty)
    }

    func testCancellationWhileReadingTheCredential_SendsNoRequest() async throws {
        respondWithAudio()
        let probe = VoiceOutputProbe(), credential = CredentialProbe(holdUntilReleased: true)
        let task = Task { try await self.speak(probe, credential: credential) }
        await eventually { credential.count == 1 }
        task.cancel()
        credential.release()
        await assertCancelled(task)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
        XCTAssertTrue(probe.events.isEmpty)
    }

    func testCancellationDuringTheExchange_StopsTheTransferAndStoresNothing() async throws {
        let started = expectation(description: "Synthesis started")
        let stopped = expectation(description: "Synthesis stopped")
        StubURLProtocol.onStartLoading = { started.fulfill() }
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        StubURLProtocol.handler = { _ in .hang }
        let probe = VoiceOutputProbe()
        let task = Task { try await self.speak(probe) }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        await assertCancelled(task)
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertTrue(probe.events.isEmpty)
    }

    func testCancellationAfterTheResponse_DiscardsTheFileWithoutPlaying() async throws {
        respondWithAudio()
        let probe = VoiceOutputProbe(cancelDuringStore: true)
        await assertCancelled(Task { try await self.speak(probe) })
        XCTAssertEqual(probe.events, ["store 1", "discard 1"])
    }

    func testCancellationDuringPlayback_DiscardsOnlyAfterThePlayerReleasesTheFile() async throws {
        respondWithAudio()
        let probe = VoiceOutputProbe(play: .untilCancelled)
        let task = Task { try await self.speak(probe) }
        await eventually { probe.events.contains("play 1") }
        task.cancel()
        await assertCancelled(task)
        XCTAssertEqual(probe.events, ["store 1", "play 1", "released 1", "discard 1"])
    }

    /// The player returns a positive duration after cancellation arrived at its
    /// completion boundary: cancellation still wins and the file is discarded
    /// exactly once.
    func testCancellationAtThePlayerCompletionBoundary_WinsOverRenderedAudio() async throws {
        respondWithAudio()
        let probe = VoiceOutputProbe(play: .cancelThenRender(0.1))
        await assertCancelled(Task { try await self.speak(probe) })
        XCTAssertEqual(probe.events, ["store 1", "play 1", "released 1", "discard 1"])
    }
}
