import Dispatch
import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

final class DesktopHostIssueReportTests: XCTestCase {
    override func setUp() { super.setUp(); FakeLog.shared.reset() }
    override func tearDown() { FakeLog.shared.reset(); super.tearDown() }

    func testLegacyProjectionExcludesCanariesAndNeverInventsRequestContext() throws {
        let record = self.record()
        let owner = DesktopHostIssueReportSession(record: record, actions: IssueReportEffects().actions)
        let report = owner.preview.report
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: report.jsonData) as? [String: Any])
        XCTAssertEqual(object["contextState"] as? String, "missingLegacyContext")
        XCTAssertNil(object["context"])
        XCTAssertNil(object["observedHandoff"])
        let failures = try XCTUnwrap(object["failures"] as? [[String: Any]])
        XCTAssertEqual(failures.count, 2)
        XCTAssertEqual(Set(failures.compactMap { $0["stage"] as? String }), ["request", "postProcessing"])
        XCTAssertTrue(failures.allSatisfy {
            $0["domain"] as? String == "unknown" && $0["code"] as? String == "unknown"
        })
        XCTAssertTrue(failures.allSatisfy { $0["httpStatus"] == nil })
        let all = report.title + report.body + report.jsonString + (report.issueURL?.absoluteString ?? "")
        for value in [Self.canary, record.id.uuidString, record.audioFilename, "PRIVATE_PATH", "api_key="] {
            XCTAssertFalse(all.contains(value))
        }
        XCTAssertLessThanOrEqual(report.jsonData.count, IssueDiagnosticReport.maximumJSONBytes)
        var synced = record
        synced.originPlatform = Self.canary
        let syncedReport = DesktopHostIssueReportSession(
            record: synced, actions: IssueReportEffects().actions).preview.report
        XCTAssertEqual(syncedReport.jsonData, report.jsonData)
    }

    func testAdmissionRequiresExactVisibleSelectionAndImplementedPresentation() async throws {
        let fixture = try self.fixture()
        let record = self.record()
        await fixture.seed(record)
        for id in ["", "not-an-id", UUID().uuidString] {
            let ticket = await fixture.controller.beginIssueReport(id, using: fixture.effects.actions)
            XCTAssertNil(ticket)
        }
        let unavailable = await fixture.controller.beginIssueReport(record.id.uuidString)
        XCTAssertNil(unavailable)
        await fixture.controller.searchHistory("missing-from-this-record")
        let hidden = await fixture.controller.beginIssueReport(record.id.uuidString, using: fixture.effects.actions)
        XCTAssertNil(hidden)
        XCTAssertTrue(fixture.effects.previews.isEmpty)
        XCTAssertTrue(fixture.effects.copies.isEmpty)
        XCTAssertTrue(fixture.effects.urls.isEmpty)
    }

    func testFrozenPreviewRemovalCopyBrowserAndJSONStayInParityAfterHistoryChanges() async throws {
        let fixture = try self.fixture()
        let record = self.record()
        await fixture.seed(record)
        let ticket = try await fixture.ticket(record.id)
        let metadata = fixture.root.appendingPathComponent("History/\(record.id.uuidString).json")
        let originalHistory = try Data(contentsOf: metadata)
        let original = try XCTUnwrap(fixture.effects.previews.last).report
        var changed = record
        changed.failure = "replacement private error"
        changed.processedText = "replacement private text"
        await fixture.controller.indexHistory(changed)
        await fixture.controller.copyIssueReport(ticket)
        await fixture.controller.openIssueReport(ticket)
        XCTAssertEqual(fixture.effects.copies, [original.body])
        XCTAssertEqual(fixture.effects.urls, [try XCTUnwrap(original.issueURL)])
        let saved = await fixture.controller.exportIssueReport(ticket)
        XCTAssertEqual(saved, .saved)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), original.jsonData)
        await fixture.controller.setIssueReportIncludesDiagnostics(false, ticket: ticket)
        let removed = try XCTUnwrap(fixture.effects.previews.last).report
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: removed.jsonData) as? [String: Any])
        XCTAssertEqual(object["contextState"] as? String, "userRemoved")
        XCTAssertNil(object["recordedModels"])
        XCTAssertNil(object["failures"])
        await fixture.controller.copyIssueReport(ticket)
        let removedSaved = await fixture.controller.exportIssueReport(ticket)
        XCTAssertEqual(removedSaved, .saved)
        XCTAssertEqual(fixture.effects.copies.last, removed.body)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), removed.jsonData)
        XCTAssertEqual(try Data(contentsOf: metadata), originalHistory)
        let names = await fixture.effects.chooser.filenames
        XCTAssertEqual(names, [IssueDiagnosticReport.attachmentFilename, IssueDiagnosticReport.attachmentFilename])
    }

    func testCancelledReplacedAndClosedPreviewsRefuseLateChooserCallbacks() async throws {
        for action in 0...2 {
            let fixture = try self.fixture()
            let record = self.record()
            await fixture.seed(record)
            let ticket = try await fixture.ticket(record.id)
            let entered = expectation(description: "owned chooser opened")
            await fixture.effects.chooser.hold(entered)
            let task = self.export(fixture, ticket: ticket)
            await fulfillment(of: [entered], timeout: 2)
            await fixture.controller.setIssueReportIncludesDiagnostics(false, ticket: ticket)
            XCTAssertEqual(fixture.effects.previews.last?.includesDiagnostics, true)
            if action == 0 { await fixture.controller.cancelIssueReport(ticket) }
            if action == 1 {
                let replacement = await fixture.begin(record.id)
                XCTAssertNotNil(replacement)
            }
            if action == 2 { await fixture.controller.close() }
            await fixture.effects.chooser.release()
            await task.value
            await fixture.controller.copyIssueReport(ticket)
            await fixture.controller.openIssueReport(ticket)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            XCTAssertTrue(fixture.effects.copies.isEmpty)
            XCTAssertTrue(fixture.effects.urls.isEmpty)
            XCTAssertFalse(fixture.effects.previews.contains { $0.status == .exported })
        }
    }

    func testCancelledTaskAndRefusedPresentationNeverPerformSharingActions() async throws {
        let fixture = try self.fixture()
        let record = self.record()
        await fixture.seed(record)
        fixture.effects.refusePresentation = true
        let refused = await fixture.begin(record.id)
        XCTAssertNil(refused)
        fixture.effects.refusePresentation = false
        let ticket = try await fixture.ticket(record.id)
        let start = Gate(open: false)
        let task = Task { await start.pass(); await fixture.controller.copyIssueReport(ticket) }
        task.cancel()
        start.release()
        await task.value
        await fixture.controller.cancelIssueReport(ticket)
        let outcome = await fixture.controller.exportIssueReport(ticket)
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertTrue(fixture.effects.copies.isEmpty)
        XCTAssertTrue(fixture.effects.urls.isEmpty)
    }

    func testCancelledExportTaskAndCancelledChooserReturnNoSuccessOrWrite() async throws {
        for cancelTask in [false, true] {
            let fixture = try self.fixture()
            let record = self.record()
            await fixture.seed(record)
            let ticket = try await fixture.ticket(record.id)
            let entered = expectation(description: "cancelled export chooser entered")
            await fixture.effects.chooser.hold(entered)
            let task = self.export(fixture, ticket: ticket)
            await fulfillment(of: [entered], timeout: 2)
            if cancelTask { task.cancel() } else { await fixture.effects.chooser.setDestination(nil) }
            await fixture.effects.chooser.release()
            await task.value
            XCTAssertEqual(fixture.effects.outcomes.last, .cancelled)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            XCTAssertFalse(fixture.effects.previews.contains { $0.status == .exported || $0.status == .exportFailed })
        }
    }

    func testFailureMessagesNeverExposePathsOrUnderlyingErrors() async throws {
        let fixture = try self.fixture()
        let record = self.record()
        await fixture.seed(record)
        let ticket = try await fixture.ticket(record.id)
        fixture.effects.refuseCopy = true
        await fixture.controller.copyIssueReport(ticket)
        XCTAssertEqual(fixture.effects.previews.last?.status, .copyFailed)
        fixture.effects.refuseBrowser = true
        await fixture.controller.openIssueReport(ticket)
        XCTAssertEqual(fixture.effects.previews.last?.status, .browserFailed)
        await fixture.effects.chooser.setDestination(
            fixture.root.appendingPathComponent("PRIVATE_PATH/missing/out.json"))
        let outcome = await fixture.controller.exportIssueReport(ticket)
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(fixture.effects.previews.last?.status, .exportFailed)
        XCTAssertFalse(fixture.effects.previews.compactMap { $0.status?.message }.joined().contains("PRIVATE_PATH"))
    }

    func testStoreGuardPreservesHistoryAndSymlinkResolvedProtectedDestinations() async throws {
        let fixture = try self.fixture()
        let record = self.record()
        await fixture.seed(record)
        let ticket = try await fixture.ticket(record.id)
        let history = fixture.root.appendingPathComponent("History")
        let metadata = history.appendingPathComponent(record.id.uuidString + ".json")
        let original = try Data(contentsOf: metadata)
        var destinations = [metadata, history.appendingPathComponent("new.json")]
        #if !os(Windows)
        let link = fixture.root.appendingPathComponent("history-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: history)
        destinations.append(link.appendingPathComponent(record.id.uuidString + ".json"))
        #endif
        for destination in destinations {
            await fixture.effects.chooser.setDestination(destination)
            let outcome = await fixture.controller.exportIssueReport(ticket)
            XCTAssertEqual(outcome, .failed)
            XCTAssertEqual(try Data(contentsOf: metadata), original)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.appendingPathComponent("new.json").path))
    }

    func testRetirementBeforeQueuedStoreGuardRefusesWriteButAdmissionIsNotRetracted() async throws {
        let fixture = try self.fixture()
        let entered = expectation(description: "owned store queue held")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let queueExit = XCTestExpectation(description: "owned queue worker exited")
        let store = await fixture.controller.store
        let held = Task { defer { queueExit.fulfill() }; await store.holdIssueReportQueue(entered, release: release) }
        fixture.own(held, exit: queueExit)
        await fulfillment(of: [entered], timeout: 2)
        let lease = DesktopHostIssueReportExportLease()
        let started = expectation(description: "owned export worker entered")
        let exit = XCTestExpectation(description: "owned export worker exited")
        let task = Task {
            defer { exit.fulfill() }
            started.fulfill()
            do {
                let saved = try await store.exportTranscriptSnapshot(
                    "frozen", to: fixture.destination, admitting: { lease.admit() })
                XCTAssertFalse(saved)
            } catch { XCTFail("Retired export must be a refused receipt, not a write failure") }
        }
        fixture.own(task, exit: exit)
        await fulfillment(of: [started], timeout: 2)
        lease.retire()
        release.signal()
        await task.value
        await held.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        let admitted = DesktopHostIssueReportExportLease()
        let saved = try await store.exportTranscriptSnapshot("admitted", to: fixture.destination, admitting: {
            let accepted = admitted.admit()
            admitted.retire()
            return accepted
        })
        XCTAssertTrue(saved)
        XCTAssertEqual(try String(contentsOf: fixture.destination, encoding: .utf8), "admitted")
        try await store.exportTranscriptSnapshot("legacy public API", to: fixture.destination)
        XCTAssertEqual(try String(contentsOf: fixture.destination, encoding: .utf8), "legacy public API")
    }
}
extension DesktopHostIssueReportTests {
    func testStoreGuardRefusesRegisteredAudioAndItsSymlinkWithoutChangingBytes() async throws {
        #if os(Linux) && canImport(Glibc)
        let fixture = try self.fixture()
        let store = await fixture.controller.store
        let history = await store.directory
        let audioRoot = fixture.root.appendingPathComponent("Audio")
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        let locations = try DesktopRecordingLocations(historyDirectory: history, persistence: IssueReportRegistration())
        try await store.activateAudioLocations(locations)
        let location = try await store.authorizeLocallySelectedAudioRoot(audioRoot)
        let capture = try await store.createLocallyAuthorizedCapture(at: location)
        defer { try? capture.file.close() }
        let pcm = try PCMRecordingFile(ownedFile: capture.file, sampleRate: 16_000)
        try pcm.append(Data([1, 2, 3, 4]))
        _ = try pcm.finish()
        let record = DesktopRecordingStore.Record(capture: capture, modelIdentifier: "fixture")
        try await store.save(record)
        let audio = try await store.audioURL(for: record)
        let original = try Data(contentsOf: audio)
        let link = fixture.root.appendingPathComponent("audio-link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: audio)
        for destination in [audio, link] {
            do {
                _ = try await store.exportTranscriptSnapshot("must not replace audio", to: destination, admitting: {
                    XCTFail("Protected audio must be refused before export admission")
                    return true
                })
                XCTFail("Registered audio must never be an export destination")
            } catch { XCTAssertEqual(try Data(contentsOf: audio), original) }
        }
        #else
        throw XCTSkip("Actual held capture creation is qualified only on Linux; no success fallback.")
        #endif
    }
    private static var canary: String { "PRIVATE_CANARY_token=user@example.com" }
    private func record() -> DesktopRecordingStore.Record {
        var record = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: "PRIVATE_PATH-audio.wav", modelIdentifier: Self.canary)
        record.failure = "401 api_key=\(Self.canary)"
        record.postProcessingFailure = "openai \(Self.canary)"
        record.processedText = Self.canary
        record.result = TranscriptionResult(
            text: Self.canary, segments: [], confidence: nil, duration: 1,
            modelIdentifier: Self.canary, cost: nil, rawPayload: Self.canary, debugInfo: nil)
        record.postProcessingModelIdentifier = "openai/gpt-4o-mini"
        record.profileName = Self.canary
        record.migrationMetadata = AnyCodable(.object(["requestContext": .string(Self.canary)]))
        return record
    }
    private func fixture() throws -> IssueReportFixture {
        FakeLog.shared.installKeyReadHook { _ in XCTFail("Issue preview must never request credentials") }
        let fixture = try IssueReportFixture()
        addTeardownBlock { await fixture.clean() }
        return fixture
    }
    private func export(_ fixture: IssueReportFixture, ticket: UUID) -> Task<Void, Never> {
        let exit = XCTestExpectation(description: "owned preview export exited")
        let task = Task {
            defer { exit.fulfill() }
            let outcome = await fixture.controller.exportIssueReport(ticket)
            fixture.effects.record(outcome)
        }
        fixture.own(task, exit: exit)
        return task
    }
}
extension DesktopHostIssueReportTests {
    func testHeldBrowserCompletionBlocksOtherActionsWithoutPrematureSuccess() async throws {
        let fixture = try self.fixture()
        let record = self.record()
        await fixture.seed(record)
        let ticket = try await fixture.ticket(record.id)
        let frozen = try XCTUnwrap(fixture.effects.previews.last).report
        let entered = expectation(description: "owned browser request entered")
        await fixture.effects.browser.hold(entered)
        let task = self.open(fixture, ticket: ticket)
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(fixture.effects.previews.last?.isOpening, true)
        XCTAssertNil(fixture.effects.previews.last?.status)
        await fixture.controller.openIssueReport(ticket)
        await fixture.controller.copyIssueReport(ticket)
        await fixture.controller.setIssueReportIncludesDiagnostics(false, ticket: ticket)
        let export = await fixture.controller.exportIssueReport(ticket)
        XCTAssertEqual(export, .unavailable)
        XCTAssertEqual(fixture.effects.urls, [try XCTUnwrap(frozen.issueURL)])
        XCTAssertTrue(fixture.effects.copies.isEmpty)
        XCTAssertEqual(fixture.effects.previews.last?.includesDiagnostics, true)
        XCTAssertEqual(fixture.effects.previews.last?.report.jsonData, frozen.jsonData)
        let names = await fixture.effects.chooser.filenames
        XCTAssertTrue(names.isEmpty)
        await fixture.effects.browser.release()
        await task.value
        XCTAssertEqual(fixture.effects.previews.last?.isOpening, false)
        XCTAssertEqual(fixture.effects.previews.last?.status, .opened)
        XCTAssertTrue(DesktopHostIssueReportStatus.opened.message.contains("system accepted"))
        XCTAssertTrue(DesktopHostIssueReportStatus.opened.message.contains("Nothing has been attached or submitted"))
    }

