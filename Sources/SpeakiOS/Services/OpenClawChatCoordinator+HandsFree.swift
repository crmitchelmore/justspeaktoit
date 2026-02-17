#if os(iOS)
import Combine
import Foundation
import MediaPlayer
import SpeakCore

extension OpenClawChatCoordinator {
    // MARK: - Private

    func setupClientCallbacks() {
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

    func ensureConversationReady() async throws -> OpenClawClient.Conversation {
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

    func waitForConnection() async throws {
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

    func maybeResumeConversationListening() async {
        guard settings.conversationModeEnabled, settings.autoResumeListening else { return }
        guard !isRecording, !isProcessing, !isSpeaking else { return }
        do {
            try await startVoiceInput()
        } catch {
            logger.error("Auto-resume recording failed: \(error.localizedDescription)")
        }
    }

    func shouldTriggerKeywordAcknowledge(for transcript: String) -> Bool {
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

    func removingAcknowledgementKeyword(from text: String) -> String {
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

    func observeSettings() {
        settings.$headsetSingleTapAcknowledge
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.configureHeadsetCommandHandling(enabled: enabled)
            }
            .store(in: &settingsCancellables)
    }

    func configureHeadsetCommandHandling(enabled: Bool) {
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

    func unregisterHeadsetCommandHandlers() {
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

    func summariseAndSpeak(_ text: String) async {
        do {
            var spokenText = text

            // Summarise if enabled and latency mode is not prioritised.
            if settings.summariseResponses &&
                !settings.lowLatencySpeech &&
                appSettings.hasOpenRouterKey {
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
