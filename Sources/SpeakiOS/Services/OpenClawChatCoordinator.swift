#if os(iOS)
import Combine
import Foundation
import MediaPlayer
import SpeakCore
import SwiftUI
import os.log

private let storeLogger = SpeakLogger.logger(category: "ConversationStore")

// MARK: - Conversation Persistence

/// Manages persisting OpenClaw conversations to disk.
@MainActor
public final class ConversationStore: ObservableObject {
    public static let shared = ConversationStore()

    @Published public private(set) var isLoaded = false
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
        defer { isLoaded = true }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            conversations = try decoder.decode([OpenClawClient.Conversation].self, from: data)
        } catch {
            storeLogger.error("Failed to load: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        do {
            let data = try encoder.encode(conversations)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            storeLogger.error("Failed to save: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - OpenClaw Chat Coordinator

/// Coordinates the voice→text→gateway→summarise→TTS pipeline.
@MainActor
public final class OpenClawChatCoordinator: ObservableObject {
    // MARK: - Published State

    @Published public var connectionState: OpenClawClient.ConnectionState = .disconnected
    @Published public var currentConversation: OpenClawClient.Conversation? {
        didSet {
            if oldValue?.id != currentConversation?.id || oldValue?.sessionKey != currentConversation?.sessionKey {
                invalidateChatOperation()
            }
        }
    }
    @Published public var isRecording = false
    @Published public var isProcessing = false
    @Published public var isSpeaking = false
    @Published public var partialTranscript = ""
    @Published public var streamingResponse = ""
    @Published public var isBufferingForTTS = false
    @Published public var error: Error?

    // MARK: - Dependencies

    let dependencies: OpenClawChatDependencies
    // Public construction eagerly initializes these as before. The internal chat
    // fixture initializer never acquires unrelated platform or singleton effects.
    lazy var ttsClient = VoiceOutputRouter()
    lazy var summariser = VoiceSummariser()
    lazy var settings = OpenClawSettings.shared
    lazy var appSettings = AppSettings.shared

    private var transcriber: (any OpenClawVoiceCapture)?
    private var voiceOwner: OpenClawVoiceOwner?
    var recordingMonitorTask: Task<Void, Never>?
    private(set) var awaitingKeywordAcknowledge = false
    var currentRunId: String?
    var conversationGeneration = UUID()
    var connectionEpoch = UUID()
    var ownedSend: OpenClawOwnedSend?
    var responseTask: Task<Void, Never>?
    var accumulatedResponse = ""
    var pendingAssistantResponses: [String] = []
    var messageCountBeforeResponse = 0
    var settingsCancellables = Set<AnyCancellable>()
    var headsetToggleTarget: Any?
    var headsetPauseTarget: Any?
    var cachedKeywordRegex: (keyword: String, regex: NSRegularExpression)?

    let logger = SpeakLogger.logger(category: "OpenClawChat")

    /// Manages the Live Activity for OpenClaw recording sessions.
    lazy var openClawActivityManager = OpenClawActivityManager()

    // MARK: - Init

    public init() {
        self.dependencies = .live()
        _ = self.ttsClient
        _ = self.summariser
        _ = self.settings
        _ = self.appSettings
        _ = self.openClawActivityManager
        setupClientCallbacks()
        observeSettings()
        ttsClient.$isSpeaking
            .sink { [weak self] speaking in
                self?.isSpeaking = speaking
                if speaking {
                    self?.isBufferingForTTS = false
                }
            }
            .store(in: &settingsCancellables)
        observeLiveActivityStateChanges()
        configureHeadsetCommandHandling(enabled: settings.headsetSingleTapAcknowledge)
    }

    init(dependencies: OpenClawChatDependencies) {
        self.dependencies = dependencies
        setupClientCallbacks()
    }

    // MARK: - Connection

    public func connect() {
        guard dependencies.isConfigured() else {
            error = OpenClawError.notConnected
            return
        }

        connectionEpoch = UUID()
        setupClientCallbacks()
        connectionState = .connecting
        dependencies.connect(currentConversation?.sessionKey)
    }

    public func disconnect() {
        invalidateChatOperation()
        connectionEpoch = UUID()
        setupClientCallbacks()
        connectionState = .disconnected
        dependencies.disconnect()
    }

    /// Stops recording, TTS playback, and disconnects.
    /// Called when the user navigates away from the chat view.
    public func stopAllAndDisconnect() {
        if isRecording {
            cancelVoiceInput()
        }
        dependencies.stopSpeech(self)
        isBufferingForTTS = false
        dependencies.endActivity(self)
        disconnect()
    }

    // MARK: - Conversation Management

    public func startNewConversation() {
        let conv = dependencies.createConversation()
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
        try Task.checkCancellation()
        guard !isRecording, !isProcessing, !isSpeaking else { return }
        let owner = OpenClawVoiceOwner(
            generation: conversationGeneration,
            conversationID: currentConversation?.id, sessionKey: currentConversation?.sessionKey
        )
        let coordinator = dependencies.makeVoiceCapture()
        self.transcriber = coordinator
        voiceOwner = owner
        isRecording = true
        partialTranscript = ""
        awaitingKeywordAcknowledge = false

        do {
            try await coordinator.startCapture()
            try Task.checkCancellation()
            guard transcriber === coordinator, voiceOwner?.token == owner.token, ownsVoice(owner) else {
                throw CancellationError()
            }
        } catch {
            coordinator.cancelCapture()
            if transcriber === coordinator {
                transcriber = nil
                voiceOwner = nil
                isRecording = false
            }
            throw error
        }

        recordingMonitorTask?.cancel()
        recordingMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.isRecording {
                guard self.transcriber === coordinator, self.voiceOwner?.token == owner.token,
                      self.ownsVoice(owner) else { return }
                let liveText = coordinator.partialText
                self.partialTranscript = liveText

                if self.shouldTriggerKeywordAcknowledge(for: liveText) {
                    self.awaitingKeywordAcknowledge = true
                    // This monitor is finishing normally, not cancelling its own Stop.
                    self.recordingMonitorTask = nil
                    await self.stopVoiceInputAndSend(triggeredByAcknowledgement: true)
                    return
                }

                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }

    /// Stop recording and send the transcribed text to OpenClaw.
    public func stopVoiceInputAndSend(triggeredByAcknowledgement: Bool = false) async {
        guard !Task.isCancelled else { return }
        guard isRecording, let coordinator = transcriber, let owner = voiceOwner else { return }

        recordingMonitorTask?.cancel()
        recordingMonitorTask = nil
        awaitingKeywordAcknowledge = false

        let result = await coordinator.stopCapture()
        guard transcriber === coordinator, voiceOwner?.token == owner.token else { return }
        isRecording = false
        transcriber = nil
        voiceOwner = nil
        guard ownsVoice(owner), !Task.isCancelled else { return }

        var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if dependencies.conversationPolicy().keywordAcknowledgeEnabled {
            text = removingAcknowledgementKeyword(from: text)
        }
        guard !text.isEmpty else {
            await dependencies.resumeListening(self)
            return
        }

        partialTranscript = ""
        await sendTextMessage(text)
    }

    /// Cancel voice input without sending.
    public func cancelVoiceInput() {
        invalidateChatOperation()
        recordingMonitorTask?.cancel()
        recordingMonitorTask = nil
        awaitingKeywordAcknowledge = false
        transcriber?.cancelCapture()
        transcriber = nil
        voiceOwner = nil
        isRecording = false
        partialTranscript = ""
    }

    public func conversationModeChanged(isEnabled: Bool) async {
        if isEnabled {
            await dependencies.resumeListening(self)
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
            invalidateChatOperation()
            dependencies.stopSpeech(self)
            await dependencies.resumeListening(self)
            return
        }

        await dependencies.resumeListening(self)
    }

}
#endif
