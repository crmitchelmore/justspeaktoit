import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// The Apple adapter reports a close status only when its own task saw a close
/// frame; any other receive failure reaches providers exactly as before.
final class URLSessionWebSocketClosureTests: XCTestCase {
    func testFailureWithoutACloseFrameIsPassedThroughUntouched() {
        let lost = NSError(domain: "SyntheticTransport", code: 7, userInfo: [NSLocalizedDescriptionKey: "Lost"])
        let mapped = URLSessionWebSocketClosure.wrapping(lost, closeCode: nil)
        XCTAssertTrue((mapped as NSError) === lost, "A generic I/O failure is not rewrapped")
        XCTAssertNil(mapped as? StreamingWebSocketCloseReporting)
        XCTAssertFalse(CartesiaLiveProtocol.isNormalClosure(mapped))
    }

    func testCloseFrameStatusIsReportedWithTheTransportDescription() {
        let underlying = NSError(
            domain: NSPOSIXErrorDomain, code: 57, userInfo: [NSLocalizedDescriptionKey: "Socket is not connected"]
        )
        let normal = URLSessionWebSocketClosure.wrapping(underlying, closeCode: 1_000)
        XCTAssertEqual((normal as? StreamingWebSocketCloseReporting)?.webSocketCloseCode, 1_000)
        XCTAssertEqual(normal.localizedDescription, "Socket is not connected", "Hosts keep the transport's text")
        XCTAssertTrue(CartesiaLiveProtocol.isNormalClosure(normal))

        let abnormal = URLSessionWebSocketClosure.wrapping(underlying, closeCode: 1_011)
        XCTAssertFalse(CartesiaLiveProtocol.isNormalClosure(abnormal))
        XCTAssertEqual(CartesiaLiveProtocol.connectionError(abnormal) as? CartesiaStreamingError, .closed(code: 1_011))
        XCTAssertFalse(CartesiaLiveProtocol.isNormalClosure(underlying), "No bare NSError is taken for a normal close")
    }
}
