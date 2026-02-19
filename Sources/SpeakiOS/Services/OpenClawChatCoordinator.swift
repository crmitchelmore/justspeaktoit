#if os(iOS)
import Combine
import Foundation
import MediaPlayer
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

    let client = OpenClawClient()
    let ttsClient = DeepgramTTSClient()
    let summariser = VoiceSummariser()
    let store = ConversationStore.shared
    let settings = OpenClawSettings.shared
    let appSettings = AppSettings.shared

    private var transcriber: TranscriberCoordinator?
    private var recordingMonitorTask: Task<Void, Never>?
    private(set) var awaitingKeywordAcknowledge = false
    var currentRunId: String?
    var accumulatedResponse = ""
    var pendingAssistantResponses: [String] = []
    var settingsCancellables = Set<AnyCancellable>()
    var headsetToggleTarget: Any?
    var headsetPauseTarget: Any?

    let logger = Logger(subsystem: "com.justspeaktoit.ios", category: "OpenClawChat")

    /// Manages the Live Activity for OpenClaw recording sessions.
    let openClawActivityManager = OpenClawActivityManager()

    // MARK: - Init

    public init() {
        setupClientCallbacks()
        observeSettings()
        ttsClient.$isSpeaking
            .sink { [weak self] speaking in
                self?.isSpeaking = speaking
            }
            .store(in: &settingsCancellables)
        observeLiveActivityStateChanges()
        configureHeadsetCommandHandling(enabled: settings.headsetSingleTapAcknowledge)
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

    /// Stops recording, TTS playback, and disconnects.
    /// Called when the user navigates away from the chat view.
    public func stopAllAndDisconnect() {
        if isRecording {
            cancelVoiceInput()
        }
        ttsClient.stop()
        openClawActivityManager.endActivity()
        disconnect()
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

    // MARK: - Live Activity

    /// Starts a Live Activity when the app moves to the background while in a conversation.
    public func startLiveActivityIfNeeded() {
        guard currentConversation != nil else { return }
        let title = currentConversation?.title ?? "OpenClaw"
        let count = currentConversation?.messages.count ?? 0

        let status = currentLiveActivityStatus

        openClawActivityManager.startActivity(title: title, messageCount: count)

        if status != .recording {
            openClawActivityManager.updateActivity(
                status: status,
                title: title,
                messageCount: count
            )
        }
    }

    /// Computed property for current Live Activity status based on coordinator state.
    var currentLiveActivityStatus: OpenClawActivityAttributes.ConversationStatus {
        if isRecording {
            return .recording
        } else if isProcessing {
            return .processing
        } else if isSpeaking {
            return .speaking
        }
        return .idle
    }

    /// Ends the Live Activity (for example when the app becomes active again).
    public func endLiveActivity() {
        openClawActivityManager.endActivity()
    }

    // MARK: - Voice Input

    /// Start recording voice input using the app's configured transcription provider.
    public func startVoiceInput() async throws {
        guard !isRecording, !isProcessing, !isSpeaking else { return }

        let coordinator = TranscriberCoordinator()
        self.transcriber = coordinator
        isRecording = true
        partialTranscript = ""
        awaitingKeywordAcknowledge = false

        try await coordinator.start()

        recordingMonitorTask?.cancel()
        recordingMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.isRecording, let activeTranscriber = self.transcriber {
                let liveText = activeTranscriber.partialText
                self.partialTranscript = liveText

                if self.shouldTriggerKeywordAcknowledge(for: liveText) {
                    self.awaitingKeywordAcknowledge = true
                    await self.stopVoiceInputAndSend(triggeredByAcknowledgement: true)
                    return
                }

                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }

    /// Stop recording and send the transcribed text to OpenClaw.
    public func stopVoiceInputAndSend(triggeredByAcknowledgement: Bool = false) async {
        guard isRecording, let coordinator = transcriber else { return }

        recordingMonitorTask?.cancel()
        recordingMonitorTask = nil
        awaitingKeywordAcknowledge = false

        let result = await coordinator.stop()
        isRecording = false
        transcriber = nil

        var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.keywordAcknowledgeEnabled {
            text = removingAcknowledgementKeyword(from: text)
        }
        guard !text.isEmpty else {
            await maybeResumeConversationListening()
            return
        }

        partialTranscript = ""
        await sendTextMessage(text)
    }

    /// Cancel voice input without sending.
    public func cancelVoiceInput() {
        recordingMonitorTask?.cancel()
        recordingMonitorTask = nil
        awaitingKeywordAcknowledge = false
        transcriber?.cancel()
        transcriber = nil
        isRecording = false
        partialTranscript = ""
    }

    public func conversationModeChanged(isEnabled: Bool) async {
        if isEnabled {
            await maybeResumeConversationListening()
            return
        }

        if isRecording {
            cancelVoiceInput()
        }
    }

    public func handleAcknowledgeSignal() async {
        if isRecording {
            await stopVoiceInputAndSend(triggeredByAcknowledgement: true)
            return
        }

        if isSpeaking {
            ttsClient.stop()
            await maybeResumeConversationListening()
            return
        }

        await maybeResumeConversationListening()
    }

    // MARK: - Text Sending

    public func sendTextMessage(_ text: String) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        do {
            let conv = try await ensureConversationReady()

            // Add user message
            let userMessage = OpenClawClient.ChatMessage(role: "user", content: trimmedText)
            store.addMessage(userMessage, to: conv.id)
            currentConversation = store.conversations.first { $0.id == conv.id }

            isProcessing = true
            streamingResponse = ""
            accumulatedResponse = ""
            pendingAssistantResponses = []

            client.sendMessage(trimmedText, sessionKey: conv.sessionKey) { [weak self] result in
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
        } catch {
            self.error = error
            self.isProcessing = false
            self.logger.error("Connection failed: \(error.localizedDescription)")
        }
    }

}
#endif
