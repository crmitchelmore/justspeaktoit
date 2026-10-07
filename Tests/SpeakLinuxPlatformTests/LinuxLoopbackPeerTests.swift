import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Glibc
import CLinuxSupport
import SpeakDesktopSync
import SpeakLinuxPlatform
import SpeakSync
import XCTest

/// The sign-in callback is accepted only from this user's processes: the
/// listener reads the connecting socket's owner from the kernel's TCP tables.
final class LinuxLoopbackPeerTests: XCTestCase {
    private let header = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  "
        + "timeout inode"
    private let loopback = UInt32(0x7F00_0001).bigEndian
    private let peerPort: UInt16 = 40_000
    private let listenerPort: UInt16 = 47_823

    /// One table row as the kernel prints it: addresses as network-order
    /// values read natively, ports in host order.
    private func row(_ local: String, _ localPort: UInt16, _ remote: String, _ remotePort: UInt16,
                     state: String = "01", uid: Int) -> String {
        "   0: \(local):\(hex(localPort)) \(remote):\(hex(remotePort)) \(state) 00000000:00000000 00:00000000 "
            + "00000000 \(String(format: "%5ld", uid))        0 4242 1 0000000000000000 20 4 30 10 -1"
    }

    private func hex(_ port: UInt16) -> String { String(format: "%04X", port) }
    private var four: String { String(format: "%08X", loopback) }
    private var mapped: String {
        "0000000000000000" + String(format: "%08X", UInt32(0x0000_FFFF).bigEndian) + four
    }

    private func owner(tcp: [String]?, tcp6: [String]? = nil, user: UInt32 = 1_000) -> Int32 {
        func text(_ rows: [String]?) -> String? { rows.map { ([header] + $0).joined(separator: "\n") + "\n" } }
        let tcpText = text(tcp)
        let tcp6Text = text(tcp6)
        return tcpText.withOptionalCString { tcpPointer in
            tcp6Text.withOptionalCString { tcp6Pointer in
                jsti_loopback_peer_owner_in_tables(
                    tcpPointer, tcp6Pointer, loopback, peerPort, loopback, listenerPort, user
                )
            }
        }
    }

    func testThePeerSocketsOwnerIsReadFromTheTCPTables() {
        let listening = row(four, listenerPort, "00000000", 0, state: "0A", uid: 1_000)
        let accepted = row(four, listenerPort, four, peerPort, uid: 1_000)
        let peer = { (uid: Int) in self.row(self.four, self.peerPort, self.four, self.listenerPort, uid: uid) }

        XCTAssertEqual(owner(tcp: [listening, accepted, peer(1_000)]), 0, "this user's process")
        XCTAssertEqual(owner(tcp: [listening, accepted, peer(1_001)]), 1, "another user's process")
        XCTAssertEqual(owner(tcp: [listening, accepted, peer(65_534)]), 1, "an unmapped user in a namespace")
        // Our own accepted socket is never mistaken for the peer's.
        XCTAssertEqual(owner(tcp: [listening, accepted]), -1)
        XCTAssertEqual(owner(tcp: nil), -1)
        XCTAssertEqual(owner(tcp: ["garbage", "", "   7: nothing"]), -1)
        // Another port or address on the same tuple shape is not the peer.
        XCTAssertEqual(owner(tcp: [row(four, peerPort + 1, four, listenerPort, uid: 1_000)]), -1)
        XCTAssertEqual(owner(tcp: [row("0200007F", peerPort, four, listenerPort, uid: 1_000)]), -1)
        XCTAssertEqual(owner(tcp: [row(four, peerPort, four, listenerPort + 1, uid: 1_000)]), -1)
    }

    func testTimeWaitEntriesAreSkippedAndConflictingOwnersAreUnknown() {
        let timeWait = row(four, peerPort, four, listenerPort, state: "06", uid: 0)
        let live = row(four, peerPort, four, listenerPort, uid: 1_000)
        XCTAssertEqual(owner(tcp: [timeWait]), -1, "a closed socket belongs to no process")
        XCTAssertEqual(owner(tcp: [timeWait, live]), 0)
        XCTAssertEqual(owner(tcp: [live, row(four, peerPort, four, listenerPort, state: "08", uid: 1_001)]), -1)
    }

    func testADualStackPeerIsFoundInTheIPv6Table() {
        let peer6 = row(mapped, peerPort, mapped, listenerPort, uid: 1_000)
        XCTAssertEqual(owner(tcp: [], tcp6: [peer6]), 0)
        XCTAssertEqual(owner(tcp: nil, tcp6: [row(mapped, peerPort, mapped, listenerPort, uid: 1_001)]), 1)
        // ::1 and other IPv6 addresses are not 127.0.0.1.
        let ipv6Loopback = "00000000000000000000000001000000"
        XCTAssertEqual(owner(tcp: nil, tcp6: [row(ipv6Loopback, peerPort, mapped, listenerPort, uid: 1_000)]), -1)
        // One owner in each table must agree.
        XCTAssertEqual(
            owner(tcp: [row(four, peerPort, four, listenerPort, uid: 1_001)], tcp6: [peer6]), -1
        )
    }

