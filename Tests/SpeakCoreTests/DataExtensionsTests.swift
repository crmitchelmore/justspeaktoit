import XCTest

@testable import SpeakCore

final class DataExtensionsTests: XCTestCase {

    // MARK: - appendFormField

    func testAppendFormField_containsBoundaryAndName() {
        var data = Data()
        data.appendFormField(named: "username", value: "alice", boundary: "BOUNDARY123")

        let string = String(data: data, encoding: .utf8)!
        XCTAssertTrue(string.contains("--BOUNDARY123"), "Should contain boundary prefix")
        XCTAssertTrue(
            string.contains("Content-Disposition: form-data; name=\"username\""),
            "Should contain field name"
        )
        XCTAssertTrue(string.contains("alice"), "Should contain field value")
    }

    func testAppendFormField_multipleFields_allPresent() {
        var data = Data()
        data.appendFormField(named: "field1", value: "value1", boundary: "B")
        data.appendFormField(named: "field2", value: "value2", boundary: "B")

        let string = String(data: data, encoding: .utf8)!
        XCTAssertTrue(string.contains("field1"))
        XCTAssertTrue(string.contains("value1"))
        XCTAssertTrue(string.contains("field2"))
        XCTAssertTrue(string.contains("value2"))
    }

    func testAppendFormField_specialCharacters_preserved() {
        var data = Data()
        data.appendFormField(named: "text", value: "Hello, world! 🎙️", boundary: "B")

        let string = String(data: data, encoding: .utf8)!
        XCTAssertTrue(string.contains("Hello, world! 🎙️"))
    }

    // MARK: - appendFileField

    func testAppendFileField_containsFilenameAndMimeType() {
        var data = Data()
        let fileData = "audio content".data(using: .utf8)!
        data.appendFileField(
            named: "file",
            filename: "recording.wav",
            mimeType: "audio/wav",
            fileData: fileData,
            boundary: "BOUND"
        )

        let string = String(data: data, encoding: .utf8)!
        XCTAssertTrue(string.contains("--BOUND"), "Should contain boundary")
        XCTAssertTrue(string.contains("filename=\"recording.wav\""), "Should contain filename")
        XCTAssertTrue(string.contains("Content-Type: audio/wav"), "Should contain MIME type")
        XCTAssertTrue(string.contains("audio content"), "Should contain file data")
    }

    func testAppendFileField_binaryData_preserved() {
        var data = Data()
        let binaryData = Data([0x00, 0xFF, 0x42, 0x13])
        data.appendFileField(
            named: "upload",
            filename: "data.bin",
            mimeType: "application/octet-stream",
            fileData: binaryData,
            boundary: "B"
        )

        XCTAssertTrue(data.count > binaryData.count, "Output should contain headers + binary data")
        // Verify the binary payload is embedded
        let range = data.range(of: binaryData)
        XCTAssertNotNil(range, "Binary data should be present in output")
    }
}
