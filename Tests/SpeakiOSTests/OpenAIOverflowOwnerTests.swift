#if os(iOS)
import AVFoundation
import XCTest
@testable import SpeakiOSLib

@MainActor
final class OpenAIOverflowOwnerTests: XCTestCase {
    func testForegroundOverflow_finishesOncePreservingTextAndOriginalRecording() async throws {
        let fixture = try OverflowOwnerFixture()
        defer { fixture.cleanUp() }
        let coordinator = TranscriberCoordinator(
            sharedState: fixture.shared, historyManager: fixture.history,
            sessionFactory: { try IOSTranscriptionSession(openAI: fixture.transcriber) }
        )
        var ownerStops = 0
        coordinator.onCaptureDisruption = {
            ownerStops += 1
            _ = await coordinator.stop()
        }
        try await coordinator.start()
        let originalURL = try XCTUnwrap(fixture.transcriber.audioRecorder.currentFileURL)
        await fixture.deliverPartial()
        fixture.overflow()
        fixture.socket.emit(["type": "error", "error": ["message": "Synthetic finalisation failure"]])
        fixture.socket.acknowledge()
        await settle { fixture.finalResults == 1 && fixture.history.items.count == 1 }
        XCTAssertEqual(ownerStops, 1)
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertEqual(coordinator.partialText, "Retained synthetic words")
        XCTAssertEqual(fixture.history.items.count, 1)
        XCTAssertEqual(
            coordinator.error?.localizedDescription,
            OpenAIRealtimeError.preReadyAudioOverflow.localizedDescription
        )
        try fixture.assertRetainedAudio(at: originalURL)
        XCTAssertEqual(fixture.socket.audio.count, 1)
    }

    func testHardwareOverflow_preservesHistoryOnlyDestination() async throws {
        let fixture = try OverflowOwnerFixture()
        defer { fixture.cleanUp() }
        let service = fixture.makeService()
        try await service.startRecording(requiresLiveActivity: false, destination: .historyOnly)
        let originalURL = try XCTUnwrap(fixture.transcriber.audioRecorder.currentFileURL)
        await fixture.deliverPartial()
        fixture.overflow()
        fixture.socket.acknowledge()
        await settle { fixture.finalResults == 1 && fixture.history.items.count == 1 }
        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(service.partialText, "Retained synthetic words")
        XCTAssertEqual(fixture.pasteboard.string, "Original clipboard")
        XCTAssertNotNil(service.lastSessionError as? OpenAIRealtimeError)
        try fixture.assertRetainedAudio(at: originalURL)
    }

    func testKeyboardOverflow_delegatesOnceToOriginalRequestOwner() async throws {
        let fixture = try OverflowOwnerFixture()
        defer { fixture.cleanUp() }
        let service = fixture.makeService()
        var keyboardResults: [String] = []
        try await service.startRecording(
            sharesLiveTranscript: false, requiresLiveActivity: false, destination: .historyOnly,
            onCaptureDisruption: {
                let result = await service.stopRecording(destination: .historyOnly, saveToHistory: false)
                keyboardResults.append(result.text)
            }
        )
        let originalURL = try XCTUnwrap(fixture.transcriber.audioRecorder.currentFileURL)
        await fixture.deliverPartial()
        fixture.overflow()
        fixture.socket.acknowledge()
        await settle { keyboardResults.count == 1 }
        XCTAssertEqual(keyboardResults, ["Retained synthetic words"])
        XCTAssertEqual(fixture.finalResults, 1)
        XCTAssertTrue(fixture.history.items.isEmpty, "History belongs to the original keyboard request owner")
        XCTAssertEqual(fixture.pasteboard.string, "Original clipboard")
        XCTAssertNotEqual(fixture.shared.lastCompletedTranscript, "Retained synthetic words")
        try fixture.assertRetainedAudio(at: originalURL)
    }

    func testStopNearOverflow_doesNotDuplicateFinalResultOrHistory() async throws {
        let fixture = try OverflowOwnerFixture()
        defer { fixture.cleanUp() }
        let service = fixture.makeService()
        try await service.startRecording(requiresLiveActivity: false, destination: .historyOnly)
        await fixture.deliverPartial()
        fixture.overflow()
        fixture.socket.acknowledge()
        let result = await service.stopRecording(destination: .historyOnly)
        XCTAssertEqual(result.text, "Retained synthetic words")
        await service.finishCaptureAfterDisruption()
        XCTAssertEqual(fixture.finalResults, 1)
        XCTAssertEqual(fixture.history.items.count, 1)
        XCTAssertFalse(service.isRunning)
    }

