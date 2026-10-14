import Foundation
import SpeakCore
import SpeakDesktop
import XCTest

final class DesktopLiveProjectionTests: XCTestCase {
    func testPartialThenExplicitEmptyProjectionRetractsEvenWithAnEmptyCallback() {
        let client = DesktopProjectionTestClient()
        let session = DesktopLiveSession(client: client)
        session.start()
        client.emit("ignored", snapshot: StreamingTranscriptSnapshot(displayText: " Draft "))
        XCTAssertEqual(session.snapshot().text, "Draft")
        let revision = session.snapshot().revision
        client.emit("", snapshot: StreamingTranscriptSnapshot(displayText: ""))
        XCTAssertEqual(session.snapshot().text, "")
        XCTAssertEqual(session.snapshot().revision, revision + 1)
        client.emit("stale", snapshot: StreamingTranscriptSnapshot(confirmedText: ""))
        XCTAssertEqual(session.snapshot().revision, revision + 1)
    }

    func testWholeSessionFinalProjectionsReplaceRatherThanAppend() {
        let client = DesktopProjectionTestClient()
        let session = DesktopLiveSession(client: client)
        session.start()
        client.emit("First.", final: true, snapshot: StreamingTranscriptSnapshot(confirmedText: "First."))
        client.emit("Second.", final: true, snapshot: StreamingTranscriptSnapshot(confirmedText: "First. Second."))
        XCTAssertEqual(session.snapshot().text, "First. Second.")
        client.emit("corrected", final: true, snapshot: StreamingTranscriptSnapshot(displayText: "Revised."))
        XCTAssertEqual(session.snapshot().text, "Revised.")
    }

    func testLockedAndInterimProjectionComposesAndRetractsOnlyTheInterim() {
        let client = DesktopProjectionTestClient()
        let session = DesktopLiveSession(client: client)
        session.start()
        client.emit("ignored", snapshot: StreamingTranscriptSnapshot(confirmedText: " Locked. ", pendingInterim: "draft"))
        XCTAssertEqual(session.snapshot().text, "Locked. draft")
        client.emit("", snapshot: StreamingTranscriptSnapshot(confirmedText: "Locked.", pendingInterim: ""))
        XCTAssertEqual(session.snapshot().text, "Locked.")
        client.emit("", snapshot: StreamingTranscriptSnapshot(confirmedText: "Locked.", pendingInterim: "next"))
        XCTAssertEqual(session.snapshot().text, "Locked. next")
    }

    func testMetadataOnlyProjectionRetainsLegacySegmentAndEmptyInterimBehavior() {
        let client = DesktopProjectionTestClient()
        let session = DesktopLiveSession(client: client)
        session.start()
        let metadata = StreamingTranscriptSnapshot(confidence: 0.9)
        client.emit("Yes.", final: true, snapshot: metadata)
        client.emit("Yes.", final: true, snapshot: metadata)
        client.emit("Maybe", snapshot: metadata)
        XCTAssertEqual(session.snapshot().text, "Yes. Yes. Maybe")
        client.emit("", snapshot: metadata)
        XCTAssertEqual(session.snapshot().text, "Yes. Yes.")
    }

    func testHealthyFinishAdoptsTheAuthoritativeWholeSessionProjection() async {
        let client = DesktopProjectionTestClient()
        let session = DesktopLiveSession(client: client)
        session.start()
        client.emit("draft", snapshot: StreamingTranscriptSnapshot(displayText: "Visible draft"))
        client.finalText = "Trailing segment."
        client.finalProjection = StreamingTranscriptSnapshot(confirmedText: "Whole. Session.", isTerminal: true)
        let result = await session.finish()
        XCTAssertEqual(result.text, "Whole. Session.")
        XCTAssertEqual(result.phase, .finished)
        client.emit("late", snapshot: StreamingTranscriptSnapshot(displayText: "Late revision"))
        XCTAssertEqual(session.snapshot(), result)
    }

    func testHealthyEmptyConfirmedFinishRetractsAndMetadataOnlyFinishUsesReturnContract() async {
        for projection in [
            StreamingTranscriptSnapshot(confirmedText: "", isTerminal: true),
            StreamingTranscriptSnapshot(confidence: 0.9, isTerminal: true)
        ] {
            let client = DesktopProjectionTestClient()
            let session = DesktopLiveSession(client: client)
            session.start()
            client.emit("draft", snapshot: StreamingTranscriptSnapshot(displayText: "Unconfirmed"))
            client.finalProjection = projection
            let result = await session.finish()
            XCTAssertEqual(result.text, "")
            XCTAssertEqual(result.phase, .finished)
        }
    }

    func testFailureDuringFinishPreservesDraftDespiteLateAuthoritativeResult() async {
        let client = DesktopProjectionTestClient()
        let session = DesktopLiveSession(client: client)
        session.start()
        client.emit("draft", snapshot: StreamingTranscriptSnapshot(displayText: "Recovery draft"))
        client.onFinish = { [weak client] in client?.fail() }
        client.finalText = "Untrusted final"
        client.finalProjection = StreamingTranscriptSnapshot(confirmedText: "Untrusted projection", isTerminal: true)
        let result = await session.finish()
        XCTAssertEqual(result.phase, .failed)
        XCTAssertEqual(result.text, "Recovery draft")
        XCTAssertEqual(result.error, "Synthetic projection failure")
        client.emit("", snapshot: StreamingTranscriptSnapshot(displayText: ""))
        XCTAssertEqual(session.snapshot(), result)
    }

