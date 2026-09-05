import Network
import XCTest

@testable import SpeakApp
@testable import SpeakCore

extension TransportLoopbackTests {
    func testUnauthenticatedIdlePeer_timesOutAndReleasesAdmissionSlot() async throws {
        let server = TransportServer(maximumPendingConnections: 1, handshakeTimeout: .seconds(1))
        let endpoint = try await self.startServer(configuredServer: server)
        let channel = TransportChannel.connecting(to: endpoint, includesPeerToPeer: false)
        defer { channel.close() }
        try await channel.start()
        try await self.ping(channel)
        XCTAssertEqual(server.pendingConnectionCount, 1)

        let didClose = await self.waitForClosure(of: channel)

        XCTAssertTrue(didClose, "A silent unpaired peer must lose its admission slot")
        XCTAssertEqual(server.pendingConnectionCount, 0)
        let replacement = try await self.authenticatedChannel(to: endpoint, deviceId: "after-timeout")
        defer { replacement.close() }
        XCTAssertEqual(server.connectedDevices.map(\.id), ["after-timeout"])
    }

    func testUnauthenticatedPings_doNotExtendAbsoluteHandshakeDeadline() async throws {
        let server = TransportServer(maximumPendingConnections: 1, handshakeTimeout: .seconds(1))
        let endpoint = try await self.startServer(configuredServer: server)
        let channel = TransportChannel.connecting(to: endpoint, includesPeerToPeer: false)
        defer { channel.close() }
        try await channel.start()
        try await self.ping(channel)
        let pingTask = Task {
            while !Task.isCancelled {
                try await channel.send(.ping)
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { pingTask.cancel() }

        let didClose = await self.waitForClosure(of: channel, ignoringPongs: true)

        XCTAssertTrue(didClose, "Ping traffic must not renew an unpaired peer's lifetime")
        XCTAssertEqual(server.pendingConnectionCount, 0)
    }

    func testPendingAdmissionLimit_rejectsOverflowButKeepsPairedChannel() async throws {
        let server = TransportServer(maximumPendingConnections: 1, handshakeTimeout: .seconds(10))
        let endpoint = try await self.startServer(configuredServer: server)
        let paired = try await self.authenticatedChannel(to: endpoint, deviceId: "paired")
        defer { paired.close() }
        XCTAssertEqual(server.pendingConnectionCount, 0, "Authentication releases the pending slot")
        let pending = TransportChannel.connecting(to: endpoint, includesPeerToPeer: false)
        defer { pending.close() }
        try await pending.start()
        try await self.ping(pending)

        let overflow = TransportChannel.connecting(to: endpoint, includesPeerToPeer: false)
        defer { overflow.close() }
        let rejected = await self.connectionIsRejected(overflow)

        XCTAssertTrue(rejected, "An extra unpaired socket must be rejected at the admission limit")
        XCTAssertEqual(server.pendingConnectionCount, 1)
        try await self.ping(paired)
        XCTAssertEqual(server.connectedDevices.map(\.id), ["paired"])
        server.stop()
        XCTAssertEqual(server.pendingConnectionCount, 0, "Stop releases every pending slot immediately")
    }

    func testAuthenticationCancelsHandshakeDeadline() async throws {
        let server = TransportServer(maximumPendingConnections: 1, handshakeTimeout: .seconds(1))
        let endpoint = try await self.startServer(configuredServer: server)
        let paired = try await self.authenticatedChannel(to: endpoint, deviceId: "still-paired")
        defer { paired.close() }

        try await Task.sleep(for: .milliseconds(1_200))
        try await self.ping(paired)

        XCTAssertEqual(server.connectedDevices.map(\.id), ["still-paired"])
        XCTAssertEqual(server.pendingConnectionCount, 0)
    }

    private func connectionIsRejected(_ channel: TransportChannel) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await channel.start()
                    _ = try await channel.receive()
                    return false
                } catch { return true }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let result = await group.next() ?? false
            channel.close()
            group.cancelAll()
            return result
        }
    }
}
