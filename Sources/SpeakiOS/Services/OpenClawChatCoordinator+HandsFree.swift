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
                guard let self, self.currentRunId == runId else { return }
                let previous = self.accumulatedResponse

                if self.isNewAssistantSegment(delta, comparedTo: previous) {
                    self.persistAssistantMessageIfNeeded(previous)
                }

                self.accumulatedResponse = delta
                self.streamingResponse = delta
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
                self.persistAssistantMessageIfNeeded(responseText)
                let responseBatch = self.pendingAssistantResponses
                self.pendingAssistantResponses = []

                // Update Live Activity status
                self.updateLiveActivityState()

                // Summarise and speak if enabled
                if self.settings.ttsEnabled && self.appSettings.hasDeepgramKey {
                    await self.speakAssistantResponses(responseBatch)
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
                self?.streamingResponse = ""
                self?.accumulatedResponse = ""
                self?.pendingAssistantResponses = []
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

        var didInitiateConnect = false
        if case .connecting = connectionState {
            // Existing connection attempt in progress.
        } else {
            connect()
            didInitiateConnect = true
        }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            switch connectionState {
            case .connected:
                return
            case .error(let message):
                throw OpenClawError.serverError(message)
            case .disconnected:
                if !didInitiateConnect {
                    connect()
                    didInitiateConnect = true
                }
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
            updateLiveActivityState()
        } catch {
            logger.error("Auto-resume recording failed: \(error.localizedDescription)")
        }
    }

    private func isNewAssistantSegment(_ incoming: String, comparedTo previous: String) -> Bool {
        guard !previous.isEmpty, !incoming.isEmpty else { return false }

        if incoming.hasPrefix(previous) {
            return false
        }
        if previous.hasPrefix(incoming) {
            return incoming.count < previous.count
        }

        return true
    }

    private func persistAssistantMessageIfNeeded(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let conv = currentConversation else { return }

        if let existingConversation = store.conversations.first(where: { $0.id == conv.id }),
           existingConversation.messages.last?.role == "assistant",
           existingConversation.messages.last?.content == trimmed {
            return
        }

        let assistantMessage = OpenClawClient.ChatMessage(role: "assistant", content: trimmed)
        store.addMessage(assistantMessage, to: conv.id)
        currentConversation = store.conversations.first { $0.id == conv.id }
        pendingAssistantResponses.append(trimmed)
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

        let lowerKeyword = keyword.lowercased()
        guard normalisedTranscript.hasSuffix(lowerKeyword) else { return false }

        let prefixEnd = normalisedTranscript.index(
            normalisedTranscript.endIndex,
            offsetBy: -lowerKeyword.count
        )
        if prefixEnd == normalisedTranscript.startIndex { return true }

        let charBefore = normalisedTranscript[normalisedTranscript.index(before: prefixEnd)]
        return charBefore.isWhitespace || charBefore.isPunctuation
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

    private func speakAssistantResponses(_ responses: [String]) async {
        let nonEmpty = responses.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return }

        if nonEmpty.count > 1,
           settings.summariseResponses,
           !settings.lowLatencySpeech,
           appSettings.hasOpenRouterKey {
            await summariseAndSpeak(nonEmpty.joined(separator: "\n\n"), allowSummary: true)
            return
        }

        if nonEmpty.count == 1 {
            await summariseAndSpeak(nonEmpty[0])
            return
        }

        for response in nonEmpty {
            await summariseAndSpeak(response, allowSummary: false)
        }
    }

    func summariseAndSpeak(_ text: String, allowSummary: Bool = true) async {
        do {
            var spokenText = text

            // Summarise if enabled and latency mode is not prioritised.
            if allowSummary &&
                settings.summariseResponses &&
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
            try await ttsClient.speak(text: spokenText, apiKey: appSettings.deepgramAPIKey)
        } catch {
            logger.error("TTS failed: \(error.localizedDescription)")
            // Don't set self.error — TTS failure shouldn't block the UI
        }
    }

    // MARK: - Live Activity Helpers

    /// Observes `isSpeaking` and `isProcessing` changes to keep the Live Activity current.
    func observeLiveActivityStateChanges() {
        $isSpeaking
            .removeDuplicates()
            .sink { [weak self] _ in self?.updateLiveActivityState() }
            .store(in: &settingsCancellables)

        $isProcessing
            .removeDuplicates()
            .sink { [weak self] _ in self?.updateLiveActivityState() }
            .store(in: &settingsCancellables)

        $isRecording
            .removeDuplicates()
            .sink { [weak self] _ in self?.updateLiveActivityState() }
            .store(in: &settingsCancellables)
    }

    /// Updates the Live Activity with the current coordinator state, if one is running.
    func updateLiveActivityState() {
        guard openClawActivityManager.isActivityRunning else { return }
        let title = currentConversation?.title ?? "OpenClaw"
        let count = currentConversation?.messages.count ?? 0
        let status = currentLiveActivityStatus

        openClawActivityManager.updateActivity(
            status: status,
            title: title,
            messageCount: count
        )
    }
}
#endif
