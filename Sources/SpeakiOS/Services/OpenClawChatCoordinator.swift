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

    private let client = OpenClawClient()
    private let ttsClient = DeepgramTTSClient()
    private let summariser = VoiceSummariser()
    private let store = ConversationStore.shared
    private let settings = OpenClawSettings.shared
    private let appSettings = AppSettings.shared

    private var transcriber: TranscriberCoordinator?
    private var recordingMonitorTask: Task<Void, Never>?
    private var awaitingKeywordAcknowledge = false
    private var currentRunId: String?
    private var accumulatedResponse = ""
    private var settingsCancellables = Set<AnyCancellable>()
    private var headsetToggleTarget: Any?
    private var headsetPauseTarget: Any?

    private let logger = Logger(subsystem: "com.justspeaktoit.ios", category: "OpenClawChat")

    // MARK: - Init

    public init() {
        setupClientCallbacks()
        observeSettings()
        configureHeadsetCommandHandling(enabled: settings.headsetSingleTapAcknowledge)
    }

    deinit {
        unregisterHeadsetCommandHandlers()
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
        if triggeredByAcknowledgement || settings.keywordAcknowledgeEnabled {
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
            isSpeaking = false
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
                self.currentRunId = nil
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

                await self.maybeResumeConversationListening()
            }
        }

        client.onChatError = { [weak self] runId, errorMessage in
            Task { @MainActor in
                guard self?.currentRunId == runId else { return }
                self?.currentRunId = nil
                self?.error = OpenClawError.serverError(errorMessage)
                self?.isProcessing = false
            }
        }
    }

    private func ensureConversationReady() async throws -> OpenClawClient.Conversation {
        let conversation: OpenClawClient.Conversation
        if let currentConversation {
            conversation = currentConversation
        } else {
            let newConversation = store.createConversation()
            currentConversation = newConversation
            conversation = newConversation
        }

        try await waitForConnection()
        return conversation
    }

    private func waitForConnection() async throws {
        guard settings.isConfigured else { throw OpenClawError.notConnected }
        if case .connected = connectionState { return }

        if case .connecting = connectionState {
            // Existing connection attempt in progress.
        } else {
            connect()
        }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            switch connectionState {
            case .connected:
                return
            case .error(let message):
                throw OpenClawError.serverError(message)
            case .disconnected:
                connect()
            case .connecting:
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        throw OpenClawError.notConnected
    }

    private func maybeResumeConversationListening() async {
        guard settings.conversationModeEnabled, settings.autoResumeListening else { return }
        guard !isRecording, !isProcessing, !isSpeaking else { return }
        do {
            try await startVoiceInput()
        } catch {
            logger.error("Auto-resume recording failed: \(error.localizedDescription)")
        }
    }

    private func shouldTriggerKeywordAcknowledge(for transcript: String) -> Bool {
        guard settings.conversationModeEnabled,
              settings.keywordAcknowledgeEnabled,
              !awaitingKeywordAcknowledge else {
            return false
        }

        let keyword = settings.keywordAcknowledgePhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return false }

        let trailingCharacters = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let normalisedTranscript = transcript
            .trimmingCharacters(in: trailingCharacters)
            .lowercased()

        return normalisedTranscript.hasSuffix(keyword.lowercased())
    }

    private func removingAcknowledgementKeyword(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let keyword = settings.keywordAcknowledgePhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return trimmed }

        let pattern = "(?i)[\\s\\p{P}]*\(NSRegularExpression.escapedPattern(for: keyword))[\\s\\p{P}]*$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return trimmed
        }

        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        let withoutKeyword = regex.stringByReplacingMatches(in: trimmed, options: [], range: range, withTemplate: "")
        return withoutKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func observeSettings() {
        settings.$headsetSingleTapAcknowledge
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.configureHeadsetCommandHandling(enabled: enabled)
            }
            .store(in: &settingsCancellables)
    }

    private func configureHeadsetCommandHandling(enabled: Bool) {
        if enabled {
            registerHeadsetCommandHandlers()
        } else {
            unregisterHeadsetCommandHandlers()
        }
    }

    private func registerHeadsetCommandHandlers() {
        guard headsetToggleTarget == nil, headsetPauseTarget == nil else { return }

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true

        headsetToggleTarget = commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                await self?.handleAcknowledgeSignal()
            }
            return .success
        }

        headsetPauseTarget = commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                await self?.handleAcknowledgeSignal()
            }
            return .success
        }
    }

    private func unregisterHeadsetCommandHandlers() {
        let commandCenter = MPRemoteCommandCenter.shared()

        if let headsetToggleTarget {
            commandCenter.togglePlayPauseCommand.removeTarget(headsetToggleTarget)
            self.headsetToggleTarget = nil
        }

        if let headsetPauseTarget {
            commandCenter.pauseCommand.removeTarget(headsetPauseTarget)
            self.headsetPauseTarget = nil
        }

        commandCenter.togglePlayPauseCommand.isEnabled = false
        commandCenter.pauseCommand.isEnabled = false
    }

    private func summariseAndSpeak(_ text: String) async {
        do {
            var spokenText = text

            // Summarise if enabled and latency mode is not prioritised.
            if settings.summariseResponses && !settings.lowLatencySpeech && appSettings.hasOpenRouterKey {
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
