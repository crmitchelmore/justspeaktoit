import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

private final class PressCapture: DesktopRecordingCapture, @unchecked Sendable {
    let deviceID: String
    private let lock = NSLock()
    private var events: [String] = []
    init(deviceID: String) { self.deviceID = deviceID }
    var log: [String] { lock.withLock { events } }
    func start() throws { lock.withLock { events.append("start") } }
    func stop() throws { lock.withLock { events.append("stop") } }
    func destroy() { lock.withLock { events.append("destroy") } }
}

private final class PressEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakePlatform
    private let base = SyntheticEffects()
    private let lock = NSLock()
    private var made: [PressCapture] = []
    var captures: [PressCapture] { lock.withLock { made } }

    func apiKey(name: String) throws -> String { "synthetic-key-never-sent" }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture {
        XCTAssertNil(context.file, "A press capture never writes audio")
        let capture = PressCapture(deviceID: deviceID)
        lock.withLock { made.append(capture) }
        return capture
    }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? { nil }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult { try await base.transcribe(request, with: controller) }
    func perform(_ job: FakeJob, text: String) -> DesktopTextOutputResult { base.perform(job, text: text) }
    func writeSettings(_ data: Data, to url: URL) throws { try base.writeSettings(data, to: url) }
}

final class DesktopHostShortcutPressMicrophoneTests: XCTestCase {
    private var directory: URL!
    private var effects: PressEffects!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("press-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        effects = PressEffects()
        controller = try DesktopHostController(
            directory: directory, effects: effects, shutdownGrace: .milliseconds(10)
        )
        await controller.markReadyForSelfTest()
    }

    override func tearDown() async throws {
        await controller.close()
        try FileManager.default.removeItem(at: directory)
    }

    func testTimeout_MatchesMacBound() {
        typealias Host = DesktopHostController<FakePlatform>
        XCTAssertEqual(Host.shortcutPressMicrophoneTimeout(hold: 0.3, doubleTap: 0.4), 2.5)
        XCTAssertEqual(Host.shortcutPressMicrophoneTimeout(hold: 1, doubleTap: 1), 4)
    }

    func testPress_OpensOneDiscardingCaptureUntilEnded() async throws {
        await controller.warmMicrophoneForShortcutPress(deviceID: "mic-a")
        await controller.warmMicrophoneForShortcutPress(deviceID: "mic-a")
        let capture = try XCTUnwrap(effects.captures.first)
        XCTAssertEqual(effects.captures.count, 1, "A repeated key-down reuses the open press capture")
        XCTAssertEqual(capture.deviceID, "mic-a")
        XCTAssertEqual(capture.log, ["start"])
        await controller.endShortcutPressMicrophone()
        XCTAssertEqual(capture.log, ["start", "stop", "destroy"])
    }

    func testRecordingCaptureReady_EndsPressCapture() async throws {
        await controller.warmMicrophoneForShortcutPress(deviceID: "")
        let capture = try XCTUnwrap(effects.captures.first)
        await controller.notifyRecordingFeedback(UUID(), handsFree: false, captureReady: true)
        XCTAssertEqual(capture.log, ["start", "stop", "destroy"])
    }

    func testDisabledOrBusyHost_NeverOpensMicrophone() async throws {
        try await controller.applyShortcutPressMicrophoneForTest(enabled: false)
        await controller.warmMicrophoneForShortcutPress(deviceID: "")
        XCTAssertTrue(effects.captures.isEmpty)
        try await controller.applyShortcutPressMicrophoneForTest(enabled: true)
        await controller.warmOperationalBlockForTest(true)
        await controller.warmMicrophoneForShortcutPress(deviceID: "")
        XCTAssertTrue(effects.captures.isEmpty)
    }

    func testClose_EndsPressCapture() async throws {
        await controller.warmMicrophoneForShortcutPress(deviceID: "")
        let capture = try XCTUnwrap(effects.captures.first)
        await controller.close()
        XCTAssertEqual(capture.log, ["start", "stop", "destroy"])
    }
}

extension DesktopHostController where Platform == FakePlatform {
    func applyShortcutPressMicrophoneForTest(enabled: Bool) throws {
        var changed = settings
        changed.configuration = try DesktopConfiguration(values: [
            ApplicationPreferenceKey.warmMicrophoneOnKeyPress.rawValue: AnyCodable(.bool(enabled))
        ])
        settings = changed
    }
}