    func testRetiredReplacedAndClosedBrowserCallbacksCannotPublishOldSuccessOrFailure() async throws {
        for action in 0...2 {
            let fixture = try self.fixture()
            let record = self.record()
            await fixture.seed(record)
            let ticket = try await fixture.ticket(record.id)
            fixture.effects.refuseBrowser = action == 1
            let entered = expectation(description: "browser admitted before retirement")
            await fixture.effects.browser.hold(entered)
            let task = self.open(fixture, ticket: ticket)
            await fulfillment(of: [entered], timeout: 2)
            if action == 0 { await fixture.controller.cancelIssueReport(ticket) }
            if action == 1 { let replacement = await fixture.begin(record.id); XCTAssertNotNil(replacement) }
            if action == 2 { await fixture.controller.close() }
            let count = fixture.effects.previews.count
            await fixture.effects.browser.release()
            await task.value
            XCTAssertEqual(fixture.effects.previews.count, count)
            XCTAssertFalse(fixture.effects.previews.contains {
                $0.ticket == ticket && ($0.status == .opened || $0.status == .browserFailed)
            })
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        }
    }

    func testCancelledBrowserTaskCannotClaimSuccessAndCurrentPreviewCanRetry() async throws {
        let fixture = try self.fixture()
        let record = self.record()
        await fixture.seed(record)
        let ticket = try await fixture.ticket(record.id)
        let entered = expectation(description: "cancelled browser was admitted")
        await fixture.effects.browser.hold(entered)
        let task = self.open(fixture, ticket: ticket)
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        await fixture.effects.browser.release()
        await task.value
        XCTAssertNil(fixture.effects.previews.last?.status)
        XCTAssertEqual(fixture.effects.previews.last?.isOpening, false)
        XCTAssertEqual(fixture.effects.urls.count, 1, "An admitted OS request cannot be retracted by this owner")
        await fixture.controller.openIssueReport(ticket)
        XCTAssertEqual(fixture.effects.previews.last?.status, .opened)
        XCTAssertEqual(fixture.effects.urls.count, 2)
    }

