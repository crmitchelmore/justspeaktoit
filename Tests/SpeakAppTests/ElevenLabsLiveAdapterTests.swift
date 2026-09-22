import Foundation
import SpeakCore
import XCTest
@testable import SpeakApp

final class ElevenLabsLiveAdapterTests: XCTestCase {
    func testExistingSessionInitializerAndCaptureFramingRemainAvailable() {
        let constructor: (String, String, Int, URLSession) -> ElevenLabsLiveTranscriber =
            ElevenLabsLiveTranscriber.init(apiKey:modelID:sampleRate:session:)
        let session = URLSession(configuration: .ephemeral)
        let adapter = constructor("test", "scribe_v2_realtime", 16_000, session)
        adapter.stop()
        session.invalidateAndCancel()
        XCTAssertEqual(ElevenLabsLiveTranscriber.minimumChunkBytes, 3_200)
        XCTAssertEqual(ElevenLabsLiveTranscriber.preferredChunkBytes, 3_200)
    }

    func testAudioUsesTheSharedClientWithoutReframingOrAnotherCommit() async {
        let client = ElevenLabsAdapterClient()
        let adapter = ElevenLabsLiveTranscriber(client: client)
        adapter.start(onTranscript: { _, _ in }, onError: { _ in })
        let audio = Data([1, 0, 2, 0])
        adapter.sendAudio(audio)
        _ = await adapter.finishAndWait()
        XCTAssertEqual(client.audio, [audio])
        XCTAssertEqual(client.finishes, 1)
        XCTAssertEqual(client.stops, 0)
    }

    func testWholeFinishReplacesPreviouslyDeliveredStandaloneSegmentsOnce() async {
        let client = ElevenLabsAdapterClient()
        let adapter = ElevenLabsLiveTranscriber(client: client)
        adapter.start(onTranscript: { _, _ in }, onError: { _ in })
        client.callbacks[0].transcript("Yes.", true)
        client.callbacks[0].transcript("Yes.", true)
        client.callbacks[0].transcript("trailing draft", false)
        client.finishResult = "Yes. Yes. Trailing."
        let result = await adapter.finishAndWait()
        XCTAssertEqual(result.text, "Yes. Yes. Trailing.")
        XCTAssertNil(result.error)
        XCTAssertEqual(adapter.snapshot.text, result.text)
    }

    func testNilWholeFinishKeepsConfirmedTextAndDraft() async {
        let client = ElevenLabsAdapterClient()
        let adapter = ElevenLabsLiveTranscriber(client: client)
        adapter.start(onTranscript: { _, _ in }, onError: { _ in })
        client.callbacks[0].transcript("Confirmed.", true)
        client.callbacks[0].transcript("draft", false)
        let result = await adapter.finishAndWait()
        XCTAssertEqual(result.text, "Confirmed. draft")
        XCTAssertNil(result.error)
    }

    func testFailureIsCapturedBeforeQueuedCallbackDeliveryAndRemainsInFinishResult() async {
        let client = ElevenLabsAdapterClient()
        let adapter = ElevenLabsLiveTranscriber(client: client)
        var queuedErrors: [Error] = []
        adapter.start(onTranscript: { _, _ in }, onError: { error in
            XCTAssertTrue(adapter.snapshot.error is AdapterFailure, "Capture precedes UI callback delivery")
            queuedErrors.append(error)
        })
        client.callbacks[0].transcript("Confirmed.", true)
        client.callbacks[0].transcript("draft", false)
        client.finishResult = "Confirmed."
        client.onFinish = { client.callbacks[0].error(AdapterFailure()) }
        let result = await adapter.finishAndWait()
        XCTAssertTrue(result.error is AdapterFailure)
        XCTAssertEqual(result.text, "Confirmed. draft", "Failure must not drop a newer draft")
        XCTAssertEqual(result.confirmedText, "Confirmed.")
        XCTAssertEqual(queuedErrors.count, 1)
        XCTAssertTrue(adapter.takeFailureForReporting() is AdapterFailure)
        XCTAssertNil(adapter.takeFailureForReporting(), "Stop and queued UI delivery report one error")
        XCTAssertTrue(adapter.snapshot.error is AdapterFailure, "Reporting must never convert failure into success")
    }

    func testReentrantStopFromFailureCallbackCannotEraseTheFinishSnapshot() async {
        let client = ElevenLabsAdapterClient()
        let adapter = ElevenLabsLiveTranscriber(client: client)
        adapter.start(onTranscript: { _, _ in }, onError: { _ in adapter.stop() })
        client.callbacks[0].transcript("Saved.", true)
        client.finishResult = "Saved."
        client.onFinish = { client.callbacks[0].error(AdapterFailure()) }
        let result = await adapter.finishAndWait()
        XCTAssertEqual(result.text, "Saved.")
        XCTAssertTrue(result.error is AdapterFailure)
        XCTAssertEqual(client.stops, 1)
    }

