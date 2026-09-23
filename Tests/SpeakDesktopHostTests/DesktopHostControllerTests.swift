import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

// The shared controller driven through a fake platform and synthetic
// effects: no window, microphone, keyring, network or clipboard. These run on
// every host that builds the portable package, so the orchestration Windows
// and Linux share is exercised without either native adapter.

struct FakeTextOutput: Codable, Equatable, Sendable {
    var label = "default"
}

struct FakeHotKey: Codable, Sendable {}

struct FakeJob: Sendable {
    let label: String
    let target: String?
}

final class FakePlayback: DesktopHostPlayback, @unchecked Sendable {
    func setStatusHandler(_ handler: @escaping @Sendable (UInt64, String) -> Void) {}
    func isCurrent(revision: UInt64) -> Bool { false }
    func play(recordID: UUID, path: String, knownDuration: TimeInterval?) throws {}
    func togglePause(recordID: UUID) -> Bool { false }
    func stop() {}
    func stop(unless recordID: UUID) {}
    func stopAndWait() async throws {}
    func close() async throws {}
}

/// Everything the fake window and services were asked to do.
final class FakeLog: @unchecked Sendable {
    static let shared = FakeLog()
    private let lock = NSLock()
    private var statuses: [String] = []
    private var clipboard: [String] = []
    var keys: [String: String] = [:]

    func reset() { lock.withLock { statuses = []; clipboard = []; keys = [:] } }
    func status(_ text: String) { lock.withLock { statuses.append(text) } }
    func copy(_ text: String) { lock.withLock { clipboard.append(text) } }
    var allStatuses: [String] { lock.withLock { statuses } }
    var copies: [String] { lock.withLock { clipboard } }
    func key(_ name: String) -> String { lock.withLock { keys[name] ?? "" } }
    func setKey(_ key: String, name: String) { lock.withLock { keys[name] = key } }
}

enum FakePlatform: DesktopHostPlatform {
    typealias VoiceOutputSettings = FakeHotKey
    static let displayName = "Test"
    static let credentialStoreName = "the test keyring"

    static func update(_ status: String, transcript: String?, state: Int32) { FakeLog.shared.status(status) }
    static func recordingState(_ state: Int32) {}
    static func history(_ records: [DesktopRecordingStore.Record], selected: UUID?, selectRecord: Bool) {}
    static func historyPresentation(
        _ record: DesktopRecordingStore.Record, variant: DesktopTranscriptVariant, status: String
    ) { FakeLog.shared.status(status) }
    static func transcriptVariant(_ variant: DesktopTranscriptVariant?, for record: UUID?, switchable: Bool) {}
    static func publishModels(status: String, refreshing: Bool) throws {}
    static func apiKey(name: String) throws -> String { FakeLog.shared.key(name) }
    static func saveAPIKey(_ key: String, name: String) throws { FakeLog.shared.setKey(key, name: name) }
    static func uploadStaging(directory: URL) -> SharedMultipartUploadStaging {
        // No `.posix` default on Windows, where these tests also run.
        SharedMultipartUploadStaging(directory: directory, securityPolicy: .init(
            prepareDirectory: { url, manager in try manager.createDirectory(at: url, withIntermediateDirectories: true) },
            createFile: { url, manager in manager.createFile(atPath: url.path, contents: nil) }
        ))
    }
    static func preparePrivateDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    static func convertAudio(input: URL, output: URL) async throws -> TimeInterval {
        throw DesktopHostError(message: "No converter in tests.")
    }
    static func openFile(_ url: URL) throws {}
    static func copyToClipboard(_ text: String) throws { FakeLog.shared.copy(text) }
    static func makeOutputJob(options: FakeTextOutput, target: String?) -> FakeJob? {
        options.label == "copy" || target != nil ? FakeJob(label: options.label, target: target) : nil
    }
    static func cancel(_ job: FakeJob) {}
    static func isClipboard(_ job: FakeJob) -> Bool { job.target == nil }
    static func makePlayback() -> FakePlayback { FakePlayback() }
    static func makeReadAloudState() {}
    static func stopReadAloud(_ state: inout Void) {}
    static var defaultHotKey: FakeHotKey { FakeHotKey() }
    static func readyHint(_ hotKey: FakeHotKey) -> String { "Shortcut starts or stops recording." }
    static func finishHint(_ hotKey: FakeHotKey, for trigger: HotKeySessionTrigger) -> String { "Press to finish." }
}

