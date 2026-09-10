#if IOS_KEYBOARD_FEATURE
import Foundation
import SpeakCore
import XCTest

/// The extension side of issue #1004: `KeyboardHandoffController` driving a
/// real `UITextDocumentProxy`-shaped surface from the pure marked-text policy.
///
/// `KeyboardMarkedTextTests` in SpeakCoreTests proves the decisions; these
/// prove the wiring — that the decisions actually reach the proxy, that a
/// completed transcript arrives exactly once by exactly one route, and that
/// nothing provisional survives a dismissal or a cancellation.
@MainActor
final class KeyboardMarkedTextStreamingTests: XCTestCase {
    /// Records what the host would have seen.
    private final class Proxy {
        private(set) var inserted: [String] = []
        private(set) var marked: [String] = []
        private(set) var unmarks = 0
        /// The text actually standing in the field: committed insertions plus
        /// whatever is currently marked.
        private(set) var committed = ""
        private var outstanding = ""

        func insertText(_ text: String) {
            inserted.append(text)
            committed += text
        }

        func setMarkedText(_ text: String) {
            marked.append(text)
            outstanding = text
        }

        func unmarkText() {
            unmarks += 1
            committed += outstanding
            outstanding = ""
        }

        var visible: String { committed + outstanding }
    }

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var app: KeyboardHandoffStore!
    private var ext: KeyboardHandoffStore!
    private var instantStore: KeyboardInstantDictationStore!
    private let document = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "KeyboardMarkedTextStreamingTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        app = KeyboardHandoffStore(defaults: defaults, role: .containingApp)
        ext = KeyboardHandoffStore(defaults: defaults, role: .keyboardExtension)
        instantStore = KeyboardInstantDictationStore(defaults: defaults)
        _ = instantStore.start(enabling: true)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    private func makeController(
        proxy: Proxy,
        streamsMarkedText: Bool,
        isSecureField: Bool = false
    ) throws -> KeyboardHandoffController {
        // The request exists before the keyboard appears, which is what
        // `activate` recovers from the shared record.
        _ = try ext.createRequest(targetDocumentIdentifier: document)
        let controller = KeyboardHandoffController(store: ext, instantSessionStore: instantStore)
        controller.activate(
            documentIdentifier: document,
            profile: KeyboardProfileSelection.directOnly.selectedProfile,
            autoStart: false,
            streamsMarkedText: streamsMarkedText,
            isSecureField: isSecureField,
            insertText: proxy.insertText,
            setMarkedText: proxy.setMarkedText,
            unmarkText: proxy.unmarkText
        )
        return controller
    }

    private func requestID() throws -> UUID {
        try XCTUnwrap(ext.activeRecord()?.requestID)
    }

    func testInterims_appearInTheFieldAndTheFinalTranscriptReplacesThemInPlace() throws {
        let proxy = Proxy()
        let controller = try makeController(proxy: proxy, streamsMarkedText: true)
        let request = try requestID()

        _ = try app.markRecording(requestID: request)
        _ = try app.updateInterim(requestID: request, transcript: "hello")
        controller.refresh()
        XCTAssertEqual(proxy.marked, ["hello"])
        XCTAssertEqual(proxy.visible, "hello")

        _ = try app.updateInterim(requestID: request, transcript: "hello there")
        controller.refresh()
        XCTAssertEqual(proxy.marked, ["hello", "hello there"])

        _ = try app.markTranscribing(requestID: request)
        _ = try app.complete(requestID: request, transcript: "Hello there.")
        controller.refresh()

        XCTAssertEqual(controller.presentation, .inserted)
        XCTAssertEqual(proxy.visible, "Hello there.")
        // Exactly one route delivered the words.
        XCTAssertEqual(proxy.inserted, [], "streaming must finalise, never also insert")
        XCTAssertEqual(proxy.unmarks, 1)
    }

    func testASecureField_isNeverStreamedIntoAndStillReceivesTheTranscript() throws {
        let proxy = Proxy()
        let controller = try makeController(
            proxy: proxy,
            streamsMarkedText: true,
            isSecureField: true
        )
        let request = try requestID()

        _ = try app.markRecording(requestID: request)
        _ = try app.updateInterim(requestID: request, transcript: "hunter2")
        controller.refresh()
        XCTAssertEqual(proxy.marked, [], "a secure field is never marked into")

        _ = try app.markTranscribing(requestID: request)
        _ = try app.complete(requestID: request, transcript: "hunter2")
        controller.refresh()
        XCTAssertEqual(proxy.inserted, ["hunter2"])
        XCTAssertEqual(proxy.unmarks, 0)
    }

