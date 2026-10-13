import Foundation
import XCTest
import SpeakCore
import SpeakDesktopHost

final class DesktopHostVoiceTextImportTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-import-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        controller = try DesktopHostController<FakePlatform>(
            directory: directory, effects: SyntheticEffects(), shutdownGrace: .milliseconds(100)
        )
    }

    override func tearDown() async throws {
        await controller.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func testImport_ReturnsValidatedTextWithoutChangingVoiceOwnership() async throws {
        let replies = ImportReplies()
        let owner = UUID()
        await setOwner(owner)
        await controller.importVoiceText(path: "/synthetic.txt", requestID: "import") { _ in
            "Synthetic file snapshot"
        } completion: { replies.append($0) }
        try await waitForFinish()
        XCTAssertEqual(replies.values, ["Synthetic file snapshot"])
        let retainedOwner = await controller.voiceOutputRecordID
        XCTAssertEqual(retainedOwner, owner)
    }

    func testCancel_IsTokenSpecificAndKeepsOneCountedOperationUntilItEnds() async throws {
        let replies = ImportReplies()
        let gate = Gate(open: false)
        await controller.importVoiceText(path: "/synthetic.txt", requestID: "active") { _ in
            await gate.pass()
            return "Late result"
        } completion: { replies.append($0) }
        await controller.cancelVoiceTextImport(requestID: "other")
        let firstCancelled = await controller.voiceTextImportTask?.isCancelled
        XCTAssertEqual(firstCancelled, false)
        await controller.importVoiceText(path: "/second.txt", requestID: "second") { _ in
            XCTFail("A second file read was admitted while the first still owned its worker")
            return "Second"
        } completion: { replies.append($0) }
        let active = await controller.activeOperations
        XCTAssertEqual(active, 1)
        XCTAssertEqual(replies.values.count, 1)
        await controller.cancelVoiceTextImport(requestID: "active")
        gate.release()
        try await waitForFinish()
        XCTAssertFalse(replies.values.contains("Late result"))
    }

    func testStopAndClose_NeverPublishLateFileTextAndShutdownIsBounded() async throws {
        let replies = ImportReplies()
        let gate = HeldImportRead()
        let entered = expectation(description: "The read owns its worker")
        await controller.importVoiceText(path: "/synthetic.txt", requestID: "active") { _ in
            entered.fulfill()
            await gate.wait()
            return "Late result"
        } completion: { replies.append($0) }
        await fulfillment(of: [entered], timeout: 2)
        await controller.playbackStop()
        let start = ContinuousClock.now
        let report = await controller.close()
        XCTAssertFalse(report.isComplete)
        XCTAssertEqual(report.unfinishedOperations, 1)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        await gate.release()
        try await waitForFinish()
        XCTAssertTrue(replies.values.isEmpty)
    }

    private actor HeldImportRead {
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { waiter = $0 } }
        func release() { waiter?.resume(); waiter = nil }
    }

    private func setOwner(_ owner: UUID) async {
        await controller.setVoiceOwnerForImportTest(owner)
    }

    private func waitForFinish() async throws {
        for _ in 0..<500 {
            if await controller.activeOperations == 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Text import did not release its counted operation")
    }
}

private extension DesktopHostController {
    func setVoiceOwnerForImportTest(_ owner: UUID) { voiceOutputRecordID = owner }
}

private final class ImportReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ result: Result<String, Error>) {
        let value: String
        switch result {
        case .success(let text): value = text
        case .failure(let error): value = error.localizedDescription
        }
        lock.withLock { storage.append(value) }
    }
}
