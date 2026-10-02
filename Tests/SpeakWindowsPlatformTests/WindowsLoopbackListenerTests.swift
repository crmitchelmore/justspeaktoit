#if os(Windows)
import Foundation
import SpeakSync
import WinSDK
import XCTest
@testable import SpeakWindowsPlatform

/// The sign-in callback listener drops a connection that never completes its
/// request, or declares a body it cannot hold, and keeps listening, as the
/// Linux listener does: a browser's idle or abandoned preconnection must not
/// hold or end iCloud sign-in.
final class WindowsLoopbackListenerTests: XCTestCase {
    func testIdleAbandonedAndOversizedConnectionsDoNotHoldTheCallback() async throws {
        let listener = try WindowsLoopbackListener(requestWindow: .milliseconds(200))
        let port = listener.port
        let accepted = Task { try await listener.accept(timeout: .seconds(20)) }
        // A preconnection that never sends, one that closes halfway, and one
        // whose declared body would overflow the request bound.
        let idle = try XCTUnwrap(connectLoopback(port: port))
        defer { closesocket(idle) }
        let abandoned = try XCTUnwrap(connectLoopback(port: port))
        send(abandoned, "GET /cloudkit-sign-in?ckWeb")
        closesocket(abandoned)
        let oversized = try XCTUnwrap(connectLoopback(port: port))
        defer { closesocket(oversized) }
        send(oversized, "POST /cloudkit-sign-in?ckWebAuthToken=forged HTTP/1.1\r\n"
            + "Content-Length: 18446744073709551615\r\n\r\n")
        let target = "/cloudkit-sign-in?ckWebAuthToken=t1"
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)" + target))
        let reply = Task {
            try await WinHTTPCloudKitTransport(timeout: .seconds(20)).send(
                CloudKitWebServicesHTTPRequest(method: "GET", url: url, headers: [:], body: nil), responseLimit: 4096
            )
        }
        let connection = try await accepted.value
        let received = connection.target
        connection.respond(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8))
        let response = try await reply.value
        listener.close()

        XCTAssertEqual(received, target)
        XCTAssertEqual(response.statusCode, 200)
    }
}

/// Connects a plain TCP socket to this computer's loopback address. The
/// listener under test has already started Winsock for this process.
private func connectLoopback(port: UInt16) -> SOCKET? {
    let socket = WinSDK.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP.rawValue)
    guard socket != SOCKET(bitPattern: -1) else { return nil }
    var address = sockaddr_in()
    address.sin_family = ADDRESS_FAMILY(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.S_un.S_addr = UInt32(0x7F00_0001).bigEndian
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            WinSDK.connect(socket, $0, Int32(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else {
        closesocket(socket)
        return nil
    }
    return socket
}

private func send(_ socket: SOCKET, _ text: String) {
    _ = text.withCString { WinSDK.send(socket, $0, Int32(text.utf8.count), 0) }
}
#endif