    func testStreamingOff_behavesExactlyAsItDidBeforeTheFeature() throws {
        let proxy = Proxy()
        let controller = try makeController(proxy: proxy, streamsMarkedText: false)
        let request = try requestID()

        _ = try app.markRecording(requestID: request)
        _ = try app.updateInterim(requestID: request, transcript: "hello")
        controller.refresh()
        XCTAssertEqual(proxy.marked, [])
        XCTAssertEqual(controller.liveTranscript, "hello", "the strip still mirrors interims")

        _ = try app.markTranscribing(requestID: request)
        _ = try app.complete(requestID: request, transcript: "Hello.")
        controller.refresh()
        XCTAssertEqual(proxy.inserted, ["Hello."])
    }

    func testDismissalMidStream_leavesNothingProvisionalInTheField() throws {
        let proxy = Proxy()
        let controller = try makeController(proxy: proxy, streamsMarkedText: true)
        let request = try requestID()

        _ = try app.markRecording(requestID: request)
        _ = try app.updateInterim(requestID: request, transcript: "half a sentence")
        controller.refresh()
        XCTAssertEqual(proxy.visible, "half a sentence")

        controller.deactivate()
        XCTAssertEqual(proxy.visible, "", "the field must not keep provisional text")
        XCTAssertEqual(proxy.marked.last, "")
        XCTAssertEqual(proxy.unmarks, 1)
    }

    func testDismissalWhileFinishing_thenReturn_stillDeliversTheTranscriptOnce() throws {
        // #1030's guarantee, with streaming on: the provisional text goes, the
        // request survives, and the transcript arrives as a plain insertion.
        let proxy = Proxy()
        let controller = try makeController(proxy: proxy, streamsMarkedText: true)
        let request = try requestID()

        _ = try app.markRecording(requestID: request)
        _ = try app.updateInterim(requestID: request, transcript: "half a sentence")
        controller.refresh()
        _ = try ext.requestFinish(requestID: request)
        _ = try app.markTranscribing(requestID: request)

        controller.deactivate()
        XCTAssertEqual(proxy.visible, "")

        _ = try app.complete(requestID: request, transcript: "Half a sentence.")
        controller.activate(
            documentIdentifier: document,
            profile: KeyboardProfileSelection.directOnly.selectedProfile,
            autoStart: false,
            streamsMarkedText: true,
            isSecureField: false,
            insertText: proxy.insertText,
            setMarkedText: proxy.setMarkedText,
            unmarkText: proxy.unmarkText
        )
        XCTAssertEqual(controller.presentation, .inserted)
        XCTAssertEqual(proxy.inserted, ["Half a sentence."])
        XCTAssertEqual(proxy.visible, "Half a sentence.")
    }

    func testCancellation_takesTheProvisionalTextBackOut() throws {
        let proxy = Proxy()
        let controller = try makeController(proxy: proxy, streamsMarkedText: true)
        let request = try requestID()

        _ = try app.markRecording(requestID: request)
        _ = try app.updateInterim(requestID: request, transcript: "never mind")
        controller.refresh()
        XCTAssertEqual(proxy.visible, "never mind")

        controller.cancel()
        XCTAssertEqual(controller.presentation, .cancelled)
        XCTAssertEqual(proxy.visible, "")
    }

    func testAFailedRun_takesTheProvisionalTextBackOut() throws {
        let proxy = Proxy()
        let controller = try makeController(proxy: proxy, streamsMarkedText: true)
        let request = try requestID()

        _ = try app.markRecording(requestID: request)
        _ = try app.updateInterim(requestID: request, transcript: "half a sentence")
        controller.refresh()

        _ = try app.fail(requestID: request, code: .recordingUnavailable)
        controller.refresh()
        XCTAssertEqual(controller.presentation, .error(.recordingUnavailable))
        XCTAssertEqual(proxy.visible, "")
    }

    func testMovingTheCaret_clearsTheStreamAndFallsBackToOneInsertion() throws {
        let proxy = Proxy()
        let controller = try makeController(proxy: proxy, streamsMarkedText: true)
        let request = try requestID()

        _ = try app.markRecording(requestID: request)
        _ = try app.updateInterim(requestID: request, transcript: "hello")
        controller.refresh()
        // The keyboard's own write echoes back as a selection change first;
        // that one is expected and must not abandon the stream.
        controller.updateDocumentContext(documentIdentifier: document, selectionChanged: true)
        XCTAssertEqual(proxy.visible, "hello")

        // A second, unexplained selection change is the user moving the caret.
        controller.updateDocumentContext(documentIdentifier: document, selectionChanged: true)
        XCTAssertEqual(proxy.visible, "", "provisional text is withdrawn")

        _ = try app.updateInterim(requestID: request, transcript: "hello there")
        controller.refresh()
        XCTAssertEqual(proxy.visible, "", "streaming does not resume after a caret move")

        _ = try app.markTranscribing(requestID: request)
        _ = try app.complete(requestID: request, transcript: "Hello there.")
        controller.refresh()
        XCTAssertEqual(proxy.inserted, ["Hello there."])
        XCTAssertEqual(proxy.visible, "Hello there.")
    }
}
#endif
