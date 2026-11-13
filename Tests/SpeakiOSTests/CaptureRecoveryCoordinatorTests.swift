#if os(iOS)
import Foundation
import SpeakCore
import XCTest

@testable import SpeakiOSLib

/// Issue #1617: the launch prompt for interrupted audio came back on every
/// launch, and "Transcribe it" appeared to do nothing. What is proved here is
/// that an in-app capture settles its claim, that a recovery reports what it
/// did, that "Not now" sticks, and that only Discard deletes audio.
@MainActor
final class CaptureRecoveryCoordinatorTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private let crashedProcess = UUID()
    private let longAgo = Date(timeIntervalSinceNow: -3600)

    private var files: [String: Int64] = [:]
    private var unreadableFiles: Set<String> = []
    private var deleted: [String] = []
    private var saved: [iOSHistoryItem] = []
    private var transcribe: @MainActor (URL) async throws -> String = { _ in "recovered words" }

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "CaptureRecoveryCoordinatorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        files = [:]
        unreadableFiles = []
        deleted = []
        saved = []
        transcribe = { _ in "recovered words" }
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private var claimStore: CaptureSafetyClaimStore {
        CaptureSafetyClaimStore(defaults: defaults, owner: CaptureSafetyClaimStore.currentOwner)
    }

    /// A capture whose process died an hour ago, leaving `name` on disk.
    @discardableResult
    private func interruptedCapture(_ name: String, startedAt: Date? = nil, bytes: Int64 = 400_000) -> UUID {
        let run = UUID()
        let started = startedAt ?? longAgo
        CaptureSafetyClaimStore(defaults: defaults, owner: crashedProcess)
            .open(recording: run, fileName: name, startedAt: started, now: started)
        files[name] = bytes
        return run
    }

    private func makeCoordinator() -> CaptureRecoveryCoordinator {
        CaptureRecoveryCoordinator(claimStore: claimStore, dependencies: .init(
            listFiles: { [unowned self] in
                self.files.map { CaptureSafetyFile(fileName: $0.key, byteSize: $0.value) }
            },
            fileURL: { URL(fileURLWithPath: "/recordings").appendingPathComponent($0) },
            fileExists: { [unowned self] in self.files[$0.lastPathComponent] != nil },
            isTranscribableAudio: { [unowned self] in !self.unreadableFiles.contains($0.lastPathComponent) },
            deleteRecording: { [unowned self] in
                self.deleted.append($0.lastPathComponent)
                self.files[$0.lastPathComponent] = nil
            },
            transcribe: { [unowned self] in try await self.transcribe($0) },
            recoveryModel: { "openai/whisper-1" },
            saveToHistory: { [unowned self] in self.saved.append($0); return true },
            preferences: defaults
        ))
    }

    // MARK: - Transcribe it

    func testRecover_savesToHistoryUnderTheRunAndStopsOfferingIt() async throws {
        let run = interruptedCapture("Recording-A.m4a")
        let coordinator = makeCoordinator()
        coordinator.refresh()
        let finding = try XCTUnwrap(coordinator.promptable.first)

        let recovered = await coordinator.recover(finding)

        XCTAssertTrue(recovered)
        XCTAssertEqual(saved.map(\.id), [run])
        XCTAssertEqual(saved.first?.transcription, "recovered words")
        XCTAssertEqual(coordinator.outcome, .recovered(historyID: run))
        XCTAssertTrue(coordinator.recoverable.isEmpty)
        XCTAssertTrue(claimStore.claims().isEmpty, "The finding is cleared")
        XCTAssertTrue(deleted.isEmpty, "The audio stays in Saved Recordings")
    }

    func testRecover_providerFailureIsReportedAndKeepsTheFindingAndAudio() async throws {
        interruptedCapture("Recording-A.m4a")
        transcribe = { _ in throw IOSBatchTranscriptionError.httpError("OpenAI", 400, "secret body") }
        let coordinator = makeCoordinator()
        coordinator.refresh()
        let finding = try XCTUnwrap(coordinator.promptable.first)

        let recovered = await coordinator.recover(finding)

        XCTAssertFalse(recovered)
        guard case .failed(let failed, let message)? = coordinator.outcome else {
            return XCTFail("A failure must be reported, got \(String(describing: coordinator.outcome))")
        }
        XCTAssertEqual(failed.run, finding.run)
        XCTAssertTrue(message.contains("HTTP 400"))
        XCTAssertFalse(message.contains("secret body"), "The raw provider body is never shown")
        XCTAssertEqual(coordinator.recoverable.map(\.run), [finding.run], "Still retryable")
        XCTAssertTrue(deleted.isEmpty, "A failure never deletes audio")
        XCTAssertNil(coordinator.recovering)
    }

    func testRecover_missingKeyAndEmptyTextAreReportedNotSwallowed() async throws {
        interruptedCapture("Recording-A.m4a")
        let coordinator = makeCoordinator()
        coordinator.refresh()
        let finding = try XCTUnwrap(coordinator.promptable.first)

        transcribe = { _ in throw IOSBatchTranscriptionError.apiKeyMissing }
        await coordinator.recover(finding)
        guard case .failed(_, let keyMessage)? = coordinator.outcome else { return XCTFail("Expected failure") }
        XCTAssertTrue(keyMessage.contains("API key"))

        transcribe = { _ in "   " }
        await coordinator.recover(finding)
        guard case .failed(_, let emptyMessage)? = coordinator.outcome else { return XCTFail("Expected failure") }
        XCTAssertTrue(emptyMessage.contains("no text"))
        XCTAssertTrue(saved.isEmpty)
    }

    // MARK: - What is offered

    func testUnreadableAudioIsNeverOfferedButCanBeDiscarded() throws {
        interruptedCapture("Corrupt.m4a")
        let readable = interruptedCapture("Good.m4a", startedAt: longAgo.addingTimeInterval(60))
        unreadableFiles = ["Corrupt.m4a"]
        let coordinator = makeCoordinator()
        coordinator.refresh()

        XCTAssertEqual(coordinator.promptable.map(\.run), [readable])
        XCTAssertEqual(coordinator.unreadable.map(\.fileName), ["Corrupt.m4a"])
        XCTAssertTrue(deleted.isEmpty, "Unreadable audio is kept until the user discards it")

        coordinator.discard(try XCTUnwrap(coordinator.unreadable.first))
        XCTAssertEqual(deleted, ["Corrupt.m4a"])
        XCTAssertTrue(coordinator.unreadable.isEmpty)
    }

    func testAnEmptyFileIsNeverOffered() {
        interruptedCapture("Empty.m4a", bytes: 0)
        let coordinator = makeCoordinator()
        coordinator.refresh()
        XCTAssertTrue(coordinator.promptable.isEmpty)
    }

    // MARK: - Not now and Discard

    func testNotNow_putsOffEverythingOfferedUntilANewerInterruption() throws {
        interruptedCapture("Old-1.m4a", startedAt: longAgo)
        interruptedCapture("Old-2.m4a", startedAt: longAgo.addingTimeInterval(60))
        let coordinator = makeCoordinator()
        coordinator.refresh()
        XCTAssertEqual(coordinator.promptable.count, 2)

        coordinator.snooze(coordinator.promptable)
        let relaunched = makeCoordinator()
        relaunched.refresh()
        XCTAssertTrue(relaunched.promptable.isEmpty, "The same findings are not asked about on the next launch")
        XCTAssertEqual(relaunched.recoverable.count, 2, "Still listed in Capture Health")
        XCTAssertTrue(deleted.isEmpty, "Not now deletes nothing")

        let newer = interruptedCapture("New.m4a", startedAt: longAgo.addingTimeInterval(120))
        relaunched.refresh()
        XCTAssertEqual(relaunched.promptable.map(\.run), [newer])
    }

    func testDiscard_deletesOnlyThatRecordingAndClearsItsClaim() throws {
        let first = interruptedCapture("A.m4a")
        let second = interruptedCapture("B.m4a", startedAt: longAgo.addingTimeInterval(60))
        let coordinator = makeCoordinator()
        coordinator.refresh()

        coordinator.discard(try XCTUnwrap(coordinator.recoverable.first { $0.run == first }))

        XCTAssertEqual(deleted, ["A.m4a"])
        XCTAssertEqual(claimStore.claims().map(\.run), [second])
        XCTAssertEqual(coordinator.promptable.map(\.run), [second])
    }

    // MARK: - The in-app capture settles its claim

    func testForegroundDelivery_marksTheCaptureDeliveredOnlyOnceHistoryHasIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureRecoveryCoordinatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = SharedTranscriptionState(defaults: defaults)

        for (writable, text, expectDelivered) in [(true, "hello there", true), (false, "hello there", false)] {
            let history = iOSHistoryManager(
                fileURL: directory.appendingPathComponent("\(UUID().uuidString).json"), syncEnabled: false,
                storageIO: .init(write: { data, url in
                    guard writable else { throw CocoaError(.fileWriteNoPermission) }
                    try data.write(to: url, options: .atomic)
                })
            )
            let finalisation = ForegroundCaptureFinalisation(sharedState: state, historyManager: history)
            var delivered: [UUID] = []
            finalisation.markDelivered = { delivered.append($0) }
            let session = ForegroundTestSession()
            let recording = UUID()
            session.safetyRecordingID = recording

            await finalisation.deliver(
                ForegroundTestSession.result(text), from: session, model: "apple/local",
                error: nil, offlineIntendedModel: nil
            )

            XCTAssertEqual(delivered, expectDelivered ? [recording] : [],
                           "writable History: \(writable)")
        }
    }
}
#endif
