import AVFoundation
import CryptoKit
import Foundation
import SpeakCore

/// Streams one microphone capture to every selected live model at once
/// (issue #1101).
///
/// Normal dictation gives each provider controller its own `AVAudioEngine`
/// and tap; N of those cannot share a microphone. This controller owns a
/// single engine and tap, converts each tap buffer once per distinct provider
/// sample rate, and hands the PCM to every shared `StreamingTranscriptionClient`
/// at that rate — the same per-client contract `SharedClientLiveController`
/// honours. Apple SpeechAnalyzer joins the same tap through its own buffer
/// converter. The 16 kHz stream is also retained so the sample can be hashed
/// and kept for later file-mode rounds.
@MainActor
final class ComparisonLiveFanOut {
    struct Update {
        let entryID: UUID
        let text: String
        let isFinal: Bool
    }

    struct Outcome {
        let entries: [ModelComparisonEntry]
        /// Linear16 mono PCM at `captureSampleRate`.
        let pcm16: Data
        let durationSeconds: Double
        let contentHash: String
    }

    nonisolated static let captureSampleRate = 16_000

    private let permissionsManager: PermissionsManager
    private let audioDeviceManager: AudioInputDeviceManager
    private let secureStorage: SecureAppStorage
    private let appSettings: AppSettings
    private let processor = ComparisonFanOutProcessor()
    private var audioEngine = AVAudioEngine()
    private var activeInputSession: AudioInputDeviceManager.SessionContext?
    private var lanes: [ComparisonLiveLane] = []
    private var captureStartedAt: Date?
    private(set) var isRunning = false

    init(
        permissionsManager: PermissionsManager,
        audioDeviceManager: AudioInputDeviceManager,
        secureStorage: SecureAppStorage,
        appSettings: AppSettings
    ) {
        self.permissionsManager = permissionsManager
        self.audioDeviceManager = audioDeviceManager
        self.secureStorage = secureStorage
        self.appSettings = appSettings
    }

