import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import XCTest

final class DesktopHostLiveProjectionTests: XCTestCase {
    func testActualHostForwardsEmptyRetractionToWindowAndClearsLiveHUD() async throws {
        FakeLog.shared.reset()
        DesktopHostModels.configure(streamingQualified: true)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-live-projection-\(UUID().uuidString)")
        let effects = HostLiveProjectionEffects()
        let controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        await controller.markReadyForSelfTest()
        let modelIndex = try XCTUnwrap(DesktopHostModels.all.firstIndex {
            $0.id == AssemblyAIModels.universal36ProStreamingID
        })
        let credential = try XCTUnwrap(DesktopHostModels.provider(
            for: AssemblyAIModels.universal36ProStreamingID
        )).apiKeyIdentifier
        FakeLog.shared.setKey("synthetic", name: credential)
        do {
            await controller.toggle(
                target: "editor", modelIndex: modelIndex, deviceID: "", targetExecutablePath: nil,
                textOutput: FakeTextOutput()
            )
            effects.client.emit("Draft words")
            try await waitFor {
                FakeLog.shared.transcripts.last == "Draft words"
                    && FakeLog.shared.huds.last?.liveText == "Draft words"
            }
            effects.client.emit("")
            try await waitFor {
                FakeLog.shared.transcripts.last == ""
                    && FakeLog.shared.huds.last?.phase == .recording
                    && FakeLog.shared.huds.last?.liveText == nil
            }
            XCTAssertTrue(effects.outputs.isEmpty, "Live preview never takes final insertion ownership")
            await controller.close()
            let updates = FakeLog.shared.transcripts
            effects.client.emit("Retired callback")
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(FakeLog.shared.transcripts, updates)
        } catch {
            await controller.close()
            try FileManager.default.removeItem(at: directory)
            throw error
        }
        await controller.close()
        try FileManager.default.removeItem(at: directory)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Host did not forward the authoritative transcript projection")
    }
}

private final class HostLiveProjectionEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakePlatform
    let client = HostProjectionClient()
    private let base = SyntheticEffects()
    var outputs: [(FakeJob, String)] { base.outputs }

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
    ) -> (any FinalizingStreamingTranscriptionClient)? { client }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult {
        try await base.transcribe(request, with: controller)
    }
    func perform(_ job: FakeJob, text: String) -> String { base.perform(job, text: text) }
    func writeSettings(_ data: Data, to url: URL) throws { try base.writeSettings(data, to: url) }
}

private final class HostProjectionClient: FinalizingStreamingTranscriptionClient,
    StreamingTranscriptSnapshotProviding, @unchecked Sendable {
    let finalShape = TranscriptFinalShape.standaloneSegments
    private let lock = NSLock()
    private var display = ""
    private var callback: ((String, Bool) -> Void)?

    func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        lock.withLock { callback = onTranscript }
    }
    func sendAudio(_ audioData: Data) {}
    func stop() {}
    func finishAndWait() async -> String? { lock.withLock { display } }
    func transcriptSnapshot(captureDuration: TimeInterval) -> StreamingTranscriptSnapshot {
        lock.withLock { StreamingTranscriptSnapshot(displayText: display) }
    }
    func emit(_ text: String) {
        let receiver = lock.withLock { display = text; return callback }
        receiver?(text, false)
    }
}
