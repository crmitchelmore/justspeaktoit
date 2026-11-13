import Network
import XCTest

@testable import SpeakApp
@testable import SpeakCore

/// Drives the phone-side `SendToMacSender` against the shipping Mac
/// `TransportServer` over loopback (#1640): pairing keeps the issued
/// credential, sends use it, and a rejected credential is never answered with
/// the pairing code.
extension TransportLoopbackTests {
    // MARK: - Send to Mac sender (#1640)

    func testSendToMacSender_pairingStoresTheCredentialAndSendDeliversTheTranscript() async throws {
        let endpoint = try await self.startServer()
        let server = try XCTUnwrap(self.server)
        let delivery = self.expectation(description: "The Mac receives the transcript")
        let inbox = TranscriptInbox()
        server.onTranscriptReceived = { sessionId, text in
            inbox.record(sessionId: sessionId, text: text)
            delivery.fulfill()
        }
        let store = InMemorySendToMacPairingStore()
        let sender = self.makeSender(store: store, endpoint: endpoint)

        let paired = await sender.pair(with: endpoint, named: "Test Mac", code: PairingManager.shared.pairingCode)

        XCTAssertTrue(paired, "Pairing failed: \(sender.activity)")
        XCTAssertEqual(sender.pairedMacName, "Test Mac")
        XCTAssertEqual(store.pairedMacName, "Test Mac")
        let credential = try XCTUnwrap(store.credential(forMac: "Test Mac"), "Pairing must keep the credential")
        XCTAssertTrue(PairingManager.shared.hasCredential(credential.id))

        let sent = await sender.send("Hello from the phone", model: "test-model", duration: 3)

        XCTAssertTrue(sent, "Send failed: \(sender.activity)")
        XCTAssertEqual(sender.activity, .sent(macName: "Test Mac"))
        await self.fulfillment(of: [delivery], timeout: 5)
        XCTAssertEqual(inbox.text, "Hello from the phone")
        XCTAssertEqual(store.credential(forMac: "Test Mac"), credential, "Sending must reuse the credential")
    }

    func testSendToMacSender_revokedCredentialFailsAndIsNeverRetriedWithTheCode() async throws {
        let endpoint = try await self.startServer()
        let server = try XCTUnwrap(self.server)
        let inbox = TranscriptInbox()
        server.onTranscriptReceived = { sessionId, text in inbox.record(sessionId: sessionId, text: text) }
        let store = InMemorySendToMacPairingStore()
        let sender = self.makeSender(store: store, endpoint: endpoint)
        let didPair = await sender.pair(with: endpoint, named: "Test Mac", code: PairingManager.shared.pairingCode)
        XCTAssertTrue(didPair)
        let credential = try XCTUnwrap(store.credential(forMac: "Test Mac"))

        // A new code on the Mac revokes every credential.
        _ = PairingManager.shared.regeneratePairingCode()
        let sent = await sender.send("Should not arrive")

        XCTAssertFalse(sent)
        XCTAssertEqual(sender.activity, .sendFailed(TransportChannel.revokedCredentialMessage))
        XCTAssertNil(inbox.text, "A rejected sender must not deliver anything")
        XCTAssertEqual(store.credential(forMac: "Test Mac"), credential, "Only the user may forget the Mac")
        XCTAssertEqual(sender.pairedMacName, "Test Mac")
        XCTAssertFalse(
            PairingManager.shared.isDevicePaired(id: DeviceIdentity.deviceId),
            "The sender must not re-pair with the code on its own"
        )
    }

    func testSendToMacSender_wrongCodeLeavesTheMacUnpaired() async throws {
        let endpoint = try await self.startServer()
        let store = InMemorySendToMacPairingStore()
        let sender = self.makeSender(store: store, endpoint: endpoint)
        let current = PairingManager.shared.pairingCode
        let wrong = current == "000000" ? "111111" : "000000"

        let paired = await sender.pair(with: endpoint, named: "Test Mac", code: wrong)

        XCTAssertFalse(paired)
        guard case .pairingFailed = sender.activity else {
            XCTFail("Expected a pairing failure, got \(sender.activity)")
            return
        }
        XCTAssertNil(sender.pairedMacName)
        XCTAssertNil(store.pairedMacName)
        XCTAssertNil(store.credential(forMac: "Test Mac"))
    }

    func testSendToMacSender_malformedCodeFailsWithoutConnecting() async throws {
        let store = InMemorySendToMacPairingStore()
        // Nothing listens here, so a connection attempt would time out instead.
        let unreachable = try XCTUnwrap(SpeakTransportWire.endpoint(host: "127.0.0.1", port: 9))
        let sender = self.makeSender(store: store, endpoint: unreachable)

        let paired = await sender.pair(with: unreachable, named: "Test Mac", code: "12 34")

        XCTAssertFalse(paired)
        XCTAssertEqual(sender.activity, .pairingFailed("Enter the six-digit code shown on the Mac."))
        XCTAssertEqual(SendToMacSender.normalizedPairingCode("123 456"), "123456")
        XCTAssertNil(SendToMacSender.normalizedPairingCode("12345a"))
    }

    func testSendToMacSender_forgetClearsTheCredentialAndBlocksSending() async throws {
        let endpoint = try await self.startServer()
        let store = InMemorySendToMacPairingStore()
        let sender = self.makeSender(store: store, endpoint: endpoint)
        let didPair = await sender.pair(with: endpoint, named: "Test Mac", code: PairingManager.shared.pairingCode)
        XCTAssertTrue(didPair)

        sender.forget()

        XCTAssertNil(sender.pairedMacName)
        XCTAssertNil(store.pairedMacName)
        XCTAssertNil(store.credential(forMac: "Test Mac"))
        let sent = await sender.send("After forgetting")
        XCTAssertFalse(sent)
        XCTAssertEqual(sender.activity, .sendFailed("Pair with a Mac in Settings first."))
    }

    private func makeSender(store: SendToMacPairingStore, endpoint: NWEndpoint) -> SendToMacSender {
        SendToMacSender(
            store: store,
            resolveEndpoint: { _ in endpoint },
            connectTimeout: .seconds(5),
            acknowledgementTimeout: .seconds(5)
        )
    }
}