    func testOldBrowserResultCannotClearReplacementOpeningFlag() async throws {
        let fixture = try self.fixture()
        let record = self.record()
        await fixture.seed(record)
        let first = try await fixture.ticket(record.id)
        let firstEntered = expectation(description: "first browser held")
        await fixture.effects.browser.hold(firstEntered)
        let firstTask = self.open(fixture, ticket: first)
        await fulfillment(of: [firstEntered], timeout: 2)
        let second = try await fixture.ticket(record.id)
        let secondEntered = expectation(description: "replacement browser held")
        await fixture.effects.browser.hold(secondEntered)
        let secondTask = self.open(fixture, ticket: second)
        await fulfillment(of: [secondEntered], timeout: 2)
        await fixture.effects.browser.releaseFirst()
        await firstTask.value
        XCTAssertEqual(fixture.effects.previews.last?.ticket, second)
        XCTAssertEqual(fixture.effects.previews.last?.isOpening, true)
        XCTAssertNil(fixture.effects.previews.last?.status)
        await fixture.effects.browser.releaseFirst()
        await secondTask.value
        XCTAssertEqual(fixture.effects.previews.last?.ticket, second)
        XCTAssertEqual(fixture.effects.previews.last?.isOpening, false)
        XCTAssertEqual(fixture.effects.previews.last?.status, .opened)
    }

