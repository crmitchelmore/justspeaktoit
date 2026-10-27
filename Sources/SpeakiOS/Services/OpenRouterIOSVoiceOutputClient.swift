#if os(iOS)
import AVFoundation
import Combine
import Foundation
import SpeakCore

/// Plays OpenRouter speech and owns each temporary response until playback finishes.
@MainActor
public final class OpenRouterIOSVoiceOutputClient: ObservableObject {
    @Published public private(set) var isSpeaking = false

    private let session: URLSession
    private let progressiveSpeech: OpenRouterProgressiveSpeechOption
    private let makeProgressivePlayback: () -> OpenRouterIOSProgressivePlayback
    private var synthesisTask: Task<OpenRouterSpeechResult, Error>?
    private var playback: OpenRouterIOSAudioPlayback?
    private var progressiveTask: Task<OpenRouterProgressiveSpeechResult, Error>?
    private var progressivePlayback: OpenRouterIOSProgressivePlayback?
    private var operationID: UUID?

    public init(session: URLSession = .shared) {
        self.session = session
        self.progressiveSpeech = .disabled
        self.makeProgressivePlayback = { OpenRouterIOSProgressivePlayback() }
    }

    init(
        session: URLSession,
        progressiveSpeech: OpenRouterProgressiveSpeechOption,
        makeProgressivePlayback: @escaping () -> OpenRouterIOSProgressivePlayback = {
            OpenRouterIOSProgressivePlayback()
        }
    ) {
        self.session = session
        self.progressiveSpeech = progressiveSpeech
        self.makeProgressivePlayback = makeProgressivePlayback
    }

    public func speak(text: String, apiKey: String, selectionID: String, speed: Double) async throws {
        try Task.checkCancellation()
        stop()
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenRouterIOSVoiceOutputError.missingAPIKey
        }
        guard let selection = OpenRouterSpeechSelection(id: selectionID) else {
            throw OpenRouterIOSVoiceOutputError.invalidSelection
        }
        let identifier = UUID()
        operationID = identifier
        defer {
            if operationID == identifier { stop() }
        }
        let client = OpenRouterAudioClient(apiKeyProvider: { apiKey }, session: session)
        if progressiveSpeech.allows(selection), speed.isFinite, speed == 1 {
            try await speakProgressively(text: text, selection: selection, client: client, operation: identifier)
        } else {
            try await speakFile(text: text, selection: selection, client: client, operation: identifier, speed: speed)
        }
    }

    private func speakFile(
        text: String, selection: OpenRouterSpeechSelection, client: OpenRouterAudioClient,
        operation identifier: UUID, speed: Double
    ) async throws {
        let task = Task {
            try await client.synthesize(
                text: text, model: selection.modelID, voice: selection.voice
            )
        }
        synthesisTask = task
        try await withTaskCancellationHandler {
            let result = try await task.value
            defer { try? FileManager.default.removeItem(at: result.audioURL) }
            try Task.checkCancellation()
            guard operationID == identifier else { throw CancellationError() }
            synthesisTask = nil
            try await playAudio(at: result.audioURL, operation: identifier, speed: speed)
        } onCancel: {
            // Cancel this run's network work without waiting for a UI actor hop.
            task.cancel()
        }
    }

    public func stop() {
        operationID = nil
        synthesisTask?.cancel()
        synthesisTask = nil
        progressiveTask?.cancel()
        progressiveTask = nil
        progressivePlayback?.stop()
        progressivePlayback = nil
        playback?.stop()
        playback = nil
        isSpeaking = false
    }

    private func speakProgressively(
        text: String, selection: OpenRouterSpeechSelection, client: OpenRouterAudioClient, operation identifier: UUID
    ) async throws {
        let player = makeProgressivePlayback()
        progressivePlayback = player
        let owner: OpenRouterIOSProgressivePlayback.SessionID
        do {
            owner = try player.start()
        } catch OpenRouterIOSProgressivePlayback.SetupFailure.unavailable {
            // No request has begun and no PCM was accepted; file synthesis happens once.
            try await speakFile(text: text, selection: selection, client: client, operation: identifier, speed: 1)
            return
        }
        let task = Task {
            try await client.synthesizeProgressively(
                text: text, model: selection.modelID, voice: selection.voice
            ) { [weak self] pcm in
                try await player.enqueue(pcm, session: owner)
                guard let self else { throw CancellationError() }
                try await self.acceptedPCM(operation: identifier)
            }
        }
        progressiveTask = task
        player.onInterruption = { [weak self] in
            guard self?.operationID == identifier else { return }
            task.cancel()
        }
        do {
            try await withTaskCancellationHandler {
                let result = try await task.value
                defer { try? FileManager.default.removeItem(at: result.speech.audioURL) }
                try requireCurrent(identifier)
                try player.checkInterruption(session: owner)
                progressiveTask = nil
                if result.completedFileRequired {
                    guard !result.pcmProduced else { throw OpenRouterIOSVoiceOutputError.playbackFailed }
                    player.stop(session: owner)
                    progressivePlayback = nil
                    try await playAudio(at: result.speech.audioURL, operation: identifier, speed: 1)
                } else {
                    guard result.pcmProduced else { throw OpenRouterIOSVoiceOutputError.playbackFailed }
                    try await player.finish(session: owner)
                    try requireCurrent(identifier)
                }
            } onCancel: {
                // Preserve immediate transport cancellation without requiring a UI actor hop.
                task.cancel()
            }
        } catch {
            if operationID == identifier { try player.checkInterruption(session: owner) }
            throw error
        }
    }

    private func acceptedPCM(operation identifier: UUID) throws {
        try requireCurrent(identifier)
        isSpeaking = true
    }

    private func requireCurrent(_ identifier: UUID) throws {
        try Task.checkCancellation()
        guard operationID == identifier else { throw CancellationError() }
    }

    private func playAudio(at url: URL, operation identifier: UUID, speed: Double) async throws {
        let operation = OpenRouterIOSAudioPlayback()
        playback = operation
        try operation.start(at: url, speed: speed)
        isSpeaking = true
        while !operation.isFinished {
            try await Task.sleep(for: .milliseconds(30))
            guard operationID == identifier else { throw CancellationError() }
            try operation.checkProgress()
        }
        try Task.checkCancellation()
        guard operationID == identifier else { throw CancellationError() }
        try operation.checkCompletion()
    }
}

public enum OpenRouterIOSVoiceOutputError: LocalizedError {
    case missingAPIKey
    case invalidSelection
    case playbackFailed
    case interrupted
    case recordingInProgress

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add your OpenRouter API key in Settings to use voice output."
        case .invalidSelection:
            "Choose an OpenRouter speech model and voice in Browse OpenRouter Audio."
        case .interrupted:
            "OpenRouter playback was interrupted. Retry voice output when audio is available."
        case .recordingInProgress:
            "Stop the current recording before playing OpenRouter voice output."
        case .playbackFailed:
            "OpenRouter audio could not be played. Try another speech model or voice."
        }
    }
}
#endif
