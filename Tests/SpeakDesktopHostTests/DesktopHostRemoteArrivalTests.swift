import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

private final class ArrivalEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakePlatform
    private let base = SyntheticEffects()
    private let lock = NSLock()
    private var performed: [(FakeJob, String)] = []
    var outputs: [(FakeJob, String)] { lock.withLock { performed } }

    func apiKey(name: String) throws -> String { "synthetic-key-never-sent" }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture {
        try base.makeCapture(
            context: context, deviceID: deviceID, sampleRate: sampleRate, frameMilliseconds: frameMilliseconds
        )
    }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? { nil }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult { try await base.transcribe(request, with: controller) }
    func perform(_ job: FakeJob, text: String) -> DesktopTextOutputResult {
        lock.withLock { performed.append((job, text)) }
        return DesktopTextOutputResult(.confirmedInsertion, status: "Inserted.")
    }
    func captureInsertionTarget() async throws -> String? { "focused-field" }
    func writeSettings(_ data: Data, to url: URL) throws { try base.writeSettings(data, to: url) }
}

final class DesktopHostRemoteArrivalTests: XCTestCase {
    private var directory: URL!
    private var effects: ArrivalEffects!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("arrival-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        effects = ArrivalEffects()
        controller = try DesktopHostController(
            directory: directory, effects: effects, shutdownGrace: .milliseconds(10)
        )
    }

    override func tearDown() async throws {
        await controller.close()
        try FileManager.default.removeItem(at: directory)
    }

    private func arrive(
        origin: String = "ios", age: TimeInterval = 5, text: String = "From the phone"
    ) async throws -> UUID {
        var record = DesktopRecordingStore.Record(
            syncedID: UUID(), createdAt: Date().addingTimeInterval(-age),
            modelIdentifier: "remote/model", originPlatform: origin
        )
        record.processedText = text
        try await controller.store.save(record)
        await controller.applySyncedHistory([.saved(record.id)])
        await controller.outputSlot.task?.value
        return record.id
    }

    func testEnabledFreshPhoneArrival_PastesAtFocusedField() async throws {
        try await controller.applyRemotePasteForTest(enabled: true)
        let id = try await arrive()
        XCTAssertEqual(effects.outputs.map(\.1), ["From the phone"])
        XCTAssertEqual(effects.outputs.first?.0.target, "focused-field")

        await controller.applySyncedHistory([.saved(id)])
        XCTAssertEqual(effects.outputs.count, 1, "A record this host already has is never pasted again")
    }

    func testDisabledOldOrDesktopArrival_IsOnlySavedToHistory() async throws {
        _ = try await arrive()
        try await controller.applyRemotePasteForTest(enabled: true)
        _ = try await arrive(age: 120)
        _ = try await arrive(origin: "macos")
        _ = try await arrive(origin: "windows")
        XCTAssertTrue(effects.outputs.isEmpty)
    }

    func testStatus_ReportsWhatHappened() {
        let alert = RemoteTranscriptArrival.Alert(title: "New from iPhone", body: "Hi", transcript: "Hi")
        typealias Host = DesktopHostController<FakePlatform>
        XCTAssertEqual(Host.remoteArrivalStatus(alert, start: .inserting), "New from iPhone: pasting at the cursor…")
        XCTAssertTrue(Host.remoteArrivalStatus(alert, start: .unavailable).contains("saved in History"))
    }
}

extension DesktopHostController where Platform == FakePlatform {
    func applyRemotePasteForTest(enabled: Bool) throws {
        var changed = settings
        changed.configuration = try DesktopConfiguration(values: [
            ApplicationPreferenceKey.pasteRemoteTranscriptsAtCursor.rawValue: AnyCodable(.bool(enabled))
        ])
        settings = changed
    }
}
