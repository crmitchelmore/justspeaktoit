import XCTest

@testable import SpeakCore

final class OpenClawContentExtractionTests: XCTestCase {

    // MARK: - No message key

    func testExtractContent_emptyDict_returnsEmpty() {
        let result = OpenClawClient.extractContent(from: [:])
        XCTAssertEqual(result, "")
    }

    func testExtractContent_missingMessageKey_returnsEmpty() {
        let dict: [String: Any] = ["other": "value"]
        XCTAssertEqual(OpenClawClient.extractContent(from: dict), "")
    }

    func testExtractContent_messageKeyNotDict_returnsEmpty() {
        let dict: [String: Any] = ["message": "not a dict"]
        XCTAssertEqual(OpenClawClient.extractContent(from: dict), "")
    }

    // MARK: - String content

    func testExtractContent_stringContent_returnsString() {
        let dict: [String: Any] = ["message": ["content": "Hello world"]]
        XCTAssertEqual(OpenClawClient.extractContent(from: dict), "Hello world")
    }

    func testExtractContent_emptyStringContent_returnsEmpty() {
        let dict: [String: Any] = ["message": ["content": ""]]
        XCTAssertEqual(OpenClawClient.extractContent(from: dict), "")
    }

    func testExtractContent_stringContent_preservesUnicode() {
        let dict: [String: Any] = ["message": ["content": "こんにちは 🎙️"]]
        XCTAssertEqual(OpenClawClient.extractContent(from: dict), "こんにちは 🎙️")
    }

    // MARK: - Block content

    func testExtractContent_singleTextBlock_returnsText() {
        let blocks: [[String: Any]] = [["type": "text", "text": "Hello"]]
        let dict: [String: Any] = ["message": ["content": blocks]]
        XCTAssertEqual(OpenClawClient.extractContent(from: dict), "Hello")
    }

    func testExtractContent_multipleTextBlocks_joinsText() {
        let blocks: [[String: Any]] = [
            ["type": "text", "text": "Hello"],
            ["type": "text", "text": " world"]
        ]
        let dict: [String: Any] = ["message": ["content": blocks]]
        XCTAssertEqual(OpenClawClient.extractContent(from: dict), "Hello world")
    }

    func testExtractContent_nonTextBlocksOnly_returnsEmpty() {
        let blocks: [[String: Any]] = [
            ["type": "image", "url": "https://example.com/image.png"],
            ["type": "tool_use", "name": "web_search"]
        ]
        let dict: [String: Any] = ["message": ["content": blocks]]
        XCTAssertEqual(OpenClawClient.extractContent(from: dict), "")
    }

    func testExtractContent_mixedBlocks_includesOnlyTextBlocks() {
        let blocks: [[String: Any]] = [
            ["type": "text", "text": "Before"],
            ["type": "image", "url": "https://example.com/image.png"],
            ["type": "text", "text": " after"]
        ]
        let dict: [String: Any] = ["message": ["content": blocks]]
        XCTAssertEqual(OpenClawClient.extractContent(from: dict), "Before after")
    }

    func testExtractContent_textBlockMissingTextField_skipsBlock() {
        let blocks: [[String: Any]] = [
            ["type": "text"],
            ["type": "text", "text": "valid"]
        ]
        let dict: [String: Any] = ["message": ["content": blocks]]
        XCTAssertEqual(OpenClawClient.extractContent(from: dict), "valid")
    }

    func testExtractContent_emptyBlockArray_returnsEmpty() {
        let dict: [String: Any] = ["message": ["content": [[String: Any]]()]]
        XCTAssertEqual(OpenClawClient.extractContent(from: dict), "")
    }

    // MARK: - No content key

    func testExtractContent_messageWithNoContent_returnsEmpty() {
        let dict: [String: Any] = ["message": ["other": "value"]]
        XCTAssertEqual(OpenClawClient.extractContent(from: dict), "")
    }
}
