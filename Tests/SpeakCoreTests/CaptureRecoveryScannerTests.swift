import Foundation
@testable import SpeakCore
import XCTest

/// Issue #992. The recovery pass touches audio a person recorded and never got
/// back, so the branches worth proving are the ones where it would be wrong:
/// a claim that belongs to a capture happening right now, a clock that moved,
/// a file it cannot make sense of. None of them may end in a deletion, and
/// none of them may end in a live recording being called an orphan.
final class CaptureRecoveryScannerTests: XCTestCase {
    private let thisProcess = UUID()
    private let otherProcess = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func claim(
        run: UUID = UUID(),
        name: String = "Recording-A.m4a",
        owner: UUID? = nil,
        heartbeatAgo: TimeInterval,
        delivered: Bool = false
    ) -> CaptureSafetyClaim {
        CaptureSafetyClaim(
            run: run,
            fileName: name,
            startedAt: self.now.addingTimeInterval(-heartbeatAgo - 60),
            owner: owner ?? self.otherProcess,
            lastHeartbeat: self.now.addingTimeInterval(-heartbeatAgo),
            deliveredTranscript: delivered
        )
    }

    private func scan(
        claims: [CaptureSafetyClaim],
        files: [CaptureSafetyFile],
        liveRuns: Set<UUID> = []
    ) -> CaptureRecoveryPlan {
        CaptureRecoveryScanner.scan(
            CaptureRecoveryInput(
                claims: claims,
                files: files,
                currentOwner: self.thisProcess,
                liveRuns: liveRuns,
                now: self.now
            )
        )
    }

    private var healthyFile: CaptureSafetyFile {
        CaptureSafetyFile(fileName: "Recording-A.m4a", byteSize: 512_000)
    }

    // MARK: - A live capture is never an orphan

    func testClaimForARunTheCallerKnowsIsCapturingIsLive() {
        let run = UUID()
        // Deliberately every other signal points at "orphan": a foreign
        // process and an ancient heartbeat. Liveness still wins.
        let plan = self.scan(
            claims: [self.claim(run: run, heartbeatAgo: 86_400)],
            files: [self.healthyFile],
            liveRuns: [run]
        )
        XCTAssertEqual(plan.findings.first?.disposition, .live(.runIsCapturingNow))
        XCTAssertTrue(plan.recoverable.isEmpty)
        XCTAssertTrue(plan.hasLiveCapture)
    }

    func testClaimOpenedByThisProcessLaunchIsLiveEvenWithAStaleHeartbeat() {
        let plan = self.scan(
            claims: [self.claim(owner: self.thisProcess, heartbeatAgo: 86_400)],
            files: [self.healthyFile]
        )
        XCTAssertEqual(plan.findings.first?.disposition, .live(.sameProcess))
        XCTAssertTrue(plan.recoverable.isEmpty)
    }

    func testFreshHeartbeatFromAnotherProcessIsLive() {
        // The keyboard extension capturing while the app is launched behind it.
        let plan = self.scan(
            claims: [self.claim(heartbeatAgo: CaptureRecoveryPolicy.heartbeatIntervalSeconds)],
            files: [self.healthyFile]
        )
        XCTAssertEqual(plan.findings.first?.disposition, .live(.recentHeartbeat))
    }

    func testHeartbeatExactlyAtTheStalenessWindowIsStillLive() {
        let plan = self.scan(
            claims: [self.claim(heartbeatAgo: CaptureRecoveryPolicy.stalenessWindowSeconds)],
            files: [self.healthyFile]
        )
        XCTAssertEqual(plan.findings.first?.disposition, .live(.recentHeartbeat))
    }

    func testHeartbeatJustPastTheWindowIsRecoverable() {
        let plan = self.scan(
            claims: [self.claim(heartbeatAgo: CaptureRecoveryPolicy.stalenessWindowSeconds + 1)],
            files: [self.healthyFile]
        )
        XCTAssertEqual(plan.findings.first?.disposition, .recoverable)
        XCTAssertEqual(plan.recoverable.count, 1)
    }

    // MARK: - Ambiguity keeps the audio

    func testHeartbeatInTheFutureIsUncertainRatherThanOrphaned() {
        var future = self.claim(heartbeatAgo: 0)
        future.lastHeartbeat = self.now.addingTimeInterval(600)
        let plan = self.scan(claims: [future], files: [self.healthyFile])
        XCTAssertEqual(plan.findings.first?.disposition, .uncertain(.clockUnreliable))
        XCTAssertTrue(plan.recoverable.isEmpty)
        XCTAssertEqual(plan.uncertain.count, 1)
    }

    func testSmallClockSkewInsideToleranceIsNotTreatedAsAMovedClock() {
        var skewed = self.claim(heartbeatAgo: 0)
        skewed.lastHeartbeat = self.now.addingTimeInterval(
            CaptureRecoveryPolicy.clockToleranceSeconds - 1
        )
        let plan = self.scan(claims: [skewed], files: [self.healthyFile])
        XCTAssertEqual(plan.findings.first?.disposition, .live(.recentHeartbeat))
    }

    func testAnAlreadyDeliveredTranscriptIsNotOfferedAgainButKeepsItsAudio() {
        let plan = self.scan(
            claims: [self.claim(heartbeatAgo: 86_400, delivered: true)],
            files: [self.healthyFile]
        )
        XCTAssertEqual(plan.findings.first?.disposition, .uncertain(.transcriptAlreadyDelivered))
        XCTAssertTrue(plan.recoverable.isEmpty)
        XCTAssertTrue(plan.claimsToForget.isEmpty, "the file is still there, so nothing is forgotten")
    }

