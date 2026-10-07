import Foundation
import XCTest
@testable import SpeakApp

final class SonioxControllerRecoveryTests: XCTestCase {
    func testFailedFinishPreservesDraftWhenOnlyConfirmedPrefixIsReturned() async {
        let client = SonioxControllerFakeClient()
        let adapter = SonioxControllerClient(client: client)
        adapter.start(onTranscript: { _, _ in }, onError: { _ in })
        client.transcript?("Hello", true)
        client.transcript?("Hello trailing words", false)
        client.result = "Hello"
        client.onFinish = { client.error?(URLError(.timedOut)) }

        let snapshot = await adapter.finishAndWait()

        XCTAssertEqual(snapshot.text, "Hello trailing words")
        XCTAssertEqual(snapshot.confirmedText, "Hello")
        XCTAssertEqual((snapshot.error as? URLError)?.code, .timedOut)
    }

    func testCancelledFinishPreservesDraftWithoutLabellingItConfirmed() async {
        let client = SonioxControllerFakeClient()
        let adapter = SonioxControllerClient(client: client)
        adapter.start(onTranscript: { _, _ in }, onError: { _ in })
        client.transcript?("Hello", true)
        client.transcript?("Hello trailing words", false)
        client.result = "Hello"
        client.onFinish = { adapter.cancel() }

        let snapshot = await adapter.finishAndWait()

        XCTAssertEqual(snapshot.text, "Hello trailing words")
        XCTAssertEqual(snapshot.confirmedText, "Hello")
        XCTAssertNil(snapshot.error)
    }

    func testFailureRetainsLateConfirmedRevisionSeparatelyFromVisibleDraft() async {
        let client = SonioxControllerFakeClient()
        let adapter = SonioxControllerClient(client: client)
        adapter.start(onTranscript: { _, _ in }, onError: { _ in adapter.cancel() })
        client.transcript?("hello", true)
        client.transcript?("hello trailing draft", false)
        // A final received during finish can revise earlier punctuation and
        // contain additional confirmed words without completing the stream.
        client.result = "Hello, new confirmed words."
        client.onFinish = { client.error?(URLError(.networkConnectionLost)) }

        let snapshot = await adapter.finishAndWait()

        XCTAssertEqual(snapshot.text, "hello trailing draft")
        XCTAssertEqual(snapshot.confirmedText, "Hello, new confirmed words.")
        XCTAssertNotNil(snapshot.error)
    }

    func testTaskCancellationPreservesDraftWithoutExplicitAdapterCancellation() async {
        let client = SonioxControllerFakeClient()
        let adapter = SonioxControllerClient(client: client)
        adapter.start(onTranscript: { _, _ in }, onError: { _ in })
        client.transcript?("Hello", true)
        client.transcript?("Hello trailing words", false)
        client.result = "Hello"
        let finishing = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await adapter.finishAndWait()
        }

        let snapshot = await finishing.value

        XCTAssertEqual(snapshot.text, "Hello trailing words")
        XCTAssertEqual(snapshot.confirmedText, "Hello")
        XCTAssertNil(snapshot.error)
    }

    func testSuccessfulFinalIsAuthoritativeEvenWhenItShortensOrRevisesTheDraft() async {
        let client = SonioxControllerFakeClient()
        let adapter = SonioxControllerClient(client: client)
        adapter.start(onTranscript: { _, _ in }, onError: { _ in })
        client.transcript?("hello", true)
        client.transcript?("hello trailing words", false)
        client.result = "Hello!"

        let snapshot = await adapter.finishAndWait()

        XCTAssertEqual(snapshot.text, "Hello!")
        XCTAssertEqual(snapshot.confirmedText, "Hello!")
        XCTAssertNil(snapshot.error)
    }
}
