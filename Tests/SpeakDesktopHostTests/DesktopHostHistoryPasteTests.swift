import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

final class DesktopHostHistoryPasteTests: XCTestCase {
    private var directory: URL!
    private var effects: HistoryPasteEffects!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        FakeLog.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-paste-\(UUID())")
        effects = HistoryPasteEffects()
        controller = try DesktopHostController(directory: directory, effects: effects)
        await controller.markReadyForSelfTest()
        FakeLog.shared.installKeyReadHook { name in
            XCTFail("Pasting History must not read credentials: \(name)")
        }
    }

    override func tearDown() async throws {
        await controller.close()
        try FileManager.default.removeItem(at: directory)
    }

    private func record(
        _ raw: String?, processed: String? = nil, createdAt: TimeInterval
    ) -> DesktopRecordingStore.Record {
        var record = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: "synthetic.wav", modelIdentifier: "synthetic",
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
        if let raw {
            record.result = .init(
                text: raw, segments: [], confidence: nil, duration: 1,
                modelIdentifier: "synthetic", cost: nil, rawPayload: nil, debugInfo: nil
            )
        }
        record.processedText = processed
        return record
    }

    private func finishOutput() async {
        let output = await controller.outputSlot.task
        await output?.value
    }

    func testPaste_UsesLatestProcessedTextRegardlessOfSelectionAndSearch() async throws {
        let older = record("Only older", createdAt: 1)
        let latest = record("Latest raw", processed: "Latest processed", createdAt: 2)
        await controller.indexHistory(older)
        await controller.indexHistory(latest)
        await controller.selectHistory(older.id.uuidString)
        await controller.historyPasteFixtureQuery("Only older")
        await controller.recordingEventFixtureOutput(FakeTextOutput(label: "saved-output"))
        let writes = effects.base.writes
        await controller.pasteLastHistoryItem(target: "captured-field")
        await finishOutput()
        let call = try XCTUnwrap(effects.calls.first)
        XCTAssertEqual(effects.calls.count, 1)
        XCTAssertEqual(call.text, "Latest processed")
        XCTAssertEqual(call.job.target, "captured-field")
        XCTAssertEqual(call.job.label, "saved-output")
        let selected = await controller.selectedHistoryID
        let query = await controller.historyQuery
        let visible = await controller.visibleHistory()
        XCTAssertEqual(selected, older.id)
        XCTAssertEqual(query, "Only older")
        XCTAssertEqual(visible.map(\.id), [older.id])
        XCTAssertEqual(effects.base.writes, writes)
        XCTAssertEqual(FakeLog.shared.allStatuses.last, "Synthetic output delivered.")
    }

    func testPaste_RawFallbackHonorsClipboardOnlyOutputWithoutAField() async throws {
        await controller.indexHistory(record(" Raw text \n", createdAt: 1))
        await controller.recordingEventFixtureOutput(FakeTextOutput(label: "copy"))
        await controller.pasteLastHistoryItem(target: nil)
        await finishOutput()
        let call = try XCTUnwrap(effects.calls.first)
        XCTAssertEqual(call.text, " Raw text \n")
        XCTAssertEqual(call.job.label, "copy")
        XCTAssertNil(call.job.target)
    }

    func testPaste_EmptyLatestRecordNeverFallsBackToAnOlderRecord() async throws {
        await controller.indexHistory(record("Older usable text", createdAt: 1))
        let emptyValues: [String?] = [nil, "", " \n\t "]
        for (index, text) in emptyValues.enumerated() {
            await controller.indexHistory(record(
                text == nil ? nil : "Raw must not replace empty processed text",
                processed: text, createdAt: Double(index + 2)
            ))
            await controller.pasteLastHistoryItem(target: "captured-field")
            await finishOutput()
            XCTAssertTrue(effects.calls.isEmpty)
            XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("Nothing to paste") == true)
        }
    }

    func testPaste_MissingTargetAndOutputFailureAreVisibleWithoutChangingHistory() async throws {
        let latest = record("Retained text", createdAt: 1)
        await controller.indexHistory(latest)
        await controller.pasteLastHistoryItem(target: nil)
        XCTAssertTrue(effects.calls.isEmpty)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("Focus a supported text field") == true)
        effects.result = .init(.cancelled, status: "Synthetic output cancelled.")
        await controller.pasteLastHistoryItem(target: "captured-field")
        await finishOutput()
        XCTAssertEqual(FakeLog.shared.allStatuses.last, "Synthetic output cancelled.")
        let retained = await controller.history[latest.id]
        XCTAssertEqual(retained?.displayText, latest.displayText)
    }

    func testPaste_BusyHostDoesNotStartOutput() async throws {
        await controller.indexHistory(record("Retained text", createdAt: 1))
        await controller.historyPasteFixtureBusy(true)
        await controller.pasteLastHistoryItem(target: "captured-field")
        XCTAssertTrue(effects.calls.isEmpty)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("Finish the current recording or text output") == true)
        await controller.historyPasteFixtureBusy(false)
        await controller.pasteLastHistoryItem(target: "captured-field")
        await finishOutput()
        XCTAssertEqual(effects.calls.count, 1)
    }
}

extension DesktopHostController where Platform == FakePlatform {
    fileprivate func historyPasteFixtureQuery(_ query: String) { historyQuery = query }
    fileprivate func historyPasteFixtureBusy(_ value: Bool) { busy = value }
}

private final class HistoryPasteEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakePlatform
    let base = SettingsWriteEffects()
    private let lock = NSLock()
    private var captured: [(job: FakeJob, text: String)] = []
    private var outputResult = DesktopTextOutputResult(.confirmedInsertion, status: "Synthetic output delivered.")

    var calls: [(job: FakeJob, text: String)] { lock.withLock { captured } }
    var result: DesktopTextOutputResult {
        get { lock.withLock { outputResult } }
        set { lock.withLock { outputResult = newValue } }
    }
    func apiKey(name: String) throws -> String { try base.apiKey(name: name) }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture {
        try base.makeCapture(
            context: context, deviceID: deviceID, sampleRate: sampleRate, frameMilliseconds: frameMilliseconds
        )
    }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? {
        base.makeLiveClient(model: model, key: key, language: language, azureEndpoint: azureEndpoint)
    }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult {
        try await base.transcribe(request, with: controller)
    }
    func perform(_ job: FakeJob, text: String) -> DesktopTextOutputResult {
        lock.withLock {
            captured.append((job, text))
            return outputResult
        }
    }
    func writeSettings(_ data: Data, to url: URL) throws { try base.writeSettings(data, to: url) }
}
