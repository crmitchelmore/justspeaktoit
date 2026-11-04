#if DEBUG
import Foundation
import SpeakCore

/// Streaming, silent-input and missing-credential journeys (#802). Each enters
/// at an existing production dependency seam: the live controller factory, the
/// recording capture source, the OpenRouter key provider and its URLSession.
enum CoreJourneyScenarioFixture {
    static let streamingModel = "core-journey/streaming-fixture"
    /// Each partial replaces the previous one. A revised word ("partial" →
    /// "partials") and a final that is not a concatenation of any partial make
    /// appended, stale or duplicated text distinguishable from the final.
    static let streamingPartials = [
        "Streaming",
        "Streaming partial",
        "Streaming partials become",
        "Streaming partials become one final"
    ]
    static let streamingFinal = "Streaming partials become one final transcript."
    static let credentialAcknowledgementFileName = "fixture-credential.json"
    static let missingKeyMessage =
        "Batch transcription requires an OpenRouter API key. Add one in Settings › API Keys."

    /// 250 ms of digital silence in the same 16 kHz mono PCM layout.
    static let silentAudioData: Data = {
        var data = CoreJourneyBatchFixture.audioData
        data.replaceSubrange(44..<data.count, with: Data(count: data.count - 44))
        return data
    }()
}

extension CoreJourneyBatchScenario {
    var recordingAudio: Data {
        self == .batchSilentInput ? CoreJourneyScenarioFixture.silentAudioData : CoreJourneyBatchFixture.audioData
    }
}

extension CoreJourneyLaunchProfile {
    func configureScenarioSettings() {
        switch batchScenario {
        case .streamingOff:
            settings.speedMode = .instant
            settings.streamingInsertionEnabled = false
            settings.transcriptionMode = .liveNative
            settings.liveTranscriptionModel = CoreJourneyScenarioFixture.streamingModel
        case .batchMissingKeyThenRecovery:
            settings.showHUDDuringSessions = true
            settings.shortenErrorDisplay = false
        case .batchOff, .batchPolishSuccess, .batchPolishFailureThenSuccess, .batchSilentInput:
            break
        }
    }

    func makeFixtureClient() -> OpenRouterAPIClient {
        switch batchScenario {
        case .batchPolishSuccess, .batchPolishFailureThenSuccess:
            return polishFixture.makeClient()
        case .batchSilentInput:
            return CoreJourneyBatchFixture.makeClient(protocolClass: CoreJourneySilentURLProtocol.self)
        case .batchMissingKeyThenRecovery:
            let slot = credentialSlot
            return CoreJourneyBatchFixture.makeClient(apiKeyProvider: { slot.key })
        case .batchOff, .streamingOff:
            return CoreJourneyBatchFixture.makeClient()
        }
    }

    func makeCaptureSource() -> any RecordingCaptureSource {
        CoreJourneyRecordingSource(audio: batchScenario.recordingAudio)
    }

    func makeLiveControllerOverride() -> ((String) -> any LiveTranscriptionController)? {
        guard batchScenario == .streamingOff else { return nil }
        let controller = CoreJourneyStreamingController(directory: directory)
        return { _ in controller }
    }
}

/// Emits fixed replacement partials while running and one final on stop. It
/// never sees audio: capture still runs through the synthetic recording source.
@MainActor
final class CoreJourneyStreamingController: LiveTranscriptionController {
    private struct Diagnostics: Encodable {
        let model: String?
        let starts: Int
        let stops: Int
        let emittedPartials: [String]
        let finals: [String]
        let unexpectedModels: [String]
    }

    weak var delegate: LiveTranscriptionSessionDelegate?
    private(set) var isRunning = false
    var stopCompletionTimeout: TimeInterval { 5 }
    private let diagnosticsURL: URL
    private var model: String?
    private var starts = 0
    private var stops = 0
    private var emitted: [String] = []
    private var finals: [String] = []
    private var unexpectedModels: [String] = []
    private var emitter: Task<Void, Never>?

    init(directory: URL) {
        diagnosticsURL = directory.appendingPathComponent("streaming-live.json")
    }

    func configure(language _: String?, model: String) {
        self.model = model
        if model != CoreJourneyScenarioFixture.streamingModel { unexpectedModels.append(model) }
        persist()
    }

