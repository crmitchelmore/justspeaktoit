#if DEBUG
import AVFoundation
import Foundation
import XCTest
@testable import SpeakApp

@MainActor
final class CoreJourneyRecordingSourceTests: XCTestCase {
    func testFileCapture_runsWithoutMicrophoneAndPreservesOwnership() async throws {
        let profile = CoreJourneyLaunchProfile(identifier: UUID())
        let suiteName = profile.suiteName
        let directory = profile.directory
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let permissions = PermissionsManager(statusProvider: { _ in .denied })
        let devices = AudioInputDeviceManager(appSettings: profile.settings)
        let manager = AudioFileManager(
            appSettings: profile.settings, permissionsManager: permissions,
            audioDeviceManager: devices, captureSource: CoreJourneyRecordingSource()
        )
        XCTAssertFalse(manager.requiresPhysicalInput)
        let start = try await manager.startRecording(owner: .dictation)
        XCTAssertFalse(start.usedWarmRecorder)
        XCTAssertEqual(try AVAudioFile(forReading: start.url).length, 4_000)
        XCTAssertEqual(try Data(contentsOf: start.url), CoreJourneyBatchFixture.audioData)
        do {
            _ = try await manager.startRecording(owner: .dictation)
            XCTFail("A second capture must not replace the active file")
        } catch AudioFileManagerError.alreadyRecording {
            // Expected: production manager retains single-owner capture admission.
        }
        await manager.cancelRecording(ifOwnedBy: .voiceEdit)
        XCTAssertTrue(FileManager.default.fileExists(atPath: start.url.path))
        let summary = try await manager.stopRecording()
        XCTAssertEqual(summary.url, start.url)
        XCTAssertEqual(summary.duration, 0.25)
        XCTAssertEqual(summary.fileSize, 8_044)
        XCTAssertEqual(permissions.status(for: .microphone), .denied)

        let next = try await manager.startRecording(owner: .dictation)
        XCTAssertNotEqual(next.url, start.url)
        await manager.cancelRecording(ifOwnedBy: .dictation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: next.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: start.url.path))
        do {
            _ = try await manager.stopRecording()
            XCTFail("Cancelled capture must not produce a late summary")
        } catch AudioFileManagerError.noActiveRecording {
            // Expected: a cancelled file cannot reach transcription.
        }
    }

    func testDefaultRecorder_stillRequiresPhysicalInput() {
        let profile = CoreJourneyLaunchProfile(identifier: UUID())
        defer {
            profile.defaults.removePersistentDomain(forName: profile.suiteName)
            try? FileManager.default.removeItem(at: profile.directory)
        }
        let manager = AudioFileManager(
            appSettings: profile.settings,
            permissionsManager: PermissionsManager(statusProvider: { _ in .denied }),
            audioDeviceManager: AudioInputDeviceManager(appSettings: profile.settings)
        )
        XCTAssertTrue(manager.requiresPhysicalInput)
    }

    func testHTTPFixture_rejectsWrongAudioModelCredentialsAndNetworkRoute() throws {
        let request = try makeRequest()
        XCTAssertTrue(CoreJourneyBatchURLProtocol.accepts(request))
        var wrongRoute = request
        wrongRoute.url = URL(string: "https://unexpected.invalid/chat/completions")
        XCTAssertFalse(CoreJourneyBatchURLProtocol.accepts(wrongRoute))
        var wrongKey = request
        wrongKey.setValue("Bearer different-key", forHTTPHeaderField: "Authorization")
        XCTAssertFalse(CoreJourneyBatchURLProtocol.accepts(wrongKey))
        XCTAssertFalse(CoreJourneyBatchURLProtocol.accepts(try makeRequest(audio: Data([0, 1, 2]))))
        XCTAssertFalse(CoreJourneyBatchURLProtocol.accepts(try makeRequest(model: "another/model")))
        XCTAssertFalse(CoreJourneyBatchURLProtocol.accepts(try makeRequest(streaming: true)))
    }

    func testCancelledSuspendedStart_cannotPublishLateCaptureAndAllowsNextRun() async throws {
        let gate = CaptureSourceGate()
        let source = SuspendedRecordingSource(startGate: gate)
        let manager = makeManager(source: source)
        let pending = Task { try await manager.startRecording(owner: .dictation) }
        await gate.waitUntilPaused()
        await manager.cancelRecording(ifOwnedBy: .voiceEdit)
        let ignoredCancellationCount = await source.cancellationCount
        XCTAssertEqual(ignoredCancellationCount, 0, "Startup already belongs to dictation")
        await manager.cancelRecording(ifOwnedBy: .dictation)
        await assertStartRejected(manager)
        await gate.release()
        do {
            _ = try await pending.value
            XCTFail("A cancelled source must not publish its late RecordingStart")
        } catch is CancellationError {
            // The source deliberately ignores cancellation and creates its file late.
        }
        let returnedURL = await source.lastStartedURL
        let lateURL = try XCTUnwrap(returnedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lateURL.path))
        do {
            _ = try await manager.stopRecording()
            XCTFail("Cancelled startup must leave no active capture")
        } catch AudioFileManagerError.noActiveRecording {}
        let replacement = try await manager.startRecording(owner: .dictation)
        let summary = try await manager.stopRecording()
        XCTAssertEqual(summary.url, replacement.url)
        XCTAssertNotEqual(summary.url, lateURL)
    }

    func testCancelDuringSuspendedStop_rejectsLateSummaryAndProtectsReplacement() async throws {
        let gate = CaptureSourceGate()
        let source = SuspendedRecordingSource(stopGate: gate)
        let manager = makeManager(source: source)
        let first = try await manager.startRecording(owner: .dictation)
        let pending = Task { try await manager.stopRecording() }
        await gate.waitUntilPaused()
        await manager.cancelRecording(ifOwnedBy: .dictation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        await assertStartRejected(manager)
        await gate.release()
        do {
            _ = try await pending.value
            XCTFail("A cancelled stop must not deliver its late summary")
        } catch is CancellationError {}
        let replacement = try await manager.startRecording(owner: .dictation)
        let summary = try await manager.stopRecording()
        XCTAssertEqual(summary.url, replacement.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.url.path))
    }

    func testSuspendedCancellation_reservesSourceUntilTeardownCompletes() async throws {
        let gate = CaptureSourceGate()
        let source = SuspendedRecordingSource(cancelGate: gate)
        let manager = makeManager(source: source)
        let first = try await manager.startRecording(owner: .dictation)
        let pending = Task { await manager.cancelRecording(ifOwnedBy: .dictation) }
        await gate.waitUntilPaused()
        await assertStartRejected(manager)
        await gate.release()
        await pending.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        let replacement = try await manager.startRecording(owner: .dictation)
        let summary = try await manager.stopRecording()
        XCTAssertEqual(summary.url, replacement.url)
    }

    private func assertStartRejected(_ manager: AudioFileManager) async {
        do {
            _ = try await manager.startRecording(owner: .dictation)
            XCTFail("Source ownership must remain reserved across suspended teardown")
        } catch AudioFileManagerError.alreadyRecording {
            // Expected while the old start/stop/cancel still owns a source operation.
        } catch {
            XCTFail("Unexpected admission error: \(error)")
        }
    }

    private func makeManager(source: any RecordingCaptureSource) -> AudioFileManager {
        let profile = CoreJourneyLaunchProfile(identifier: UUID())
        let suiteName = profile.suiteName
        let directory = profile.directory
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        return AudioFileManager(
            appSettings: profile.settings,
            permissionsManager: PermissionsManager(statusProvider: { _ in .denied }),
            audioDeviceManager: AudioInputDeviceManager(appSettings: profile.settings), captureSource: source
        )
    }

    private func makeRequest(
        audio: Data = CoreJourneyBatchFixture.audioData,
        model: String = CoreJourneyBatchFixture.model,
        streaming: Bool = false
    ) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer core-journey-fixture-not-a-real-key", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "stream": streaming,
            "messages": [["content": [[
                "type": "input_audio", "input_audio": ["data": audio.base64EncodedString(), "format": "wav"]
            ]]]]
        ])
        return request
    }
}
/// A one-shot continuation gate makes reentrancy deterministic without sleeps.
private actor CaptureSourceGate {
    private var paused: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var released = false

    func pause() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            paused = continuation
            observer?.resume()
            observer = nil
        }
    }

    func waitUntilPaused() async {
        guard paused == nil else { return }
        await withCheckedContinuation { observer = $0 }
    }

    func release() {
        released = true
        paused?.resume()
        paused = nil
    }
}

private actor SuspendedRecordingSource: RecordingCaptureSource {
    private let source = CoreJourneyRecordingSource()
    private let startGate: CaptureSourceGate?
    private let stopGate: CaptureSourceGate?
    private let cancelGate: CaptureSourceGate?
    private(set) var lastStartedURL: URL?
    private(set) var cancellationCount = 0

    init(
        startGate: CaptureSourceGate? = nil, stopGate: CaptureSourceGate? = nil, cancelGate: CaptureSourceGate? = nil
    ) {
        self.startGate = startGate
        self.stopGate = stopGate
        self.cancelGate = cancelGate
    }

    func start(in directory: URL) async throws -> RecordingStart {
        await startGate?.pause()
        let result = try await source.start(in: directory)
        lastStartedURL = result.url
        return result
    }

    func stop() async throws -> RecordingSummary {
        let summary = try await source.stop()
        await stopGate?.pause()
        return summary
    }

    func cancel(deleteFile: Bool) async {
        cancellationCount += 1
        await cancelGate?.pause()
        await source.cancel(deleteFile: deleteFile)
    }
}

#endif