    func testLateProjectedFinishCannotMutateCancelledRecovery() async {
        let client = DesktopProjectionTestClient()
        let session = DesktopLiveSession(client: client)
        session.start()
        client.emit("draft", snapshot: StreamingTranscriptSnapshot(displayText: "Recovery"))
        client.deferFinish = true
        client.finalProjection = StreamingTranscriptSnapshot(confirmedText: "Late projection", isTerminal: true)
        let began = expectation(description: "Provider finish is pending")
        client.onFinish = { began.fulfill() }
        let finish = Task { await session.finish() }
        await fulfillment(of: [began], timeout: 2)
        let cancelled = session.cancel()
        client.completeFinish()
        let result = await finish.value
        XCTAssertEqual(result, cancelled)
        XCTAssertEqual(result.text, "Recovery")
    }

    func testCancelledOldSessionCannotUpdateANewSessionOrItsOwnRecovery() {
        let oldClient = DesktopProjectionTestClient()
        let oldSession = DesktopLiveSession(client: oldClient)
        oldSession.start()
        oldClient.emit("old", snapshot: StreamingTranscriptSnapshot(displayText: "Old recovery"))
        let cancelled = oldSession.cancel()
        let newClient = DesktopProjectionTestClient()
        let newSession = DesktopLiveSession(client: newClient)
        newSession.start()
        newClient.emit("new", snapshot: StreamingTranscriptSnapshot(displayText: "New recording"))
        oldClient.emit("", snapshot: StreamingTranscriptSnapshot(displayText: ""))
        oldClient.fail()
        XCTAssertEqual(oldSession.snapshot(), cancelled)
        XCTAssertEqual(newSession.snapshot().text, "New recording")
        XCTAssertNotEqual(oldSession.id, newSession.id)
    }

    func testDelayedProjectionReadCannotHoldStateLockOrOvertakeCancellation() {
        let client = DesktopProjectionTestClient()
        let session = DesktopLiveSession(client: client)
        session.start()
        client.emit("before", snapshot: StreamingTranscriptSnapshot(displayText: "Recovery"))
        let entered = expectation(description: "Provider projection read entered")
        let read = expectation(description: "Session snapshot is not blocked by provider")
        let delivered = expectation(description: "Delayed provider callback returned")
        let release = DispatchSemaphore(value: 0)
        client.onSnapshot = {
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
        }
        DispatchQueue.global().async {
            client.emit("late", snapshot: StreamingTranscriptSnapshot(displayText: "Late projection"))
            delivered.fulfill()
        }
        wait(for: [entered], timeout: 2)
        DispatchQueue.global().async {
            XCTAssertEqual(session.snapshot().text, "Recovery")
            read.fulfill()
        }
        wait(for: [read], timeout: 2)
        let cancelled = session.cancel()
        release.signal()
        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(session.snapshot(), cancelled)
    }

    func testSynchronousProjectedStartAndAudioCallbacksDoNotDeadlock() {
        let client = DesktopProjectionTestClient()
        let session = DesktopLiveSession(client: client)
        client.onStart = { [weak client] in
            client?.emit("", snapshot: StreamingTranscriptSnapshot(displayText: "Opening"))
        }
        client.onAudio = { [weak client] in
            client?.emit("", snapshot: StreamingTranscriptSnapshot(displayText: ""))
        }
        let completed = expectation(description: "Synchronous projected callbacks complete")
        DispatchQueue.global().async {
            session.start()
            session.sendAudio(Data([0, 0]))
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(session.snapshot().phase, .recording)
        XCTAssertEqual(session.snapshot().text, "")
    }

    func testActualAssemblyAISessionProjectsRevisedTurnsAndSilentFinalFold() async {
        let fixture = AssemblyAILiveFixture()
        let session = DesktopLiveSession(client: fixture.client)
        session.start()
        let socket = fixture.factory.sockets[0]
        socket.open()
        socket.begin()
        socket.emit(Self.turn("First.", order: 0))
        socket.emit(Self.turn("Second.", order: 1))
        XCTAssertEqual(session.snapshot().text, "First. Second.")
        socket.emit(Self.turn("Revised.", order: 1))
        XCTAssertEqual(session.snapshot().text, "First. Revised.")
        let forced = expectation(description: "Real client requests final endpoint")
        socket.onSend = {
            if case .text(let text) = $0, text.contains("ForceEndpoint") { forced.fulfill() }
        }
        let finish = Task { await session.finish() }
        await fulfillment(of: [forced], timeout: 2)
        socket.completeSend()
        socket.emit(Self.turn("Trailing.", order: 2))
        XCTAssertEqual(session.snapshot().text, "First. Revised.", "Finishing turn is folded without a callback")
        socket.completeSend()
        socket.emit(#"{"type":"Termination"}"#)
        let result = await finish.value
        XCTAssertEqual(result.phase, .finished)
        XCTAssertEqual(result.text, "First. Revised. Trailing.")
        XCTAssertNil(result.error)
    }

    private static func turn(_ text: String, order: Int) -> String {
        #"{"type":"Turn","transcript":"\#(text)","turn_order":\#(order),"end_of_turn":true,"turn_is_formatted":true}"#
    }
}