    func testAnEmptyContainerIsKeptRatherThanTidiedAway() {
        let plan = self.scan(
            claims: [self.claim(heartbeatAgo: 86_400)],
            files: [CaptureSafetyFile(fileName: "Recording-A.m4a", byteSize: 128)]
        )
        XCTAssertEqual(plan.findings.first?.disposition, .uncertain(.fileHoldsNoAudio))
        XCTAssertTrue(plan.claimsToForget.isEmpty)
    }

    func testAFileExactlyAtTheMinimumIsRecoverable() {
        let plan = self.scan(
            claims: [self.claim(heartbeatAgo: 86_400)],
            files: [CaptureSafetyFile(
                fileName: "Recording-A.m4a",
                byteSize: CaptureRecoveryPolicy.minimumRecoverableBytes
            )]
        )
        XCTAssertEqual(plan.findings.first?.disposition, .recoverable)
    }

    // MARK: - Bookkeeping, never audio

    func testAClaimWhoseFileIsGoneLeavesOnlyABookkeepingRecordToForget() {
        let run = UUID()
        let plan = self.scan(claims: [self.claim(run: run, heartbeatAgo: 86_400)], files: [])
        XCTAssertEqual(plan.findings.first?.disposition, .nothingRecorded)
        XCTAssertEqual(plan.claimsToForget, [run])
        XCTAssertTrue(plan.recoverable.isEmpty)
        XCTAssertTrue(plan.uncertain.isEmpty)
    }

    func testOnlyClaimsWithNoFileAreEverForgotten() {
        // Every disposition that still has bytes on disk keeps its record, so
        // the recovery offer survives a relaunch that the user did not answer.
        let cases: [(CaptureSafetyClaim, [CaptureSafetyFile])] = [
            (self.claim(heartbeatAgo: 86_400), [self.healthyFile]),
            (self.claim(heartbeatAgo: 86_400, delivered: true), [self.healthyFile]),
            (self.claim(heartbeatAgo: 0), [self.healthyFile]),
            (self.claim(owner: self.thisProcess, heartbeatAgo: 0), [self.healthyFile])
        ]
        for (claim, files) in cases {
            let plan = self.scan(claims: [claim], files: files)
            XCTAssertTrue(plan.claimsToForget.isEmpty, "\(plan.findings)")
        }
    }

    // MARK: - Ordinary saved recordings are not this pass's business

    func testFilesWithNoClaimAreNotReportedAtAll() {
        // Everything in the recordings library that finished cleanly looks
        // like this. Reporting them would offer to re-transcribe the user's
        // whole history on every launch.
        let plan = self.scan(
            claims: [],
            files: [
                CaptureSafetyFile(fileName: "Recording-B.m4a", byteSize: 900_000),
                CaptureSafetyFile(fileName: "Recording-C.m4a", byteSize: 900_000)
            ]
        )
        XCTAssertTrue(plan.findings.isEmpty)
        XCTAssertFalse(plan.hasLiveCapture)
    }

    // MARK: - Several at once

    func testRecoverableCapturesComeBackOldestFirst() {
        let older = CaptureSafetyClaim(
            run: UUID(),
            fileName: "older.m4a",
            startedAt: self.now.addingTimeInterval(-7200),
            owner: self.otherProcess,
            lastHeartbeat: self.now.addingTimeInterval(-7000)
        )
        let newer = CaptureSafetyClaim(
            run: UUID(),
            fileName: "newer.m4a",
            startedAt: self.now.addingTimeInterval(-3600),
            owner: self.otherProcess,
            lastHeartbeat: self.now.addingTimeInterval(-3400)
        )
        let plan = self.scan(
            claims: [newer, older],
            files: [
                CaptureSafetyFile(fileName: "older.m4a", byteSize: 500_000),
                CaptureSafetyFile(fileName: "newer.m4a", byteSize: 500_000)
            ]
        )
        XCTAssertEqual(plan.recoverable.map(\.fileName), ["older.m4a", "newer.m4a"])
    }

    func testALiveCaptureAlongsideARecoverableOneIsReportedSeparately() {
        let live = UUID()
        let plan = self.scan(
            claims: [
                self.claim(run: live, name: "live.m4a", heartbeatAgo: 1),
                self.claim(name: "dead.m4a", heartbeatAgo: 86_400)
            ],
            files: [
                CaptureSafetyFile(fileName: "live.m4a", byteSize: 100_000),
                CaptureSafetyFile(fileName: "dead.m4a", byteSize: 100_000)
            ],
            liveRuns: [live]
        )
        XCTAssertTrue(plan.hasLiveCapture)
        XCTAssertEqual(plan.recoverable.map(\.fileName), ["dead.m4a"])
    }

    func testClaimsCarryTheSizeOfTheFileTheyNameAndZeroWhenItIsGone() {
        let plan = self.scan(
            claims: [self.claim(heartbeatAgo: 86_400)],
            files: [CaptureSafetyFile(fileName: "Recording-A.m4a", byteSize: 777)]
        )
        XCTAssertEqual(plan.findings.first?.byteSize, 777)

        let missing = self.scan(claims: [self.claim(heartbeatAgo: 86_400)], files: [])
        XCTAssertEqual(missing.findings.first?.byteSize, 0)
    }

    // MARK: - Identity

    func testTheClaimSurvivesACodableRoundTrip() throws {
        // It is written by one process and read by the next launch, so this is
        // the only thing standing between a crash and a recoverable file.
        let original = self.claim(heartbeatAgo: 30, delivered: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CaptureSafetyClaim.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testTheClaimRecordsAFileNameRatherThanAPath() {
        // Containers move between installs; an absolute path recorded
        // yesterday resolves to nothing today.
        let claim = self.claim(heartbeatAgo: 0)
        XCTAssertFalse(claim.fileName.contains("/"))
    }
}
