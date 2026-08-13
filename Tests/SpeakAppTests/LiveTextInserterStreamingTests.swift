import ApplicationServices
import Foundation
import XCTest

@testable import SpeakApp

/// In-memory stand-in for a target text field, modelling the accessibility
/// contract the ranged streaming path depends on: a value plus a selection,
/// where writing selected text replaces the selected range and leaves a caret
/// after the inserted text.
private final class FakeStreamingTextField: StreamingTextField {
    var value: String
    var selection: CFRange
    var valueIsReadable = true
    var selectedRangeIsReadable = true
    var setSelectedRangeResult: AXError = .success
    var setSelectedTextResult: AXError = .success

    /// The range that was selected at the moment each replacement was attempted,
    /// with the text it tried to write. One entry per attempted AX write.
    private(set) var selectedTextWrites: [(range: CFRange, text: String)] = []
    private(set) var selectedRangeWrites: [CFRange] = []

    init(value: String = "", selection: CFRange = CFRange(location: 0, length: 0)) {
        self.value = value
        self.selection = selection
    }

    func readValue() -> String? {
        self.valueIsReadable ? self.value : nil
    }

    func readSelectedRange() -> CFRange? {
        self.selectedRangeIsReadable ? self.selection : nil
    }

    func setSelectedRange(_ range: CFRange) -> AXError {
        self.selectedRangeWrites.append(range)
        guard self.setSelectedRangeResult == .success else { return self.setSelectedRangeResult }
        self.selection = range
        return .success
    }

    func setSelectedText(_ text: String) -> AXError {
        self.selectedTextWrites.append((self.selection, text))
        guard self.setSelectedTextResult == .success else { return self.setSelectedTextResult }
        let current = self.value as NSString
        guard self.selection.location >= 0, self.selection.length >= 0,
              self.selection.location + self.selection.length <= current.length
        else { return .failure }
        self.value = current.replacingCharacters(
            in: NSRange(location: self.selection.location, length: self.selection.length),
            with: text
        )
        self.selection = CFRange(location: self.selection.location + text.utf16.count, length: 0)
        return .success
    }
}

/// Orchestration-level coverage of ranged streaming insertion (issue #611):
/// how many accessibility writes each transcript sequence produces, and whether
/// the session ends up delivering through the standard path — the two things
/// that decide whether text can be lost or duplicated in the target app.
final class LiveTextInserterStreamingTests: XCTestCase {
    @MainActor
    private func makeInserter(field: FakeStreamingTextField) -> LiveTextInserter {
        let defaults = UserDefaults(suiteName: "com.speakapp.tests.\(UUID().uuidString)")!
        let inserter = LiveTextInserter(
            permissionsManager: PermissionsManager(statusProvider: { _ in .granted }),
            appSettings: AppSettings(defaults: defaults)
        )
        inserter.streamingFieldProvider = { field }
        inserter.streamingVerificationDelay = 0
        inserter.begin(
            target: TextOutputTarget(
                processIdentifier: 123,
                applicationName: "TextEdit",
                bundleIdentifier: "com.apple.TextEdit",
                applicationLaunchDate: nil,
                focusedElement: nil
            ),
            strategy: .rangedStreaming
        )
        return inserter
    }

    // MARK: - Happy path

    @MainActor
    func testFirstWriteConsumesPreExistingSelection() {
        // The user had "world" selected: streaming must replace it exactly like
        // the standard insertion path would, not append alongside it.
        let field = FakeStreamingTextField(
            value: "hello world", selection: CFRange(location: 6, length: 5)
        )
        let inserter = self.makeInserter(field: field)

        inserter.update(with: "bye")

        XCTAssertEqual(field.value, "hello bye")
        XCTAssertEqual(field.selectedTextWrites.count, 1)
        XCTAssertEqual(field.selectedTextWrites.first?.range.location, 6)
        XCTAssertEqual(field.selectedTextWrites.first?.range.length, 5)
        XCTAssertEqual(inserter.insertedText, "bye")
    }

    @MainActor
    func testPartialSequenceProducesExactlyOneWritePerPartial() {
        let field = FakeStreamingTextField()
        let inserter = self.makeInserter(field: field)

        for partial in ["he", "hello", "hello there"] {
            inserter.update(with: partial)
        }

        XCTAssertEqual(field.selectedTextWrites.count, 3)
        XCTAssertEqual(field.value, "hello there")
        XCTAssertEqual(inserter.insertedText, "hello there")
        XCTAssertFalse(inserter.usingClipboardFallback)
    }

    @MainActor
    func testRepeatedIdenticalPartialProducesNoExtraWrite() {
        let field = FakeStreamingTextField()
        let inserter = self.makeInserter(field: field)

        inserter.update(with: "hello")
        inserter.update(with: "hello")

        XCTAssertEqual(field.selectedTextWrites.count, 1)
        XCTAssertEqual(field.value, "hello")
    }