    func testAConnectionFromThisProcessIsThisUsers() async throws {
        let listener = try LinuxLoopbackListener()
        defer { listener.close() }
        let request = "GET /cloudkit-sign-in?ckWebAuthToken=t HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            + "Sec-Fetch-Mode: navigate\r\n\r\n"
        for family in [AF_INET, AF_INET6] {
            guard let client = connect(family: family, port: listener.port) else {
                XCTAssertEqual(family, AF_INET6, "IPv4 loopback is always available")
                continue
            }
            defer { Glibc.close(client) }
            _ = request.withCString { Glibc.send(client, $0, strlen($0), 0) }
            let next = try await listener.nextRequest(within: .seconds(10))
            let connection = try XCTUnwrap(next)
            XCTAssertEqual(connection.peer, .currentUser, "family \(family)")
            XCTAssertEqual(connection.head?.values("Sec-Fetch-Mode"), ["navigate"])
            connection.respond(DesktopCloudSyncSignIn.callbackPage("ok", "ok"))
        }
    }

    func testAWebPageRequestIsRefusedAndTheBrowsersCallbackStillSignsIn() async throws {
        let listener = try LinuxLoopbackListener()
        let port = listener.port
        let callback = Task { try await DesktopCloudSyncSignIn.awaitCallback(on: listener, within: .seconds(20)) }
        let transport = LinuxCloudKitTransport(timeout: .seconds(20))
        let page = try await transport.send(
            CloudKitWebServicesHTTPRequest(
                method: "GET",
                url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/cloudkit-sign-in?ckWebAuthToken=attacker")),
                headers: ["Sec-Fetch-Mode": "no-cors", "Sec-Fetch-Site": "cross-site", "Sec-Fetch-Dest": "image"],
                body: nil
            ),
            responseLimit: 4096
        )
        let browser = try await transport.send(
            CloudKitWebServicesHTTPRequest(
                method: "GET",
                url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/cloudkit-sign-in?ckWebAuthToken=mine")),
                headers: ["Sec-Fetch-Mode": "navigate", "Sec-Fetch-Site": "cross-site", "Sec-Fetch-Dest": "document"],
                body: nil
            ),
            responseLimit: 4096
        )
        let token = try await callback.value
        listener.close()

        XCTAssertEqual(page.statusCode, 403)
        XCTAssertEqual(browser.statusCode, 200)
        XCTAssertEqual(token, "mine")
    }

    /// Needs root, to run a client as `nobody`; CI runners and developer
    /// machines skip it.
    func testAnotherUsersProcessCannotCompleteTheSignIn() async throws {
        let setpriv = URL(fileURLWithPath: "/usr/bin/setpriv")
        let curl = URL(fileURLWithPath: "/usr/bin/curl")
        guard geteuid() == 0, FileManager.default.isExecutableFile(atPath: setpriv.path),
              FileManager.default.isExecutableFile(atPath: curl.path) else {
            throw XCTSkip("Running a client as another user needs root, setpriv and curl.")
        }
        func curlAsNobody(_ url: String) -> Task<String, Error> {
            Task.detached {
                let process = Process()
                let output = Pipe()
                process.executableURL = setpriv
                process.arguments = [
                    "--reuid=65534", "--regid=65534", "--clear-groups", curl.path, "-s", "-o", "/dev/null",
                    "-w", "%{http_code}", url
                ]
                process.standardOutput = output
                try process.run()
                process.waitUntilExit()
                return String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            }
        }
        let listener = try LinuxLoopbackListener()
        let port = listener.port
        let callbackURL = "http://127.0.0.1:\(port)/cloudkit-sign-in?ckWebAuthToken="

        // The listener names the other account, rather than failing to tell.
        let probe = curlAsNobody(callbackURL + "probe")
        let next = try await listener.nextRequest(within: .seconds(20))
        let connection = try XCTUnwrap(next)
        XCTAssertEqual(connection.peer, .otherUser)
        XCTAssertEqual(
            DesktopCloudSyncSignIn.evaluateCallback(connection.head, peer: connection.peer), .refuse(.otherUser)
        )
        connection.respond(DesktopCloudSyncSignIn.callbackPage("Not signed in", "Refused.", status: 403))
        _ = try await probe.value

        // During sign-in its callback is refused and this user's still arrives.
        let callback = Task { try await DesktopCloudSyncSignIn.awaitCallback(on: listener, within: .seconds(20)) }
        let other = try await curlAsNobody(callbackURL + "other-user").value
        let mine = try await LinuxCloudKitTransport(timeout: .seconds(20)).send(
            CloudKitWebServicesHTTPRequest(
                method: "GET", url: try XCTUnwrap(URL(string: callbackURL + "mine")), headers: [:], body: nil
            ),
            responseLimit: 4096
        )
        let token = try await callback.value
        listener.close()

        XCTAssertEqual(other, "403", "another user's callback is refused")
        XCTAssertEqual(mine.statusCode, 200)
        XCTAssertEqual(token, "mine")
    }

    /// A TCP socket of `family` connected to 127.0.0.1 (as ::ffff:127.0.0.1
    /// for a dual-stack IPv6 socket), or `nil` when the family is unavailable.
    private func connect(family: Int32, port: UInt16) -> Int32? {
        let client = Glibc.socket(family, Int32(SOCK_STREAM.rawValue), 0)
        guard client >= 0 else { return nil }
        var connected: Int32 = -1
        if family == AF_INET6 {
            var only: Int32 = 0
            setsockopt(client, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &only, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6()
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            _ = inet_pton(AF_INET6, "::ffff:127.0.0.1", &address.sin6_addr)
            connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Glibc.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = loopback
            connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Glibc.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard connected == 0 else {
            Glibc.close(client)
            return nil
        }
        return client
    }
}

private extension Optional where Wrapped == String {
    func withOptionalCString<Result>(_ body: (UnsafePointer<CChar>?) -> Result) -> Result {
        guard let self else { return body(nil) }
        return self.withCString { body($0) }
    }
}