    func testSupersededAndFinishedCallbacksCannotMutateTheCurrentSnapshot() async {
        let client = ElevenLabsAdapterClient()
        let adapter = ElevenLabsLiveTranscriber(client: client)
        var delivered: [String] = []
        adapter.start(onTranscript: { text, _ in delivered.append(text) }, onError: { _ in XCTFail("Old failure") })
        client.callbacks[0].transcript("Old.", true)
        adapter.start(onTranscript: { text, _ in delivered.append(text) }, onError: { _ in XCTFail("Old failure") })
        client.callbacks[0].transcript("Stale.", true)
        client.callbacks[0].error(AdapterFailure())
        client.callbacks[1].transcript("Current.", true)
        let result = await adapter.finishAndWait()
        client.callbacks[1].transcript("After finish.", true)
        XCTAssertEqual(result.text, "Current.")
        XCTAssertEqual(adapter.snapshot.text, "Current.")
        XCTAssertEqual(delivered, ["Old.", "Current."])
        XCTAssertNil(result.error)
    }

    func testFailedFinishKeepsVisibleDraftAndLateRevisedConfirmedTextSeparately() async {
        let client = ElevenLabsAdapterClient()
        let adapter = ElevenLabsLiveTranscriber(client: client)
        adapter.start(onTranscript: { _, _ in }, onError: { _ in })
        client.callbacks[0].transcript("hello", true)
        client.callbacks[0].transcript("trailing words", false)
        client.finishResult = "Hello."
        client.onFinish = { client.callbacks[0].error(AdapterFailure()) }
        let result = await adapter.finishAndWait()
        XCTAssertEqual(result.text, "hello trailing words")
        XCTAssertEqual(result.confirmedText, "Hello.")
        XCTAssertTrue(result.error is AdapterFailure)
    }

    func testExplicitCancellationKeepsDraftWhenTheClientReturnsConfirmedText() async {
        let client = ElevenLabsAdapterClient()
        let adapter = ElevenLabsLiveTranscriber(client: client)
        adapter.start(onTranscript: { _, _ in }, onError: { _ in })
        client.callbacks[0].transcript("Hello", true)
        client.callbacks[0].transcript("trailing words", false)
        client.finishResult = "Hello."
        client.onFinish = { adapter.stop() }
        let result = await adapter.finishAndWait()
        XCTAssertEqual(result.text, "Hello trailing words")
        XCTAssertEqual(result.confirmedText, "Hello.")
        XCTAssertTrue(result.error is CancellationError)
    }

    func testTaskCancellationWithoutAnErrorCallbackKeepsTheVisibleDraft() async {
        let client = ElevenLabsAdapterClient()
        let adapter = ElevenLabsLiveTranscriber(client: client)
        adapter.start(onTranscript: { _, _ in }, onError: { _ in })
        client.callbacks[0].transcript("Hello", true)
        client.callbacks[0].transcript("trailing words", false)
        client.finishResult = "Hello"
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await adapter.finishAndWait()
        }
        let result = await task.value
        XCTAssertEqual(result.text, "Hello trailing words")
        XCTAssertEqual(result.confirmedText, "Hello")
        XCTAssertTrue(result.error is CancellationError)
    }

    func testHealthyFinalPunctuationRevisionIsAuthoritative() async {
        let client = ElevenLabsAdapterClient()
        let adapter = ElevenLabsLiveTranscriber(client: client)
        adapter.start(onTranscript: { _, _ in }, onError: { _ in })
        client.callbacks[0].transcript("hello", true)
        client.callbacks[0].transcript("stale guess", false)
        client.finishResult = "Hello!"
        let result = await adapter.finishAndWait()
        XCTAssertEqual(result.text, "Hello!")
        XCTAssertEqual(result.confirmedText, "Hello!")
        XCTAssertNil(result.error)
    }

    func testEmptyFinishKeepsAnEmptyTranscript() async {
        let adapter = ElevenLabsLiveTranscriber(client: ElevenLabsAdapterClient())
        adapter.start(onTranscript: { _, _ in }, onError: { _ in XCTFail("Unexpected error") })
        let result = await adapter.finishAndWait()
        XCTAssertTrue(result.text.isEmpty)
        XCTAssertNil(result.error)
    }
}

private struct AdapterFailure: Error {}

private final class ElevenLabsAdapterClient: FinalizingStreamingTranscriptionClient {
    struct Callbacks {
        let transcript: (String, Bool) -> Void
        let error: (Error) -> Void
    }
    let finalShape: TranscriptFinalShape = .standaloneSegments
    var callbacks: [Callbacks] = []
    var audio: [Data] = []
    var finishes = 0
    var stops = 0
    var finishResult: String?
    var onFinish: (() -> Void)?

    func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        callbacks.append(Callbacks(transcript: onTranscript, error: onError))
    }
    func sendAudio(_ data: Data) { audio.append(data) }
    func stop() { stops += 1 }
    func finishAndWait() async -> String? {
        finishes += 1
        onFinish?()
        return finishResult
    }
}
