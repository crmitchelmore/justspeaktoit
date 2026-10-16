import XCTest
@testable import SpeakCore

final class VoiceSynthesisMarkupEditingTests: XCTestCase {
    func testWrap_UsesTheEntireDraftWithoutEscapingOrReplacingSelectedWords() throws {
        let draft = "Before Ω 😀 & <break time='500ms'/>\r\nAfter &lt;literal&gt;."
        let result = try nativeWrap(draft)
        XCTAssertEqual(result.text, "<speak>" + draft + "</speak>")
        XCTAssertEqual(result.text, VoiceSynthesisMarkup.wrapping(draft))
        XCTAssertEqual(result.utf16, 7)
        XCTAssertEqual(result.scalars, 7)
        XCTAssertTrue(result.text.contains("& <break"))
        XCTAssertTrue(result.text.contains("&lt;literal&gt;"))
    }

    func testExistingMarker_UsesTheExactMacTestRatherThanInventingXMLRecognition() throws {
        for draft in ["<speak>Ω &amp; 😀</speak>", "before <speak>fragment</speak> after"] {
            let result = try nativeWrap(draft)
            XCTAssertEqual(result.text, draft)
            XCTAssertEqual(result.utf16, 0)
            XCTAssertEqual(result.scalars, 0)
        }
        for draft in ["<speak version='1.0'>Ω</speak>", "<SPEAK>Ω</SPEAK>", "<speak />"] {
            XCTAssertEqual(try nativeWrap(draft).text, "<speak>" + draft + "</speak>")
        }
    }

    func testEmptyAndWhitespaceDrafts_WrapLikeTheMacWithoutStartingSynthesis() throws {
        for draft in ["", " \r\n\t "] {
            XCTAssertEqual(try nativeWrap(draft).text, "<speak>" + draft + "</speak>")
        }
    }

    func testUnicodeSelectionOffsets_RetainTheOriginalUTF16AndScalarSpans() throws {
        let draft = "Ω 😀 e\u{301} suffix"
        let result = try nativeWrap(draft)
        let original = Array(draft.utf16)
        let wrapped = Array(result.text.utf16)
        XCTAssertEqual(Array(wrapped[Int(result.utf16)..<(Int(result.utf16) + original.count)]), original)
        let scalars = Array(draft.unicodeScalars)
        let wrappedScalars = Array(result.text.unicodeScalars)
        XCTAssertEqual(Array(wrappedScalars[
            Int(result.scalars)..<(Int(result.scalars) + scalars.count)]), scalars)
    }

    func testRejectedBridgeInput_LeavesOutputAndOffsetsUntouched() {
        var output = [CChar](repeating: 42, count: 64)
        var utf16: Int32 = 123
        var scalars: Int32 = 456
        let invalid: [CChar] = [-1, 0]
        let capacity = output.count
        invalid.withUnsafeBufferPointer { input in
            XCTAssertEqual(VoiceSynthesisMarkup.writeWrappedText(input.baseAddress,
                output: &output, capacity: capacity, leadingUTF16: &utf16, leadingScalars: &scalars), -1)
        }
        "Synthetic".withCString { input in
            for capacity in [0, 1, 1_048_577] {
                XCTAssertEqual(VoiceSynthesisMarkup.writeWrappedText(input,
                    output: &output, capacity: capacity, leadingUTF16: &utf16, leadingScalars: &scalars), -1)
            }
            XCTAssertEqual(VoiceSynthesisMarkup.writeWrappedText(input,
                output: nil, capacity: 64, leadingUTF16: &utf16, leadingScalars: &scalars), -1)
            XCTAssertEqual(VoiceSynthesisMarkup.writeWrappedText(nil,
                output: &output, capacity: 64, leadingUTF16: &utf16, leadingScalars: &scalars), -1)
        }
        XCTAssertEqual(output, [CChar](repeating: 42, count: 64))
        XCTAssertEqual(utf16, 123)
        XCTAssertEqual(scalars, 456)
    }

    func testCanonicalExamples_RetainMarkupDescriptionsAndUnicodePronunciation() throws {
        XCTAssertEqual(VoiceSynthesisMarkup.examples.count, 6)
        for example in VoiceSynthesisMarkup.examples {
            XCTAssertFalse(example.description.isEmpty)
            XCTAssertEqual(try nativeWrap(example.text).text, VoiceSynthesisMarkup.wrapping(example.text))
        }
        XCTAssertTrue(VoiceSynthesisMarkup.examples.contains { $0.text.contains("təˈmeɪtoʊ") })
    }

    // existing owned native-wrap test helper for a single call site; no behavior change.
    // swiftlint:disable:next large_tuple
    private func nativeWrap(_ text: String) throws -> (text: String, utf16: Int32, scalars: Int32) {
        var output = [CChar](repeating: 0, count: text.utf8.count + 1024)
        var utf16: Int32 = -1
        var scalars: Int32 = -1
        let capacity = output.count
        let status = text.withCString {
            VoiceSynthesisMarkup.writeWrappedText($0, output: &output, capacity: capacity,
                leadingUTF16: &utf16, leadingScalars: &scalars)
        }
        XCTAssertEqual(status, 0)
        return (output.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }, utf16, scalars)
    }
}
