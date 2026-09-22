#if os(Windows)
import CWindowsSupport
import XCTest

final class NativePlatformTests: XCTestCase {
    func testNativeAudioFramingAndUnicode_FailsClosedWithoutDeviceAccess() {
        var error = [CChar](repeating: 0, count: 1024)
        let result = jsti_native_self_test(&error, error.count)
        XCTAssertEqual(result, 0, String(cString: error))
    }

    func testMissingCredential_ReturnsMissingAndNoBytes() {
        var error = [CChar](repeating: 0, count: 1024)
        var count = 999
        let result = jsti_credential_read("tests/missing-\(UUID().uuidString)", nil, 0, &count, &error, error.count)
        XCTAssertEqual(result, 1, String(cString: error))
        XCTAssertEqual(count, 0)
    }

    func testCredentialRoundTrip_PreservesBinaryBytesAndDeletesOnlyItsOwnEntry() {
        let name = "tests/round-trip-\(UUID().uuidString)"
        let bytes: [UInt8] = [0, 1, 127, 128, 255]
        var error = [CChar](repeating: 0, count: 1024)
        XCTAssertEqual(jsti_credential_write(name, bytes, bytes.count, &error, error.count), 0, String(cString: error))
        defer { _ = jsti_credential_delete(name, &error, error.count) }

        var count = 0
        XCTAssertEqual(jsti_credential_read(name, nil, 0, &count, &error, error.count), 2)
        XCTAssertEqual(count, bytes.count)
        var output = [UInt8](repeating: 0, count: count)
        XCTAssertEqual(jsti_credential_read(name, &output, output.count, &count, &error, error.count), 0)
        XCTAssertEqual(output, bytes)
        XCTAssertEqual(jsti_credential_delete(name, &error, error.count), 0)
        XCTAssertEqual(jsti_credential_read(name, nil, 0, &count, &error, error.count), 1)
        XCTAssertEqual(count, 0)
    }
}
#endif
