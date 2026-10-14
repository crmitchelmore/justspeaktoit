import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import XCTest

final class DesktopHostVoiceUsageSnapshotTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        FakeLog.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-snapshot-\(UUID())")
        controller = try DesktopHostController<FakePlatform>(
            directory: directory, effects: SyntheticEffects(), shutdownGrace: .milliseconds(60))
        await controller.markReadyForSelfTest()
    }

    override func tearDown() async throws {
        await controller.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func testFailedLoad_KeepsNewObservationsAndCorruptOriginalWithoutEmptySuccess() async throws {
        let bytes = Data("synthetic damaged source".utf8)
        try write(bytes)
        let operation = try await begin()
        complete(operation)
        await controller.finishVoiceUsage(operation)
        let snapshot = try await snapshot()
        XCTAssertEqual(snapshot.presence, .invalid)
        XCTAssertEqual(snapshot.originalBytes, bytes)
        XCTAssertTrue(snapshot.memory.loadFailed)
        XCTAssertEqual(snapshot.memory.unsavedRecords, operation.capture.records)
        XCTAssertNil(snapshot.memory.loadedRecords)
        XCTAssertThrowsError(try snapshot.preparedAppend())
        XCTAssertEqual(try Data(contentsOf: path), bytes)
    }

    func testFailedSave_TracksUnsavedThenNormalRetryPersistsOnceWithoutChangingDefaultWriter() async throws {
        let folder = directory.appendingPathComponent("VoiceUsage")
        try Data("synthetic blocked directory".utf8).write(to: folder)
        let first = try await begin()
        complete(first)
        await controller.finishVoiceUsage(first)
        let failed = await controller.voiceUsage
        XCTAssertEqual(failed.unsaved, first.capture.records)
        XCTAssertTrue(failed.warning?.contains("only in memory") == true)
        try FileManager.default.removeItem(at: folder)
        let second = try await begin()
        complete(second)
        await controller.finishVoiceUsage(second)
        await controller.finishVoiceUsage(first)
        let restored = try DesktopVoiceUsageLedger(validating: Data(contentsOf: path))
        XCTAssertEqual(restored.records.map(\.id),
                       first.capture.records.map(\.id) + second.capture.records.map(\.id))
        let state = await controller.voiceUsage
        XCTAssertTrue(state.unsaved.isEmpty)
        XCTAssertEqual(state.unsavedBytes, 2)
        XCTAssertTrue(state.unsavedSizes.isEmpty)
        XCTAssertTrue(state.active.isEmpty)
    }

    func testActiveAndCancelledAttempts_ArePointInTimeNotInventedCompletedUsage() async throws {
        let operation = try await begin()
        let id = operation.capture.begin(voice: .groq(GroqTTSCatalog.defaultVoice),
                                         inputCharacters: 10, usesSSML: false)
        let active = try await snapshot()
        XCTAssertEqual(active.presence, .missing)
        XCTAssertEqual(active.memory.activeCaptures.count, 1)
        XCTAssertEqual(active.memory.activeCaptures.first?.records, operation.capture.records)
        XCTAssertNil(active.memory.activeCaptures.first?.records.first?.audioDuration)
        XCTAssertNil(active.memory.activeCaptures.first?.records.first?.reportedInputTokens)
        operation.capture.finish(id, outcome: .cancelled)
        await controller.finishVoiceUsage(operation)
        let final = try await snapshot()
        XCTAssertEqual(final.acceptedLedger?.records.map(\.outcome), [.cancelled])
        XCTAssertTrue(final.memory.activeCaptures.isEmpty)
        XCTAssertTrue(final.memory.unsavedRecords.isEmpty)
    }

    func testOptOutInvalidatesActiveProvenanceEvenAfterReenable() async throws {
        let operation = try await begin()
        complete(operation)
        await controller.saveVoiceUsageTracking(false, requestID: "off")
        let disabled = try await snapshot()
        XCTAssertTrue(disabled.memory.activeCaptures.isEmpty)
        await controller.saveVoiceUsageTracking(true, requestID: "on")
        await controller.finishVoiceUsage(operation)
        let final = try await snapshot()
        XCTAssertTrue(final.memory.unsavedRecords.isEmpty)
        XCTAssertTrue(final.memory.activeCaptures.isEmpty)
        XCTAssertEqual(final.presence, .missing)
    }

    func testCaptureMutationWhileReading_RejectsStaleActorSnapshot() async throws {
        let operation = try await begin()
        let id = operation.capture.begin(voice: .groq(GroqTTSCatalog.defaultVoice),
                                         inputCharacters: 5, usesSSML: false)
        let access = DesktopVoiceUsageReadAccess { _, _ in
            operation.capture.finish(id, outcome: .cancelled)
            return .init(data: nil, revalidate: {})
        }
        do {
            _ = try await controller.voiceUsageSnapshot(access: access, digests: FakeLocalPlatform.localModelDigests)
            XCTFail("Changed active observations returned a complete snapshot")
        } catch { XCTAssertEqual(error as? DesktopVoiceUsageSnapshot.Failure, .stateChanged) }
        await controller.finishVoiceUsage(operation)
    }

    func testCancellation_CountsWorkerAndPreventsUnboundedCollectionAdmission() async throws {
        let entered = expectation(description: "Synthetic owned reader entered")
        let gate = VoiceUsageReadGate()
        let access = DesktopVoiceUsageReadAccess { _, _ in
            entered.fulfill()
            try gate.wait()
            return .init(data: nil, revalidate: {})
        }
        let controller = try XCTUnwrap(controller)
        let task = Task { try await controller.voiceUsageSnapshot(
            access: access, digests: FakeLocalPlatform.localModelDigests) }
        await fulfillment(of: [entered], timeout: 3)
        do {
            _ = try await controller.voiceUsageSnapshot(access: access, digests: FakeLocalPlatform.localModelDigests)
            XCTFail("Concurrent collection admitted another worker")
        } catch { XCTAssertEqual(error as? DesktopVoiceUsageSnapshot.Failure, .stillClosing) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled worker returned a source")
        } catch { XCTAssertTrue(error is CancellationError) }
        let operations = await controller.activeOperations
        XCTAssertEqual(operations, 0)
        let collecting = await controller.voiceUsage.collecting
        XCTAssertFalse(collecting)
    }

    func testOverflow_IsBoundedExplicitAndDoesNotOverwriteCorruptSource() async throws {
        let original = Data("synthetic corrupt ledger".utf8)
        try write(original)
        for _ in 0...VoiceUsagePolicy.maximumRetainedRequests {
            let operation = try await begin()
            complete(operation)
            await controller.finishVoiceUsage(operation)
        }
        let snapshot = try await snapshot()
        XCTAssertEqual(snapshot.memory.unsavedRecords.count, 1_000)
        XCTAssertEqual(snapshot.memory.omittedUnsavedObservations, 1)
        XCTAssertNotNil(snapshot.memory.unsavedProblem)
        XCTAssertTrue(snapshot.memory.activeCaptures.isEmpty)
        let summary = await controller.voiceUsageSummary()
        XCTAssertTrue(summary.contains("Unsaved-buffer observations omitted: 1"))
        XCTAssertEqual(try Data(contentsOf: path), original)
    }

    func testTrackingEpochChangeDuringRead_RejectsThePreviousSnapshot() async throws {
        let entered = expectation(description: "Reader paused before tracking changed")
        let gate = VoiceUsageReadGate()
        let access = DesktopVoiceUsageReadAccess { _, _ in
            entered.fulfill()
            try gate.wait()
            return .init(data: nil, revalidate: {})
        }
        let controller = try XCTUnwrap(controller)
        let task = Task { try await controller.voiceUsageSnapshot(
            access: access, digests: FakeLocalPlatform.localModelDigests) }
        await fulfillment(of: [entered], timeout: 3)
        await controller.saveVoiceUsageTracking(false, requestID: "off")
        gate.release()
        do {
            _ = try await task.value
            XCTFail("Previous tracking epoch returned a complete snapshot")
        } catch { XCTAssertEqual(error as? DesktopVoiceUsageSnapshot.Failure, .stateChanged) }
    }

    func testClose_ReportsStalledReaderAndRejectsItsLateResult() async throws {
        let entered = expectation(description: "Stalled reader entered")
        let gate = VoiceUsageReadGate()
        let access = DesktopVoiceUsageReadAccess { _, _ in
            entered.fulfill()
            try gate.wait()
            return .init(data: nil, revalidate: {})
        }
        let controller = try XCTUnwrap(controller)
        let task = Task { try await controller.voiceUsageSnapshot(
            access: access, digests: FakeLocalPlatform.localModelDigests) }
        await fulfillment(of: [entered], timeout: 3)
        let report = await controller.close()
        XCTAssertEqual(report.unfinishedOperations, 1)
        let pending = await controller.activeOperations
        XCTAssertEqual(pending, 1)
        gate.release()
        do {
            _ = try await task.value
            XCTFail("Closed host accepted a late snapshot")
        } catch { XCTAssertTrue(error is CancellationError) }
        let remaining = await controller.activeOperations
        XCTAssertEqual(remaining, 0)
    }

    func testUnsavedByteBudget_IsIndependentOfTheRecordCountLimit() async throws {
        let original = Data("synthetic corrupt ledger".utf8)
        try write(original)
        let operation = try await begin()
        let voice = DesktopSpeechVoice.groq(.init(
            id: String(repeating: "synthetic", count: 300_000), name: "Synthetic oversized metadata",
            gender: .female, model: .orpheusEnglish))
        let id = operation.capture.begin(voice: voice, inputCharacters: 1, usesSSML: false)
        operation.capture.finish(id, outcome: .failed)
        await controller.finishVoiceUsage(operation)
        let snapshot = try await snapshot()
        XCTAssertTrue(snapshot.memory.unsavedRecords.isEmpty)
        XCTAssertEqual(snapshot.memory.omittedUnsavedObservations, 1)
        XCTAssertNotNil(snapshot.memory.unsavedProblem)
        XCTAssertEqual(try Data(contentsOf: path), original)
    }

    private var path: URL { directory.appendingPathComponent("VoiceUsage/requests.json") }

    private func write(_ bytes: Data) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: path)
    }

    private func snapshot() async throws -> DesktopVoiceUsageSnapshot {
        let path = path
        // Synthetic file fixture only, not a native owned-file identity proof.
        let access = DesktopVoiceUsageReadAccess { _, _ in
            let data = FileManager.default.fileExists(atPath: path.path) ? try Data(contentsOf: path) : nil
            return .init(data: data, revalidate: {
                let current = FileManager.default.fileExists(atPath: path.path) ? try Data(contentsOf: path) : nil
                guard current == data else { throw DesktopVoiceUsageReadAccess.Failure.changed }
            })
        }
        return try await controller.voiceUsageSnapshot(access: access, digests: FakeLocalPlatform.localModelDigests)
    }

    private func begin() async throws -> DesktopVoiceUsageOperation {
        let started = await controller.beginVoiceUsage(operation: .generate, source: .typedText, recordID: nil)
        return try XCTUnwrap(started)
    }

    private func complete(_ operation: DesktopVoiceUsageOperation) {
        let id = operation.capture.begin(voice: .groq(GroqTTSCatalog.defaultVoice),
                                         inputCharacters: 12, usesSSML: false)
        operation.capture.finish(id, outcome: .completed, audioDuration: 0.1)
    }
}

private final class VoiceUsageReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false

    func release() { lock.withLock { released = true } }

    func wait() throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            try Task.checkCancellation()
            if lock.withLock({ released }) { return }
            Thread.sleep(forTimeInterval: 0.001)
        }
        throw DesktopHostError(message: "Synthetic reader gate timed out")
    }
}