    // MARK: - Write failures

    @MainActor
    func testFailedFirstWriteDefersToStandardDeliveryExactlyOnce() {
        let field = FakeStreamingTextField(
            value: "hello world", selection: CFRange(location: 6, length: 5)
        )
        field.setSelectedTextResult = .failure
        let inserter = self.makeInserter(field: field)

        inserter.update(with: "bye")

        XCTAssertTrue(inserter.usingClipboardFallback)
        XCTAssertEqual(field.value, "hello world", "a failed write must not modify the field")
        // The selection was moved before the failed replacement; leaving it
        // highlighted would make the user's next keystroke delete their text.
        XCTAssertEqual(field.selection.location, 6)
        XCTAssertEqual(field.selection.length, 0)
        XCTAssertEqual(field.selectedRangeWrites.last?.length, 0)

        // Later partials must not retry: the standard delivery owns the text now.
        inserter.update(with: "bye then")
        XCTAssertEqual(field.selectedTextWrites.count, 1)

        guard case .deferred = inserter.applyPolishedFinal("Bye then.") else {
            return XCTFail("expected a single standard delivery")
        }
        XCTAssertEqual(field.selectedTextWrites.count, 1)
    }

    @MainActor
    func testFailedLaterWritePausesWithoutASecondWrite() {
        let field = FakeStreamingTextField()
        let inserter = self.makeInserter(field: field)

        inserter.update(with: "hello")
        XCTAssertEqual(field.selectedTextWrites.count, 1)

        field.setSelectedTextResult = .failure
        inserter.update(with: "hello there")
        XCTAssertEqual(field.selectedTextWrites.count, 2, "the failing partial is attempted once")

        inserter.update(with: "hello there again")
        XCTAssertEqual(field.selectedTextWrites.count, 2, "streaming must stay paused")
        // Text already reached the app, so the standard delivery must never run:
        // it would paste a second copy alongside the streamed transcript.
        XCTAssertFalse(inserter.usingClipboardFallback)
        XCTAssertEqual(inserter.insertedText, "hello")
    }

    // MARK: - The field changing underneath the session

    @MainActor
    func testDeletedStreamedTextProducesExactlyOneStandardDelivery() {
        let field = FakeStreamingTextField()
        let inserter = self.makeInserter(field: field)

        inserter.update(with: "hello")
        XCTAssertEqual(field.selectedTextWrites.count, 1)

        // The user cleared the field: nothing from this session is on screen.
        field.value = ""
        field.selection = CFRange(location: 0, length: 0)

        guard case .deferred = inserter.applyPolishedFinal("Hello there.") else {
            return XCTFail("absent streamed text must defer to the standard delivery")
        }
        XCTAssertEqual(field.selectedTextWrites.count, 1, "finalize must not patch a vanished region")
        XCTAssertTrue(inserter.usingClipboardFallback)
        XCTAssertEqual(inserter.insertedText, "", "nothing is left that a delivery could duplicate")
    }

    @MainActor
    func testAutocorrectedFieldStopsWritingAndAvoidsDuplicateDelivery() {
        let field = FakeStreamingTextField()
        let inserter = self.makeInserter(field: field)

        inserter.update(with: "hello")
        XCTAssertEqual(field.selectedTextWrites.count, 1)

        // The app rewrote the streamed text, so its position can no longer be proven.
        field.value = "Hello"

        inserter.update(with: "hello there")
        XCTAssertEqual(field.selectedTextWrites.count, 1, "no write may target an unverifiable region")

        let result = inserter.applyPolishedFinal("Hello there.")
        guard case .failed(let error) = result else {
            return XCTFail("an unverifiable region must not be reported as delivered")
        }
        guard let outputError = error as? TextOutputError,
              case .unableToVerifyInsertion = outputError
        else {
            return XCTFail("expected an unverified-insertion error, got \(error)")
        }
        XCTAssertEqual(field.selectedTextWrites.count, 1)
        XCTAssertFalse(
            inserter.usingClipboardFallback,
            "a standard delivery here would duplicate the streamed text"
        )
    }

    // MARK: - Unreadable fields

    @MainActor
    func testUnreadableValueAfterFirstWritePausesStreaming() {
        // Web areas and custom text views often refuse to report kAXValue; the
        // session must stop patching rather than write blind.
        let field = FakeStreamingTextField()
        let inserter = self.makeInserter(field: field)

        inserter.update(with: "hello")
        XCTAssertEqual(field.selectedTextWrites.count, 1)

        field.valueIsReadable = false
        inserter.update(with: "hello there")

        XCTAssertEqual(field.selectedTextWrites.count, 1)
        XCTAssertFalse(inserter.usingClipboardFallback)
    }
}