    func testChooserFailureAndCancellationHaveDistinctOutcomesWithoutWriting() async throws {
        for failed in [false, true] {
            let fixture = try self.fixture()
            let record = self.record()
            await fixture.seed(record)
            let ticket = try await fixture.ticket(record.id)
            await fixture.effects.chooser.setResult(failed ? .failed : .cancelled)
            let result = await fixture.controller.exportIssueReport(ticket)
            XCTAssertEqual(result, failed ? .failed : .cancelled)
            XCTAssertEqual(fixture.effects.previews.last?.status, failed ? .exportFailed : nil)
            XCTAssertEqual(fixture.effects.previews.last?.isExporting, false)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            XCTAssertTrue(fixture.effects.urls.isEmpty)
            XCTAssertTrue(fixture.effects.copies.isEmpty)
        }
    }

    func testLateChooserFailureAfterReplacementCannotMarkNewPreviewFailed() async throws {
        let fixture = try self.fixture()
        let record = self.record()
        await fixture.seed(record)
        let ticket = try await fixture.ticket(record.id)
        let entered = expectation(description: "old chooser held before failure")
        await fixture.effects.chooser.hold(entered)
        let task = self.export(fixture, ticket: ticket)
        await fulfillment(of: [entered], timeout: 2)
        let replacement = try await fixture.ticket(record.id)
        await fixture.effects.chooser.setResult(.failed)
        await fixture.effects.chooser.release()
        await task.value
        XCTAssertEqual(fixture.effects.outcomes.last, .cancelled)
        XCTAssertEqual(fixture.effects.previews.last?.ticket, replacement)
        XCTAssertNil(fixture.effects.previews.last?.status)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    func testBrowserCannotStartWhileDestinationChooserOwnsExport() async throws {
        let fixture = try self.fixture()
        let record = self.record()
        await fixture.seed(record)
        let ticket = try await fixture.ticket(record.id)
        let entered = expectation(description: "export chooser admitted")
        await fixture.effects.chooser.hold(entered)
        let task = self.export(fixture, ticket: ticket)
        await fulfillment(of: [entered], timeout: 2)
        await fixture.controller.openIssueReport(ticket)
        XCTAssertTrue(fixture.effects.urls.isEmpty)
        XCTAssertEqual(fixture.effects.previews.last?.isExporting, true)
        XCTAssertEqual(fixture.effects.previews.last?.isOpening, false)
        await fixture.effects.chooser.release()
        await task.value
        XCTAssertEqual(fixture.effects.outcomes.last, .saved)
    }

    private func open(_ fixture: IssueReportFixture, ticket: UUID) -> Task<Void, Never> {
        let exit = XCTestExpectation(description: "owned preview browser exited")
        let task = Task {
            defer { exit.fulfill() }
            await fixture.controller.openIssueReport(ticket)
        }
        fixture.own(task, exit: exit)
        return task
    }
}

private final class IssueReportFixture: @unchecked Sendable {
    let root: URL
    let controller: DesktopHostController<FakePlatform>
    let effects = IssueReportEffects()
    private let lock = NSLock()
    private var tasks: [(Task<Void, Never>, XCTestExpectation)] = []
    var destination: URL { root.appendingPathComponent(IssueDiagnosticReport.attachmentFilename) }
    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("issue-report-\(UUID().uuidString)")
        self.root = root
        controller = try DesktopHostController(directory: root, effects: SyntheticEffects())
    }
    func seed(_ record: DesktopRecordingStore.Record) async {
        do { try await controller.store.save(record) } catch { XCTFail("Could not seed owned History") }
        await effects.chooser.setDestination(destination)
        await controller.markReadyForSelfTest()
        await controller.indexHistory(record)
        await controller.selectHistory(record.id.uuidString)
    }
    func begin(_ id: UUID) async -> UUID? { await controller.beginIssueReport(id.uuidString, using: effects.actions) }
    func ticket(_ id: UUID) async throws -> UUID { let value = await begin(id); return try XCTUnwrap(value) }
    func own(_ task: Task<Void, Never>, exit: XCTestExpectation) { lock.withLock { tasks.append((task, exit)) } }
    func clean() async {
        await effects.chooser.release()
        await effects.browser.release()
        let owned = lock.withLock { tasks }
        owned.forEach { $0.0.cancel() }
        for (_, exit) in owned {
            guard await XCTWaiter.fulfillment(of: [exit], timeout: 2) == .completed else {
                XCTFail("Owned report work remains active; its directory is retained")
                return
            }
        }
        await controller.close()
        do { try FileManager.default.removeItem(at: root) } catch { XCTFail("Could not remove owned report fixture") }
    }
}
private actor IssueReportChooser {
    private var result: DesktopHostIssueReportDestination = .cancelled
    private var entered: XCTestExpectation?
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var filenames: [String] = []
    func setDestination(_ value: URL?) { result = value.map { .selected($0) } ?? .cancelled }
    func setResult(_ value: DesktopHostIssueReportDestination) { result = value }
    func hold(_ receipt: XCTestExpectation) { entered = receipt; released = false }
    func choose(_ name: String) async -> DesktopHostIssueReportDestination {
        filenames.append(name)
        if let entered, !released {
            await withCheckedContinuation { continuation in self.continuation = continuation; entered.fulfill() }
        }
        return result
    }
    func release() { released = true; let pending = continuation; continuation = nil; pending?.resume() }
}
/// Synthetic only: holds at most the two requests admitted by the replacement test.
private actor IssueReportBrowser {
    private var entered: XCTestExpectation?
    private var pending: [(CheckedContinuation<Bool, Never>, Bool)] = []
    private var released = false

    func hold(_ receipt: XCTestExpectation) { entered = receipt; released = false }

    func open(result: Bool) async -> Bool {
        guard let entered, !released else { return result }
        self.entered = nil
        return await withCheckedContinuation { continuation in
            pending.append((continuation, result))
            entered.fulfill()
        }
    }

    func releaseFirst() {
        guard !pending.isEmpty else { return }
        let (continuation, result) = pending.removeFirst()
        continuation.resume(returning: result)
    }

    func release() {
        released = true
        entered = nil
        while !pending.isEmpty { releaseFirst() }
    }
}

