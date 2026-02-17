#if os(iOS)
import Foundation
import SpeakCore
import SwiftUI
import os.log

// MARK: - Conversation Persistence

/// Manages persisting OpenClaw conversations to disk.
@MainActor
public final class ConversationStore: ObservableObject {
    public static let shared = ConversationStore()

    @Published public private(set) var conversations: [OpenClawClient.Conversation] = []

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = documentsURL.appendingPathComponent("openclaw-conversations.json")
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        Task { await load() }
    }

    public func createConversation(title: String = "New Conversation") -> OpenClawClient.Conversation {
        let sessionKey = "speak-ios:voice:\(UUID().uuidString.prefix(8).lowercased())"
        var conv = OpenClawClient.Conversation(
            sessionKey: sessionKey,
            title: title
        )
        conversations.insert(conv, at: 0)
        save()
        return conv
    }

    public func addMessage(_ message: OpenClawClient.ChatMessage, to conversationId: String) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }) else { return }
        conversations[idx].messages.append(message)
        conversations[idx].updatedAt = Date()

        // Auto-title from first user message
        if conversations[idx].title == "New Conversation",
           message.role == "user" {
            let title = String(message.content.prefix(50))
            conversations[idx].title = title.count < message.content.count ? title + "…" : title
        }

        // Move to top
        let conv = conversations.remove(at: idx)
        conversations.insert(conv, at: 0)
        save()
    }

    public func deleteConversation(_ id: String) {
        conversations.removeAll { $0.id == id }
        save()
    }

    public func clearAll() {
        conversations.removeAll()
        save()
    }

    // MARK: - Persistence

    private func load() async {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            conversations = try decoder.decode([OpenClawClient.Conversation].self, from: data)
        } catch {
            print("[ConversationStore] Failed to load: \(error)")
        }
    }

    private func save() {
        do {
            let data = try encoder.encode(conversations)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[ConversationStore] Failed to save: \(error)")
        }
    }
}

// MARK: - OpenClaw Chat Coordinator

/// Coordinates the voice→text→gateway→summarise→TTS pipeline.
@MainActor
public final class OpenClawChatCoordinator: ObservableObject {
    // MARK: - Published State

    @Published public var connectionState: OpenClawClient.ConnectionState = .disconnected
    @Published public var currentConversation: OpenClawClient.Conversation?
    @Published public var isRecording = false
    @Published public var isProcessing = false
    @Published public var isSpeaking = false
    @Published public var partialTranscript = ""
    @Published public var streamingResponse = ""
    @Published public var error: Error?

    // MARK: - Dependencies

    private let client = OpenClawClient()
    private let ttsClient = DeepgramTTSClient()
    private let summariser = VoiceSummariser()
    private let store = ConversationStore.shared
    private let settings = OpenClawSettings.shared
    private let appSettings = AppSettings.shared

    private var transcriber: TranscriberCoordinator?
    private var currentRunId: String?
    private var accumulatedResponse = ""

    private let logger = Logger(subsystem: "com.justspeaktoit.ios", category: "OpenClawChat")

    // MARK: - Init

    public init() {
        setupClientCallbacks()
    }

    // MARK: - Connection

    public func connect() {
        guard settings.isConfigured else {
            error = OpenClawError.notConnected
            return
        }

        let config = OpenClawClient.ConnectConfig(
            gatewayURL: settings.gatewayURL,
            token: settings.token,
            clientName: "speak-ios",
            sessionKey: currentConversation?.sessionKey ?? "speak-ios:voice"
        )

        client.connect(config: config)
    }

    public func disconnect() {
        client.disconnect()
    }

    // MARK: - Conversation Management

    public func startNewConversation() {
        let conv = store.createConversation()
        currentConversation = conv

        // Reconnect with new session key if already connected
        if case .connected = connectionState {
            disconnect()
            connect()
        }
    }

    public func selectConversation(_ conversation: OpenClawClient.Conversation) {
        currentConversation = conversation
        streamingResponse = ""

        // Reconnect with this conversation's session key
        if case .connected = connectionState {
            disconnect()
        }
        connect()
    }

    // MARK: - Voice Input

