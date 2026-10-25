import ApplicationServices
import XCTest

@testable import SpeakApp

final class AccessibilityInsertionWriterTests: XCTestCase {
    func testAppSwitchDuringSelectionRead_refusesAllWrites() {
        var frontmost = true
        var writes = 0
        let result = AccessibilityInsertionWriter.insertAtCursor(
            text: "Hello", selectedRange: { frontmost = false; return CFRange(location: 2, length: 0) },
            destinationError: { frontmost ? nil : .destinationApplicationChanged },
            setSelectedText: { writes += 1; return .success },
            setValue: { writes += 1; return .success }
        )
        XCTAssertEqual(writes, 0)
        assertDestinationChanged(result)
    }

    func testAppSwitchAfterSelectedTextFailure_refusesWholeFieldFallback() {
        var frontmost = true
        var writes: [String] = []
        let result = AccessibilityInsertionWriter.insertAtCursor(
            text: "Hello", selectedRange: { CFRange(location: 2, length: 0) },
            destinationError: { frontmost ? nil : .destinationApplicationChanged },
            setSelectedText: { writes.append("selection"); frontmost = false; return .failure },
            setValue: { writes.append("whole field"); return .success }
        )
        XCTAssertEqual(writes, ["selection"])
        assertDestinationChanged(result)
    }

    func testStableDestination_retainsWholeFieldFallbackAndUTF16Range() {
        var writes: [String] = []
        let result = AccessibilityInsertionWriter.insertAtCursor(
            text: "Hi 👋", selectedRange: { CFRange(location: 8, length: 0) }, destinationError: { nil },
            setSelectedText: { writes.append("selection"); return .attributeUnsupported },
            setValue: { writes.append("whole field"); return .success }
        )
        XCTAssertEqual(writes, ["selection", "whole field"])
        XCTAssertNil(result.error)
        XCTAssertEqual(result.insertedRange, VoiceEditTextRange(location: 0, length: 5))
    }

    func testSuccessfulSelectionWrite_retainsOriginalInsertionRange() {
        let result = AccessibilityInsertionWriter.insertAtCursor(
            text: "Hi 👋", selectedRange: { CFRange(location: 8, length: 3) }, destinationError: { nil },
            setSelectedText: { .success }, setValue: { XCTFail("Unexpected whole-field write"); return .failure }
        )
        XCTAssertNil(result.error)
        XCTAssertEqual(result.insertedRange, VoiceEditTextRange(location: 8, length: 5))
    }

    func testReplaceAll_rechecksDestinationBeforeWriting() {
        let result = AccessibilityInsertionWriter.replaceAll(
            text: "Hello", destinationError: { .destinationApplicationChanged },
            setValue: { XCTFail("Destination changed"); return .success }
        )
        assertDestinationChanged(result)
    }

    private func assertDestinationChanged(
        _ result: TextOutputResult, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .destinationApplicationChanged? = result.error as? TextOutputError else {
            return XCTFail("Expected changed-destination error", file: file, line: line)
        }
        XCTAssertNil(result.insertedRange, file: file, line: line)
    }
}
