import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

private final class RecordedPreparation: DesktopCapturePreparation, @unchecked Sendable {
    let deviceID: String
    private let lock = NSLock()
    private var active = true
    private var releases = 0
    init(deviceID: String) { self.deviceID = deviceID }
    var isActive: Bool { lock.withLock { active } }
    var released: Int { lock.withLock { releases } }
    func expire() { lock.withLock { active = false } }
    func release() { lock.withLock { releases += 1; active = false } }
}

private final class PreparationEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakePlatform
    private let base = SyntheticEffects()
    private let lock = NSLock()
    private var made: [RecordedPreparation] = []
    var preparations: [RecordedPreparation] { lock.withLock { made } }

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
    func perform(_ job: FakeJob, text: String) -> DesktopTextOutputResult { base.perform(job, text: text) }
    func writeSettings(_ data: Data, to url: URL) throws { try base.writeSettings(data, to: url) }
    func prepareCaptureWhileIdle(
        deviceID: String, lifetimeMilliseconds: UInt32
    ) -> (any DesktopCapturePreparation)? {
        XCTAssertEqual(lifetimeMilliseconds, 600_000)
        let prepared = RecordedPreparation(deviceID: deviceID)
        lock.withLock { made.append(prepared) }
        return prepared
    }
}

final class DesktopHostCapturePreparationTests: XCTestCase {
    private var directory: URL!
    private var effects: PreparationEffects!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("prepare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        effects = PreparationEffects()
        controller = try DesktopHostController(
            directory: directory, effects: effects, shutdownGrace: .milliseconds(10)
        )
        await controller.markReadyForSelfTest()
    }

    override func tearDown() async throws {
        await controller.close()
        try FileManager.default.removeItem(at: directory)
    }

    private func settle(_ condition: @escaping () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func testIdleTransition_PreparesOnceAndKeepsActivePreparation() async throws {
        await controller.warmOperationCycleForTest()
        await controller.warmOperationCycleForTest()
        XCTAssertEqual(effects.preparations.map(\.deviceID), [""])
        XCTAssertEqual(effects.preparations.first?.released, 0)
    }

    func testEndedLifetime_RenewsOnlyOnALaterIdleTransition() async throws {
        await controller.warmOperationCycleForTest()
        let first = try XCTUnwrap(effects.preparations.first)
        first.expire()
        XCTAssertEqual(effects.preparations.count, 1)
        await controller.warmOperationCycleForTest()
        XCTAssertEqual(effects.preparations.count, 2)
    }

    func testDisableDeviceChangeAndClose_ReleasePreparation() async throws {
        await controller.warmOperationCycleForTest()
        let first = try XCTUnwrap(effects.preparations.first)
        await controller.setMicrophoneWarning(nil)
        await settle { first.released == 1 }
        XCTAssertEqual(first.released, 1)
        let second = try XCTUnwrap(effects.preparations.last)
        XCTAssertFalse(first === second)

        try await controller.applyCapturePreparationForTest(enabled: false)
        await settle { second.released == 1 }
        XCTAssertEqual(second.released, 1)
        await controller.warmOperationCycleForTest()
        XCTAssertEqual(effects.preparations.count, 2, "Disabled preparation never prepares")

        try await controller.applyCapturePreparationForTest(enabled: true)
        let third = try XCTUnwrap(effects.preparations.last)
        XCTAssertEqual(effects.preparations.count, 3)
        await controller.close()
        await settle { third.released == 1 }
        XCTAssertEqual(third.released, 1)
    }

    func testBusyHostNeverPrepares() async throws {
        await controller.warmOperationalBlockForTest(true)
        await controller.reconcileCapturePreparation()
        XCTAssertTrue(effects.preparations.isEmpty)
    }
}

extension DesktopHostController where Platform == FakePlatform {
    func applyCapturePreparationForTest(enabled: Bool) throws {
        var changed = settings
        changed.configuration = try DesktopConfiguration(values: [
            ApplicationPreferenceKey.audioPreWarmingEnabled.rawValue: AnyCodable(.bool(enabled))
        ])
        settings = changed
    }
}
