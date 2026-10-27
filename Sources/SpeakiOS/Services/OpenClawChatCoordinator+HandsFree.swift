#if os(iOS)
import Combine
import Foundation
import MediaPlayer
import SpeakCore

extension OpenClawChatCoordinator {
    // MARK: - Private

    func setupClientCallbacks() {
        let epoch = connectionEpoch
        dependencies.installCallbacks(.init(
            connection: { [weak self] state in self?.receiveConnectionState(state, epoch: epoch) },
            delta: { [weak self] runID, text in self?.receiveDelta(runID: runID, text: text) },
            final: { [weak self] runID, text in self?.receiveFinal(runID: runID, text: text) },
            error: { [weak self] runID, message in self?.receiveError(runID: runID, message: message) }
        ))
    }

    func receiveConnectionState(_ state: OpenClawClient.ConnectionState, epoch: UUID) {
        guard epoch == connectionEpoch else { return }
        connectionState = state
        switch state {
        case .disconnected:
            invalidateChatOperation()
        case .error(let message):
            let hadOperation = ownedSend != nil || isRecording
            invalidateChatOperation()
            if hadOperation { error = OpenClawError.serverError(message) }
        case .connecting, .connected:
            break
        }
    }

    var hasSelectedVoiceOutputKey: Bool {
        switch settings.ttsProvider {
        case .deepgram: appSettings.hasDeepgramKey
        case .soniox: appSettings.hasSonioxKey
        case .openrouter: appSettings.hasOpenRouterKey
        }
    }

    func waitForConnection() async throws {
        try Task.checkCancellation()
        if let wait = dependencies.waitForConnection {
            try await wait()
            return
        }
        guard dependencies.isConfigured() else { throw OpenClawError.notConnected }
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
            try Task.checkCancellation()
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
            try await Task.sleep(for: .milliseconds(50))
        }

        throw OpenClawError.notConnected
    }

    func maybeResumeConversationListening() async {
        let policy = dependencies.conversationPolicy()
        guard policy.conversationModeEnabled, policy.autoResumeListening else { return }
        guard !isRecording, !isProcessing, !isSpeaking else { return }
        do {
            try await startVoiceInput()
            updateLiveActivityState()
        } catch {
            logger.error("Auto-resume recording failed: \(error.localizedDescription)")
        }
    }

    func isNewAssistantSegment(_ incoming: String, comparedTo previous: String) -> Bool {
        guard !previous.isEmpty, !incoming.isEmpty else { return false }

        if incoming.hasPrefix(previous) {
            return false
        }
        if previous.hasPrefix(incoming) {
            return incoming.count < previous.count
        }

        return true
    }

    func shouldTriggerKeywordAcknowledge(for transcript: String) -> Bool {
        let policy = dependencies.conversationPolicy()
        guard policy.conversationModeEnabled,
              policy.keywordAcknowledgeEnabled,
              !awaitingKeywordAcknowledge else {
            return false
        }

        let keyword = dependencies.conversationPolicy().keywordAcknowledgePhrase
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

        let keyword = dependencies.conversationPolicy().keywordAcknowledgePhrase
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return trimmed }

        let regex: NSRegularExpression
        if let cached = cachedKeywordRegex, cached.keyword == keyword {
            regex = cached.regex
        } else {
            let pattern = "(?i)[\\s\\p{P}]*\(NSRegularExpression.escapedPattern(for: keyword))[\\s\\p{P}]*$"
            guard let compiled = try? NSRegularExpression(pattern: pattern) else {
                return trimmed
            }
            cachedKeywordRegex = (keyword: keyword, regex: compiled)
            regex = compiled
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
        guard headsetPauseTarget == nil else { return }

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.pauseCommand.isEnabled = true

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

    func speakAssistantResponses(_ responses: [String], owner token: UUID) async {
        guard ownsSend(token), !Task.isCancelled else { return }
        let nonEmpty = responses.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return }

        if nonEmpty.count > 1,
           settings.summariseResponses,
           !settings.lowLatencySpeech,
           appSettings.hasOpenRouterKey {
            await summariseAndSpeak(nonEmpty.joined(separator: "\n\n"), allowSummary: true, owner: token)
            return
        }

        if nonEmpty.count == 1 {
            await summariseAndSpeak(nonEmpty[0], owner: token)
            return
        }

        for response in nonEmpty {
            guard ownsSend(token), !Task.isCancelled else { return }
            await summariseAndSpeak(response, allowSummary: false, owner: token)
        }
    }

    func summariseAndSpeak(_ text: String, allowSummary: Bool = true, owner token: UUID) async {
        guard ownsSend(token), !Task.isCancelled else { return }
        do {
            var spokenText = text

            // Summarise if enabled and latency mode is not prioritised.
            if allowSummary &&
                settings.summariseResponses &&
                !settings.lowLatencySpeech &&
                appSettings.hasOpenRouterKey {
                do {
                    spokenText = try await summariser.summarise(
                        text,
                        apiKey: appSettings.openRouterAPIKey
                    )
                    logger.info("Summarised response (\(text.count)→\(spokenText.count) chars)")
                } catch is CancellationError {
                    return
                } catch {
                    guard ownsSend(token), !Task.isCancelled else { return }
                    // Summarisation failed — fall back to speaking the original text
                    logger.warning("Summarisation failed, speaking raw: \(error.localizedDescription)")
                    spokenText = text
                }
            }

            guard ownsSend(token), !Task.isCancelled else { return }
            try await ttsClient.speak(
                text: spokenText,
                provider: settings.ttsProvider,
                model: settings.ttsModel,
                voice: settings.ttsVoice,
                lastKnownVoiceName: settings.ttsVoiceName,
                speed: settings.ttsSpeed,
                languageIdentifier: settings.ttsLanguageIdentifier,
                sonioxRegion: settings.sonioxRegion,
                deepgramAPIKey: appSettings.deepgramAPIKey,
                sonioxAPIKey: appSettings.sonioxAPIKey,
                openRouterAPIKey: appSettings.openRouterAPIKey
            )
        } catch {
            guard ownsSend(token), !Task.isCancelled else { return }
            logger.error("TTS failed: \(error.localizedDescription)")
            if settings.ttsProvider == .openrouter, !(error is CancellationError) {
                self.error = error
            }
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