/// Opens and closes like a physical gate for synthetic work.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open: Bool
    init(open: Bool) { self.open = open }
    func release() { lock.withLock { open = true } }
    func pass() async {
        while !lock.withLock({ open }) {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}

final class SyntheticCapture: DesktopRecordingCapture {
    let context: DesktopCaptureContext
    init(context: DesktopCaptureContext) { self.context = context }
    func start() throws {
        let samples: [Int16] = (0..<1_600).map { Int16(($0 % 32) * 256 - 4_000) }
        samples.withUnsafeBufferPointer { context.receive($0.baseAddress!, count: $0.count) }
    }
    func stop() throws {}
    func destroy() {}
}

final class SyntheticEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakePlatform
    let transcription = Gate(open: true)
    private let lock = NSLock()
    private var performed: [(FakeJob, String)] = []
    var outputs: [(FakeJob, String)] { lock.withLock { performed } }

    func apiKey(name: String) throws -> String { FakeLog.shared.key(name) }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture { SyntheticCapture(context: context) }
    func makeLiveClient(model: String, key: String, language: String?) -> (any FinalizingStreamingTranscriptionClient)? {
        nil
    }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult {
        await transcription.pass()
        try Task.checkCancellation()
        return TranscriptionResult(
            text: "Synthetic transcript", segments: [], confidence: nil, duration: request.duration,
            modelIdentifier: request.model, cost: nil, rawPayload: nil, debugInfo: nil
        )
    }
    func perform(_ job: FakeJob, text: String) -> String {
        lock.withLock { performed.append((job, text)) }
        return "Delivered."
    }
    func writeSettings(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }
}

final class DesktopHostControllerTests: XCTestCase {
    private var directory: URL!
    private var effects: SyntheticEffects!
    private var controller: DesktopHostController<FakePlatform>!
    private var batchIndex = 0