    func start() async throws {
        guard !isRunning else { throw TranscriptionManagerError.liveSessionAlreadyRunning }
        isRunning = true
        starts += 1
        persist()
        emitter = Task { @MainActor [weak self] in
            for partial in CoreJourneyScenarioFixture.streamingPartials {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, self.isRunning, !Task.isCancelled else { return }
                self.emitted.append(partial)
                self.persist()
                self.delegate?.liveTranscriber(self, didUpdateWith: LiveTranscriptionUpdate(text: partial))
            }
        }
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        emitter?.cancel()
        emitter = nil
        stops += 1
        let text = CoreJourneyScenarioFixture.streamingFinal
        finals.append(text)
        persist()
        delegate?.liveTranscriber(self, didFinishWith: TranscriptionResult(
            text: text, segments: [], confidence: nil, duration: CoreJourneyBatchFixture.duration,
            modelIdentifier: model ?? CoreJourneyScenarioFixture.streamingModel,
            cost: nil, rawPayload: nil, debugInfo: nil
        ))
    }

    private func persist() {
        let snapshot = Diagnostics(
            model: model, starts: starts, stops: stops, emittedPartials: emitted,
            finals: finals, unexpectedModels: unexpectedModels
        )
        do {
            try FileManager.default.createDirectory(
                at: diagnosticsURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: diagnosticsURL, options: .atomic)
        } catch {
            preconditionFailure("Cannot write streaming fixture diagnostics: \(error.localizedDescription)")
        }
    }
}

/// Accepts only the exact silent WAV, answering as a provider does for silence:
/// with an empty transcript, which production rejects as an invalid response.
/// Every other request is rejected and counted.
/// Stands in for the user's credential store: empty until the test asks the app
/// to save the fixture key between recordings, then read on every request. The
/// sandboxed UI runner cannot write into the app's profile directory, so the
/// request arrives as a UUID-scoped distributed notification without payload.
final class CoreJourneyCredentialSlot: @unchecked Sendable {
    static func notificationName(for identifier: UUID) -> Notification.Name {
        Notification.Name("com.justspeaktoit.tests.core-journey.\(identifier.uuidString).provide-credential")
    }

    private let lock = NSLock()
    private var stored: String?
    private let acknowledgement: URL
    private var observer: NSObjectProtocol?

    init(identifier: UUID, directory: URL) {
        acknowledgement = directory.appendingPathComponent(
            CoreJourneyScenarioFixture.credentialAcknowledgementFileName
        )
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.notificationName(for: identifier), object: nil, queue: .main
        ) { [weak self] _ in self?.provide() }
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    var key: String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func provide() {
        lock.lock()
        stored = CoreJourneyBatchFixture.fixtureKey
        lock.unlock()
        do {
            try FileManager.default.createDirectory(
                at: acknowledgement.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(#"{"provided":true}"#.utf8).write(to: acknowledgement, options: .atomic)
        } catch {
            preconditionFailure("Cannot acknowledge fixture credential: \(error.localizedDescription)")
        }
    }
}

final class CoreJourneySilentURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var accepted = 0
    nonisolated(unsafe) private static var rejected = 0

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var normalized = request
        let body = CoreJourneyBatchURLProtocol.body(of: request)
        // Clearing the stream also clears httpBody, so it must come first.
        normalized.httpBodyStream = nil
        normalized.httpBody = body
        let isAccepted = CoreJourneyBatchURLProtocol.accepts(
            normalized, audio: CoreJourneyScenarioFixture.silentAudioData
        )
        Self.record(accepted: isAccepted)
        guard isAccepted, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil),
              let data = try? JSONSerialization.data(withJSONObject: [
                  "id": "core-journey-silent-response", "model": CoreJourneyBatchFixture.model,
                  "choices": [["index": 0, "message": ["role": "assistant", "content": ""]]]
              ]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func record(accepted isAccepted: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isAccepted { accepted += 1 } else { rejected += 1 }
        // Unit tests drive the protocol without a launched profile to record into.
        guard let rawID = ProcessInfo.processInfo.environment[CoreJourneyLaunchProfile.environmentKey],
              let identifier = UUID(uuidString: rawID) else { return }
        let directory = CoreJourneyLaunchProfile.launchDirectory(for: identifier)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: ["acceptedRequests": accepted, "rejectedRequests": rejected], options: [.sortedKeys]
            )
            try data.write(to: directory.appendingPathComponent("batch-http.json"), options: .atomic)
        } catch {
            preconditionFailure("Cannot persist silent HTTP diagnostics: \(error.localizedDescription)")
        }
    }
}
#endif
