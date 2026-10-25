import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Synthetic qualification of the current shared Modulate path and actual Apple
/// adapter. This mirrors iOS startClient-before-startCaptureAudio ordering; it
/// does not exercise a microphone, provider service or separate Mac controller.
final class ModulateOpeningAudioQualificationTests: XCTestCase {
    func testHeldHTTP101PreservesOpeningAndLivePCMExactlyOnceInCaptureOrder() async throws {
        let harness = try ModulateOpeningHarness(sessionCount: 1)
        addTeardownBlock { await harness.cleanup() }
        let identifier = harness.identifiers[0]
        let expected = Array(0..<12)
        try await harness.peer.configure(identifier, ids: expected, ackAfter: 10)
        let heard = expectation(description: "Peer received all ten opening chunks")
        harness.start(heard: heard)
        try await harness.peer.wait(identifier, stages: ["held"])
        harness.offer(Array(0..<10)) // Capture starts only after client.start returned.
        try await assertHeld(harness, identifier: identifier)
        try await harness.peer.act(identifier, action: "release")
        await fulfillment(of: [heard], timeout: 4)
        harness.offer([10, 11])
        let transcript = await harness.client.finishAndWait()
        XCTAssertEqual(transcript, "Opening verified.")
        try await assertReceipt(harness, identifier: identifier, ids: expected)
        XCTAssertTrue(harness.events.errors.isEmpty, "\(harness.events.errors)")
    }

    func testPrestartPrerollIsSeparateAndPostStopAudioDoesNotLeakIntoRestart() async throws {
        let harness = try ModulateOpeningHarness(sessionCount: 2)
        addTeardownBlock { await harness.cleanup() }
        let first = harness.identifiers[0], second = harness.identifiers[1]
        try await harness.peer.configure(first, ids: [900, 901, 902], ackAfter: 3)
        harness.client.sendAudio(ModulateOpeningHarness.frame(900)) // Deliberately before start.
        XCTAssertEqual(harness.client.preroll.snapshot.chunkCount, 1)
        let heard = expectation(description: "Explicit prestart and pending chunks received")
        harness.start(heard: heard)
        try await harness.peer.wait(first, stages: ["held"])
        harness.offer([901, 902])
        try await assertHeld(harness, identifier: first)
        try await harness.peer.act(first, action: "release")
        await fulfillment(of: [heard], timeout: 4)
        _ = await harness.client.finishAndWait()
        try await assertReceipt(harness, identifier: first, ids: [900, 901, 902])
        harness.client.stop()
        harness.offer([903]) // Closed-session audio is a separate discard case.
        XCTAssertEqual(harness.client.preroll.snapshot.chunkCount, 0)
        try await completeRestart(harness, identifier: second, ids: [1000])
        XCTAssertTrue(harness.events.errors.isEmpty, "\(harness.events.errors)")
    }

    func testFailedHeldUpgradeReportsTransportFailureAndClearsPendingAudioBeforeRestart() async throws {
        let harness = try ModulateOpeningHarness(sessionCount: 2)
        addTeardownBlock { await harness.cleanup() }
        let first = harness.identifiers[0], second = harness.identifiers[1]
        try await harness.peer.configure(first, ids: [2000, 2001], ackAfter: 2)
        let failed = expectation(description: "HTTP503 reaches actual Apple transport error callback")
        harness.start(failed: failed)
        try await harness.peer.wait(first, stages: ["held"])
        harness.offer([2000, 2001])
        try await assertHeld(harness, identifier: first)
        try await harness.peer.act(first, action: "fail")
        await fulfillment(of: [failed], timeout: 4)
        XCTAssertEqual(harness.events.errors.count, 1)
        let rejected = try await harness.peer.state(first)
        XCTAssertFalse(rejected.upgradeComplete)
        XCTAssertTrue(rejected.receivedIDs.isEmpty)
        harness.offer([2099])
        try await completeRestart(harness, identifier: second, ids: [2100, 2101])
        XCTAssertEqual(harness.events.errors.count, 1, "The failed run cannot contaminate the replacement")
    }