    /// Start recording voice input using the app's configured transcription provider.
    public func startVoiceInput() async throws {
        guard !isRecording else { return }

        let coordinator = TranscriberCoordinator()
        self.transcriber = coordinator
        isRecording = true
        partialTranscript = ""

        try await coordinator.start()

        // Monitor partial text updates
        Task { @MainActor in
            while self.isRecording, let activeTranscriber = self.transcriber {
                self.partialTranscript = activeTranscriber.partialText
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Stop recording and send the transcribed text to OpenClaw.
    public func stopVoiceInputAndSend() async {
        guard isRecording, let coordinator = transcriber else { return }

        let result = await coordinator.stop()
        isRecording = false
        transcriber = nil

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        partialTranscript = ""
        await sendTextMessage(text)
    }

    /// Cancel voice input without sending.
    public func cancelVoiceInput() {
        transcriber?.cancel()
        transcriber = nil
        isRecording = false
        partialTranscript = ""
    }

    // MARK: - Text Sending

    public func sendTextMessage(_ text: String) async {
        guard let conv = currentConversation else {
            startNewConversation()
            // Small delay for connection
            try? await Task.sleep(for: .milliseconds(500))
            await sendTextMessage(text)
            return
        }

        // Ensure connected
        if case .disconnected = connectionState {
            connect()
            try? await Task.sleep(for: .milliseconds(1000))
        }

        // Add user message
        let userMessage = OpenClawClient.ChatMessage(role: "user", content: text)
        store.addMessage(userMessage, to: conv.id)
        currentConversation = store.conversations.first { $0.id == conv.id }

        isProcessing = true
        streamingResponse = ""
        accumulatedResponse = ""

        client.sendMessage(text, sessionKey: conv.sessionKey) { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let runId):
                    self?.currentRunId = runId
                    self?.logger.info("Message sent, runId: \(runId)")
                case .failure(let error):
                    self?.error = error
                    self?.isProcessing = false
                    self?.logger.error("Send failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Private

    private func setupClientCallbacks() {
        client.onConnectionStateChanged = { [weak self] state in
            Task { @MainActor in
                self?.connectionState = state
            }
        }

        client.onChatDelta = { [weak self] runId, delta in
            Task { @MainActor in
                guard self?.currentRunId == runId else { return }
                // Delta events carry cumulative text (full content so far),
                // not incremental fragments — replace, don't append.
                self?.accumulatedResponse = delta
                self?.streamingResponse = delta
            }
        }

        client.onChatFinal = { [weak self] runId, finalMessage in
            Task { @MainActor in
                guard let self, self.currentRunId == runId else { return }

                let responseText = finalMessage.isEmpty ? self.accumulatedResponse : finalMessage
                self.isProcessing = false
                self.streamingResponse = ""
                self.accumulatedResponse = ""

                guard let conv = self.currentConversation else { return }

                // Add assistant message
                let assistantMessage = OpenClawClient.ChatMessage(
                    role: "assistant",
                    content: responseText
                )
                self.store.addMessage(assistantMessage, to: conv.id)
                self.currentConversation = self.store.conversations.first { $0.id == conv.id }

                // Summarise and speak if enabled
                if self.settings.ttsEnabled && self.appSettings.hasDeepgramKey {
                    await self.summariseAndSpeak(responseText)
                }
            }
        }

        client.onChatError = { [weak self] runId, errorMessage in
            Task { @MainActor in
                guard self?.currentRunId == runId else { return }
                self?.error = OpenClawError.serverError(errorMessage)
                self?.isProcessing = false
            }
        }
    }

    private func summariseAndSpeak(_ text: String) async {
        do {
            var spokenText = text

            // Summarise if enabled
            if settings.summariseResponses && appSettings.hasOpenRouterKey {
                spokenText = try await summariser.summarise(
                    text,
                    apiKey: appSettings.openRouterAPIKey
                )
            }

            // Apply TTS settings
            ttsClient.model = settings.ttsModel
            ttsClient.voice = settings.ttsVoice
            ttsClient.speed = settings.ttsSpeed

            // Speak via Deepgram TTS
            isSpeaking = true
            try await ttsClient.speak(text: spokenText, apiKey: appSettings.deepgramAPIKey)
            isSpeaking = false
        } catch {
            isSpeaking = false
            logger.error("TTS failed: \(error.localizedDescription)")
            // Don't set self.error — TTS failure shouldn't block the UI
        }
    }
}
#endif