private final class IssueReportEffects: @unchecked Sendable {
    let chooser = IssueReportChooser()
    let browser = IssueReportBrowser()
    private let lock = NSLock()
    private var snapshots: [DesktopHostIssueReportPreview] = []
    private var clipboard: [String] = []
    private var opened: [URL] = []
    private var exportOutcomes: [DesktopHostIssueReportExportOutcome] = []
    var refusePresentation = false
    var refuseCopy = false
    var refuseBrowser = false
    var previews: [DesktopHostIssueReportPreview] { lock.withLock { snapshots } }
    var copies: [String] { lock.withLock { clipboard } }
    var urls: [URL] { lock.withLock { opened } }
    var outcomes: [DesktopHostIssueReportExportOutcome] { lock.withLock { exportOutcomes } }
    func record(_ outcome: DesktopHostIssueReportExportOutcome) { lock.withLock { exportOutcomes.append(outcome) } }
    var actions: DesktopHostIssueReportActions {
        .init(present: { [self] value in lock.withLock { snapshots.append(value); return !refusePresentation } },
              dismiss: { _ in }, chooseDestination: { [self] name in await chooser.choose(name) },
              copy: { [self] value in
                  try lock.withLock { if refuseCopy { throw CocoaError(.fileWriteUnknown) }; clipboard.append(value) }
              }, open: { [self] url in
                  let result = lock.withLock { opened.append(url); return !refuseBrowser }
                  return await browser.open(result: result)
              })
    }
}

private struct IssueReportRegistration: DesktopRecordingLocationPersistence {
    func loadVerified() throws -> DesktopRecordingLocationState { .init() }
    func appendRegistration(_ registration: DesktopRecordingLocationRegistration) throws {}
    func appendRecording(_ recording: DesktopRecordingLocationOwnership) throws {}
}

private extension DesktopRecordingStore {
    /// Bounded synchronous actor work, never a MainActor semaphore wait.
    func holdIssueReportQueue(_ entered: XCTestExpectation, release: DispatchSemaphore) {
        entered.fulfill()
        if release.wait(timeout: .now() + 3) != .success { XCTFail("Owned queue hold was not released") }
    }
} // swiftlint:disable:this file_length