    func testStopDuringHeldUpgradeSeparatesRestartFromLateOldUpgrade() async throws {
        let harness = try ModulateOpeningHarness(sessionCount: 2)
        addTeardownBlock { await harness.cleanup() }
        let first = harness.identifiers[0], second = harness.identifiers[1]
        try await harness.peer.configure(first, ids: [3000], ackAfter: 1)
        harness.start()
        try await harness.peer.wait(first, stages: ["held"])
        harness.offer([3000])
        try await assertHeld(harness, identifier: first)
        harness.client.stop()
        harness.offer([3999])
        try await harness.peer.configure(second, ids: [3100], ackAfter: 1)
        let heard = expectation(description: "Replacement run owns its opening audio")
        harness.start(heard: heard)
        try await harness.peer.wait(second, stages: ["held"])
        harness.offer([3100])
        try await harness.peer.act(first, action: "release") // Old callbacks may now arrive.
        try await harness.peer.act(second, action: "release")
        await fulfillment(of: [heard], timeout: 4)
        _ = await harness.client.finishAndWait()
        try await assertReceipt(harness, identifier: second, ids: [3100])
        try await harness.peer.wait(first, stages: ["failed", "cancelled"])
        let abandoned = try await harness.peer.state(first)
        XCTAssertTrue(abandoned.receivedIDs.isEmpty)
        XCTAssertEqual(harness.events.sends(first), 0)
        XCTAssertTrue(harness.events.errors.isEmpty, "Late failure belongs only to the stopped run")
    }

    private func assertHeld(_ harness: ModulateOpeningHarness, identifier: String) async throws {
        let receipt = try await harness.peer.state(identifier)
        XCTAssertEqual(receipt.stage, "held")
        XCTAssertFalse(receipt.upgradeComplete)
        XCTAssertEqual(receipt.receivedPCMBytes, 0)
        XCTAssertTrue(receipt.receivedIDs.isEmpty)
        XCTAssertEqual(harness.events.opens(identifier), 0)
        XCTAssertEqual(harness.events.sends(identifier), 0, "Shared lifecycle waits for actual HTTP101")
        let states = await harness.taskStates(identifier, test: self)
        XCTAssertEqual(states, [.running], "Running is not proof of handshake completion")
        print("Modulate held101: task=running openCallbacks=0 nativeSends=0 receivedPCMBytes=0")
    }

    private func assertReceipt(_ harness: ModulateOpeningHarness, identifier: String, ids: [Int]) async throws {
        let receipt = try await harness.peer.state(identifier)
        XCTAssertEqual(receipt.stage, "completed")
        XCTAssertTrue(receipt.upgradeComplete)
        XCTAssertTrue(receipt.endVerified)
        XCTAssertEqual(receipt.receivedIDs, ids, "No missing, duplicate, stale or reordered synthetic chunks")
        XCTAssertEqual(receipt.receivedPCMBytes, ids.count * 3200)
        XCTAssertEqual(receipt.wavHeaders, 1)
        XCTAssertEqual(harness.events.sends(identifier), ids.count + 1, "One send per chunk, then one end")
        XCTAssertEqual(harness.events.opens(identifier), 1)
        print("Modulate receipt: ids=\(receipt.receivedIDs) pcmBytes=\(receipt.receivedPCMBytes) wavHeaders=1")
        print("Modulate measured HTTP101 holdMilliseconds=\(receipt.upgradeHoldMilliseconds)")
    }

    private func completeRestart(_ harness: ModulateOpeningHarness, identifier: String, ids: [Int]) async throws {
        try await harness.peer.configure(identifier, ids: ids, ackAfter: ids.count)
        let heard = expectation(description: "Restart audio received without old queued chunks")
        harness.start(heard: heard)
        try await harness.peer.wait(identifier, stages: ["held"])
        harness.offer(ids)
        try await assertHeld(harness, identifier: identifier)
        try await harness.peer.act(identifier, action: "release")
        await fulfillment(of: [heard], timeout: 4)
        _ = await harness.client.finishAndWait()
        try await assertReceipt(harness, identifier: identifier, ids: ids)
    }
}