    func testCancelAfterOverflow_discardsAndQueuedCallbacksCannotStopFreshRun() async throws {
        let fixture = try OverflowOwnerFixture()
        defer { fixture.cleanUp() }
        let coordinator = TranscriberCoordinator(
            sharedState: fixture.shared, historyManager: fixture.history,
            sessionFactory: { try IOSTranscriptionSession(openAI: fixture.transcriber) }
        )
        try await coordinator.start()
        let cancelledURL = try XCTUnwrap(fixture.transcriber.audioRecorder.currentFileURL)
        let oldSocket = fixture.socket
        fixture.overflow() // Queues a MainActor error; Cancel wins before it can be delivered.
        coordinator.cancel()
        try await coordinator.start()
        oldSocket.acknowledge()
        await fixture.deliverPartial()
        XCTAssertTrue(coordinator.isRunning)
        XCTAssertNil(coordinator.error)
        XCTAssertEqual(fixture.finalResults, 0)
        XCTAssertTrue(fixture.history.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledURL.path))
        let freshPCM = Data(repeating: 1, count: 4_800)
        fixture.client.sendAudio(freshPCM)
        fixture.socket.acknowledge()
        _ = await coordinator.stop()
        XCTAssertEqual(fixture.socket.audio, [freshPCM])
        XCTAssertEqual(fixture.finalResults, 1)
        XCTAssertEqual(fixture.history.items.count, 1)
    }

    private func settle(_ predicate: () -> Bool) async {
        for _ in 0..<300 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate(), "Owner finalisation did not settle")
    }
}

@MainActor
private final class OverflowOwnerFixture {
    let defaults: UserDefaults
    let suite = "OpenAIOverflowOwner.\(UUID())"
    let directory: URL
    let shared: SharedTranscriptionState
    let history: iOSHistoryManager
    let pasteboard = OverflowOwnerPasteboard()
    private let originalLiveActivities: Bool
    private var recordingURLs: [URL] = []
    private(set) var socket = OverflowTestSocket()
    private(set) var client: OpenAIRealtimeWebSocketClient!
    private(set) var transcriber: OpenAIRealtimeLiveTranscriber!
    var finalResults = 0

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        shared = SharedTranscriptionState(defaults: defaults)
        history = iOSHistoryManager(
            fileURL: directory.appendingPathComponent("history.json"), syncEnabled: false, userDefaults: defaults
        )
        originalLiveActivities = AppSettings.shared.liveActivitiesEnabled
        AppSettings.shared.liveActivitiesEnabled = false
        transcriber = OpenAIRealtimeLiveTranscriber(
            audioSessionManager: AudioSessionManager(),
            makeClient: { [unowned self] in
                let socket = OverflowTestSocket()
                self.socket = socket
                let client = OpenAIRealtimeWebSocketClient(
                    apiKey: "synthetic-test-key", model: "gpt-live-transcribe", language: nil, sampleRate: 24_000,
                    makeSocket: { _ in socket }
                )
                self.client = client
                return client
            },
            startCapture: { [unowned self] recorder in
                let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000))
                buffer.frameLength = 24_000
                for frame in 0..<24_000 {
                    buffer.floatChannelData?[0][frame] = Float(sin(Double(frame) * 0.1)) * 0.25
                }
                let url = try recorder.startRecording(format: format)
                self.recordingURLs.append(url)
                recorder.writeBuffer(buffer)
            }
        )
        transcriber.configure(apiKey: "synthetic-test-key")
        transcriber.onFinalResult = { [weak self] _ in self?.finalResults += 1 }
    }

    func makeService() -> TranscriptionRecordingService {
        TranscriptionRecordingService(
            sharedState: shared, historyManager: history,
            polishClipboard: PolishClipboard(pasteboard: pasteboard, now: { 100 }, isActive: { true }),
            hasPolishingKey: { false }, polish: { text, _, _ in text },
            sessionFactory: { [unowned self] in try IOSTranscriptionSession(openAI: self.transcriber) }
        )
    }

    func deliverPartial() async {
        socket.emit([
            "type": "conversation.item.input_audio_transcription.delta",
            "item_id": "synthetic", "delta": "Retained synthetic words"
        ])
        for _ in 0..<100 where transcriber.partialText.isEmpty { await Task.yield() }
        XCTAssertEqual(transcriber.partialText, "Retained synthetic words")
    }

    func overflow() {
        client.sendAudio(Data(repeating: 0, count: 240_000))
        for _ in 0..<10 { client.sendAudio(Data(repeating: 0, count: 4_800)) }
    }

    func assertRetainedAudio(at url: URL) throws {
        XCTAssertFalse(transcriber.audioRecorder.isRecording)
        let file = try AVAudioFile(forReading: url)
        XCTAssertGreaterThan(file.length, 0, "The original writer must retain decodable audio")
    }

    func cleanUp() {
        transcriber.cancel()
        AppSettings.shared.liveActivitiesEnabled = originalLiveActivities
        defaults.removePersistentDomain(forName: suite)
        for url in recordingURLs { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class OverflowOwnerPasteboard: PolishPasteboard {
    var changeCount = 0
    var ownershipToken: String?
    var string: String? = "Original clipboard"
    func write(_ text: String, token: String) {
        changeCount += 1
        ownershipToken = token
        string = text
    }
}
#endif