    override func setUp() async throws {
        FakeLog.shared.reset()
        DesktopHostModels.configure(streamingQualified: false)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("host-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        effects = SyntheticEffects()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        await controller.markReadyForSelfTest()
        batchIndex = try XCTUnwrap(DesktopHostModels.all.firstIndex { DesktopTranscription.provider(for: $0.id) != nil })
        let model = DesktopHostModels.all[batchIndex].id
        let credential = try XCTUnwrap(DesktopHostModels.provider(for: model)).apiKeyIdentifier
        FakeLog.shared.setKey("synthetic-key", name: credential)
    }

    override func tearDown() async throws {
        await controller.close()
        try? FileManager.default.removeItem(at: directory)
        DesktopHostModels.configure(streamingQualified: true)
    }

    private func records() async throws -> [DesktopRecordingStore.Record] {
        try await DesktopRecordingStore(directory: directory.appendingPathComponent("History"))
            .recoverInterruptedRecordings().records
    }

    private func waitFor(_ description: String, _ condition: () async throws -> Bool) async throws {
        for _ in 0..<500 {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }

    func testRecordingIsSavedBeforeTranscriptionAndOutputUsesTheStartSnapshot() async throws {
        await controller.toggle(
            target: "editor", modelIndex: batchIndex, deviceID: "", targetExecutablePath: nil,
            textOutput: FakeTextOutput(label: "at-start")
        )
        let pending = try await records()
        XCTAssertEqual(pending.count, 1)
        XCTAssertNil(pending.first?.result, "the record must exist before any network request")
        effects.transcription.release()
        await controller.toggle(
            target: "other", modelIndex: batchIndex, deviceID: "", targetExecutablePath: nil,
            textOutput: FakeTextOutput(label: "later")
        )
        try await waitFor("the automatic output") { !self.effects.outputs.isEmpty }
        let output = try XCTUnwrap(effects.outputs.first)
        XCTAssertEqual(output.0.label, "at-start")
        XCTAssertEqual(output.0.target, "editor")
        XCTAssertEqual(output.1, "Synthetic transcript")
        let saved = try await records()
        XCTAssertEqual(saved.first?.result?.text, "Synthetic transcript")
    }

    func testRecordingStartedWithoutATargetIsNotOutput() async throws {
        await controller.toggle(
            target: nil, modelIndex: batchIndex, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
        await controller.toggle(
            target: nil, modelIndex: batchIndex, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
        let saved = try await records()
        XCTAssertEqual(saved.first?.result?.text, "Synthetic transcript")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(effects.outputs.isEmpty)
    }

    func testMissingKeyRefusesToRecord() async throws {
        FakeLog.shared.reset()
        await controller.toggle(
            target: nil, modelIndex: batchIndex, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
        let saved = try await records()
        XCTAssertTrue(saved.isEmpty)
        XCTAssertFalse(FakeLog.shared.allStatuses.isEmpty)
    }

    func testCancellingTranscriptionRetainsTheAudio() async throws {
        await controller.close()
        controller = try DesktopHostController<FakePlatform>(
            directory: directory, effects: GatedEffects(gate: Gate(open: false))
        )
        await controller.markReadyForSelfTest()
        await controller.toggle(
            target: nil, modelIndex: batchIndex, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
        let stopping = Task {
            await self.controller.toggle(
                target: nil, modelIndex: self.batchIndex, deviceID: "", targetExecutablePath: nil,
                textOutput: FakeTextOutput()
            )
        }
        try await waitFor("transcription to start") { await self.controller.busy }
        await controller.cancelTranscription()
        await stopping.value
        let saved = try await records()
        let record = try XCTUnwrap(saved.first)
        XCTAssertEqual(record.failure, "Transcription cancelled. Audio retained.")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("History").appendingPathComponent(record.audioFilename).path
        ))
    }

    func testClosingWhileRecordingKeepsTheAudio() async throws {
        await controller.toggle(
            target: nil, modelIndex: batchIndex, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
        await controller.close()
        let saved = try await records()
        let record = try XCTUnwrap(saved.first)
        XCTAssertEqual(record.failure, "Recording stopped when the app closed. Audio retained.")
    }

    func testCopyUsesTheSnapshotText() async throws {
        await controller.copyTranscript("Displayed text", variant: .original)
        XCTAssertEqual(FakeLog.shared.copies, ["Displayed text"])
        XCTAssertEqual(FakeLog.shared.allStatuses.last, "Original transcript copied.")
    }

    func testSavingAKeyNamesTheCredentialStore() async throws {
        await controller.saveKey("  new-key  ", modelIndex: batchIndex)
        let model = DesktopHostModels.all[batchIndex].id
        let credential = try XCTUnwrap(DesktopHostModels.provider(for: model)).apiKeyIdentifier
        XCTAssertEqual(FakeLog.shared.key(credential), "new-key")
        XCTAssertEqual(FakeLog.shared.allStatuses.last, "API key saved in the test keyring.")
    }

    func testUnqualifiedHostsOfferNoLiveModels() {
        XCTAssertTrue(DesktopHostModels.live.isEmpty)
        XCTAssertFalse(DesktopHostModels.all.contains { DesktopHostModels.isLive($0.id) })
    }

    func testImportValidationRejectsUnsupportedFiles() throws {
        let text = directory.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)
        XCTAssertThrowsError(try DesktopHostImport.validate(text))
        let empty = directory.appendingPathComponent("empty.wav")
        try Data().write(to: empty)
        XCTAssertThrowsError(try DesktopHostImport.validate(empty))
    }
}

/// Transcription blocks until cancelled or released.
final class GatedEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakePlatform
    let gate: Gate
    init(gate: Gate) { self.gate = gate }
    func apiKey(name: String) throws -> String { FakeLog.shared.key(name) }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture { SyntheticCapture(context: context) }
    func makeLiveClient(model: String, key: String, language: String?) -> (any FinalizingStreamingTranscriptionClient)? {
        nil
    }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult {
        await gate.pass()
        try Task.checkCancellation()
        throw CancellationError()
    }
    func perform(_ job: FakeJob, text: String) -> String { "Delivered." }
    func writeSettings(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }
}