    /// Opens every model's session and starts the microphone. Models that
    /// fail to open are returned with an error and simply do not receive
    /// audio; the capture still runs for the rest.
    func start(
        candidates: [ComparisonCandidate],
        language: String?,
        localeIdentifier: String,
        onUpdate: @escaping @MainActor (Update) -> Void
    ) async throws -> [ModelComparisonEntry] {
        guard !isRunning else { throw TranscriptionManagerError.liveSessionAlreadyRunning }
        let permission = await permissionsManager.ensureGranted(.microphone)
        guard permission.isGranted else { throw TranscriptionManagerError.microphonePermissionMissing }

        activeInputSession = await audioDeviceManager.beginUsingPreferredInput()
        audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard audioInputFormatIsUsable(inputFormat) else {
            await cleanup()
            throw TranscriptionManagerError.noUsableAudioInput
        }

        lanes = []
        for candidate in candidates {
            lanes.append(await openLane(
                for: candidate,
                inputFormat: inputFormat,
                language: language,
                localeIdentifier: localeIdentifier,
                onUpdate: onUpdate
            ))
        }
        guard lanes.contains(where: { $0.isOpen }) else {
            await cleanup()
            throw ComparisonRunError.noUsableModels
        }

        configureProcessor(inputFormat: inputFormat)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [processor] buffer, _ in
            processor.handleAudioTap(buffer)
        }
        do {
            try await startAudioEngineAfterInputDeviceSettles(audioEngine)
        } catch {
            await cleanup()
            throw normalisedAudioInputStartError(error)
        }
        captureStartedAt = Date()
        for lane in lanes {
            lane.captureStartedAt = captureStartedAt
        }
        isRunning = true
        return lanes.map(\.entry)
    }

    /// Stops the microphone, lets every session finish, and returns the
    /// entries with their final transcripts, latency and estimated cost.
    func stop() async -> Outcome {
        let stoppedAt = Date()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        let capture = processor.finish()
        let duration = Double(capture.count / 2) / Double(Self.captureSampleRate)
        let hash = SHA256.hash(data: capture).map { String(format: "%02x", $0) }.joined()

        await withTaskGroup(of: Void.self) { group in
            for lane in lanes where lane.isOpen {
                group.addTask { await lane.finish(stoppedAt: stoppedAt) }
            }
        }
        let entries = lanes.map { lane -> ModelComparisonEntry in
            var entry = lane.entry
            if entry.errorDescription == nil {
                entry.estimatedCostUSD = TranscriptionPricing.estimatedCostUSD(
                    modelID: entry.modelID, durationSeconds: duration
                )
            }
            return entry
        }
        lanes = []
        isRunning = false
        captureStartedAt = nil
        await endActiveInputSession()
        return Outcome(entries: entries, pcm16: capture, durationSeconds: duration, contentHash: hash)
    }

    /// Abandons the capture without waiting for transcripts.
    func cancel() async {
        for lane in lanes {
            lane.abandon()
        }
        await cleanup()
    }

    private func configureProcessor(inputFormat: AVAudioFormat) {
        let openLanes = lanes.filter(\.isOpen)
        processor.configure(
            clients: openLanes.compactMap { lane in
                guard let client = lane.client, let rate = lane.sampleRate else { return nil }
                return (client, rate)
            },
            appleLanes: openLanes.compactMap { lane in
                guard let session = lane.appleSession, let converter = lane.appleConverter else { return nil }
                return (session, converter)
            },
            inputFormat: inputFormat
        )
    }

    private func openLane(
        for candidate: ComparisonCandidate,
        inputFormat: AVAudioFormat,
        language: String?,
        localeIdentifier: String,
        onUpdate: @escaping @MainActor (Update) -> Void
    ) async -> ComparisonLiveLane {
        let lane = ComparisonLiveLane(candidate: candidate)
        let entryID = lane.entry.id
        let deliver: @Sendable (String, Bool) -> Void = { text, isFinal in
            Task { @MainActor in
                lane.record(text: text, isFinal: isFinal)
                onUpdate(Update(entryID: entryID, text: lane.displayText, isFinal: isFinal))
            }
        }
        do {
            switch candidate.engine {
            case .sharedStreamingClient(let route):
                try await lane.openSharedClient(
                    route: route,
                    apiKey: loadAPIKey(identifier: route.apiKeyIdentifier),
                    language: language,
                    keywords: [.meta, .google].contains(route.provider)
                        ? MetaMuseVoiceTranscribe.keywords(from: appSettings.transcriptionKeywords) : [],
                    azureEndpoint: Self.configuredAzureEndpoint,
                    onTranscript: deliver
                )
            case .appleSpeechAnalyzer:
                try await lane.openAppleSession(
                    inputFormat: inputFormat,
                    localeIdentifier: localeIdentifier,
                    onTranscript: deliver
                )
            case .cloudBatch, .downloadedLocal:
                throw ComparisonRunError.notStreamable(candidate.displayName)
            }
        } catch {
            lane.entry.errorDescription = error.localizedDescription
        }
        return lane
    }

    /// The Azure Speech resource endpoint the settings store, or "" when unset.
    nonisolated static var configuredAzureEndpoint: String {
        (UserDefaults.standard.string(forKey: AzureSpeechConfiguration.endpointDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadAPIKey(identifier: String?) async throws -> String {
        guard let identifier else { return "" }
        let apiKey: String
        do {
            apiKey = try await secureStorage.secret(identifier: identifier)
        } catch let error as SecureAppStorageError {
            if case .valueNotFound = error { throw TranscriptionProviderError.apiKeyMissing }
            throw error
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptionProviderError.apiKeyMissing
        }
        return apiKey
    }

    private func cleanup() async {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        _ = processor.finish()
        lanes = []
        isRunning = false
        captureStartedAt = nil
        await endActiveInputSession()
    }

    private func endActiveInputSession() async {
        guard let session = activeInputSession else { return }
        activeInputSession = nil
        await audioDeviceManager.endUsingPreferredInput(session: session)
    }
}
