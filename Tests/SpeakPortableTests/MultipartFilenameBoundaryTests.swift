import Foundation
import XCTest

@testable import SpeakCore

final class MultipartFilenameBoundaryTests: XCTestCase {
    func testOrdinaryUnicodeFilename_PreservesCompleteWireBytesAndBinaryBody() {
        let payload = Data([0x00, 0xFF, 0x0D, 0x0A, 0x0D, 0x0A, 0x22, 0x5C])
        var expected = Data(
            "--BOUND\r\nContent-Disposition: form-data; name=\"file\"; filename=\"café 🎙.wav\"\r\n"
                .utf8
        )
        expected.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        expected.append(payload)
        expected.append(Data("\r\n".utf8))

        XCTAssertEqual(multipart(filename: "café 🎙.wav", payload: payload), expected)
    }

    func testQuotedFilename_EscapesParameterDelimitersWithoutChangingPayload() throws {
        let payload = Data("\"\\\r\nContent-Type: payload bytes\r\n\r\n".utf8)
        let body = multipart(filename: "recording \"take\\one\".wav", payload: payload)
        let separator = try XCTUnwrap(body.range(of: Data("\r\n\r\n".utf8)))
        let header = try XCTUnwrap(String(data: body[..<separator.lowerBound], encoding: .utf8))

        XCTAssertEqual(
            header,
            "--BOUND\r\nContent-Disposition: form-data; name=\"file\"; "
                + "filename=\"recording \\\"take\\\\one\\\".wav\"\r\nContent-Type: audio/wav"
        )
        XCTAssertEqual(body[separator.upperBound...], payload + Data("\r\n".utf8))
    }

    func testFilenameControls_CannotAddHeaderLinesOrTerminateTheHeader() throws {
        let payload = Data([0x00, 0x85, 0xFF, 0x0D, 0x0A])
        let filename = "recording\"\r\nX-Forged: yes\r\n\r\n"
            + "\u{0000}\u{0009}\u{007F}\u{0085}\u{2028}\u{2029}\u{200E}.wav"
        let body = multipart(filename: filename, payload: payload)
        let separator = try XCTUnwrap(body.range(of: Data("\r\n\r\n".utf8)))
        let header = try XCTUnwrap(String(data: body[..<separator.lowerBound], encoding: .utf8))

        XCTAssertEqual(header.components(separatedBy: "\r\n").count, 3)
        XCTAssertEqual(
            header,
            "--BOUND\r\nContent-Disposition: form-data; name=\"file\"; "
                + "filename=\"recording\\\"X-Forged: yes.wav\"\r\nContent-Type: audio/wav"
        )
        XCTAssertEqual(body[separator.upperBound...], payload + Data("\r\n".utf8))
    }

    private func multipart(filename: String, payload: Data) -> Data {
        var body = Data()
        body.appendFileField(
            named: "file", filename: filename, mimeType: "audio/wav", fileData: payload, boundary: "BOUND"
        )
        return body
    }
}
