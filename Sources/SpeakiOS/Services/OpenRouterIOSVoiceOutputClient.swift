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
    private var synthesisTask: Task<OpenRouterSpeechResult, Error>?
    private var playback: OpenRouterIOSAudioPlayback?
    private var operationID: UUID?

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func speak(text: String, apiKey: String, selectionID: String, speed: Double) async throws {
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
        try await withTaskCancellationHandler {
            let client = OpenRouterAudioClient(apiKeyProvider: { apiKey }, session: session)
            let task = Task {
                try await client.synthesize(
                    text: text, model: selection.modelID, voice: selection.voice
                )
            }
            synthesisTask = task
            let result = try await task.value
            defer { try? FileManager.default.removeItem(at: result.audioURL) }
            try Task.checkCancellation()
            guard operationID == identifier else { throw CancellationError() }
            synthesisTask = nil
            try await playAudio(at: result.audioURL, operation: identifier, speed: speed)
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.operationID == identifier else { return }
                self?.stop()
            }
        }
    }

    public func stop() {
        operationID = nil
        synthesisTask?.cancel()
        synthesisTask = nil
        playback?.stop()
        playback = nil
        isSpeaking = false
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
