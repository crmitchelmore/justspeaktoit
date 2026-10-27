#if os(iOS)
import Foundation
import SpeakCore

struct OpenClawOwnedSend {
    let token: UUID
    let generation: UUID
    let conversationID: String
    let sessionKey: String
    var runID: String?
    var receivedTerminal = false
}

struct OpenClawVoiceOwner {
    let token = UUID()
    let generation: UUID
    let conversationID: String?
    let sessionKey: String?
}

@MainActor
extension OpenClawChatCoordinator {
    public func sendTextMessage(_ text: String) async {
        await sendOwnedText(text)
    }

    func ownsVoice(_ owner: OpenClawVoiceOwner) -> Bool {
        owner.generation == conversationGeneration &&
            owner.conversationID == currentConversation?.id && owner.sessionKey == currentConversation?.sessionKey
    }

    func ownsSend(_ token: UUID) -> Bool {
        guard let owner = ownedSend, owner.token == token,
              owner.generation == conversationGeneration,
              currentConversation?.id == owner.conversationID,
              currentConversation?.sessionKey == owner.sessionKey,
              let stored = dependencies.conversation(owner.conversationID) else { return false }
        return stored.sessionKey == owner.sessionKey
    }

    func invalidateChatOperation(ifToken token: UUID? = nil) {
        if let token, ownedSend?.token != token { return }
        conversationGeneration = UUID()
        partialTranscript = ""
        ownedSend = nil
        let hadResponse = responseTask != nil || isSpeaking
        responseTask?.cancel()
        responseTask = nil
        if hadResponse { dependencies.stopSpeech(self) }
        currentRunId = nil
        isProcessing = false
        streamingResponse = ""
        accumulatedResponse = ""
        pendingAssistantResponses = []
        isBufferingForTTS = false
    }

    func sendOwnedText(_ text: String) async {
        // A cancelled queued caller must not retire a newer valid operation.
        guard !Task.isCancelled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        invalidateChatOperation()
        let conversation: OpenClawClient.Conversation
        if let currentConversation {
            conversation = currentConversation
        } else {
            conversation = dependencies.createConversation()
            currentConversation = conversation
        }
        let owner = OpenClawOwnedSend(
            token: UUID(), generation: conversationGeneration,
            conversationID: conversation.id, sessionKey: conversation.sessionKey
        )
        ownedSend = owner
        await withTaskCancellationHandler {
            do {
                try await waitForConnection()
                try Task.checkCancellation()
                guard ownsSend(owner.token) else { return }
                dependencies.addMessage(.init(role: "user", content: trimmed), owner.conversationID)
                currentConversation = dependencies.conversation(owner.conversationID)
                guard ownsSend(owner.token) else { return }
                isProcessing = true
                streamingResponse = ""
                accumulatedResponse = ""
                pendingAssistantResponses = []
                if dependencies.canSpeak(self) {
                    isBufferingForTTS = true
                    messageCountBeforeResponse = currentConversation?.messages.count ?? 0
                }
                dependencies.send(trimmed, owner.sessionKey) { [weak self] result in
                    self?.acceptAcknowledgment(result, owner: owner.token)
                }
            } catch is CancellationError {
                invalidateChatOperation(ifToken: owner.token)
            } catch {
                guard ownsSend(owner.token) else { return }
                ownedSend?.receivedTerminal = true
                self.error = error
                isProcessing = false
                isBufferingForTTS = false
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.invalidateChatOperation(ifToken: owner.token) }
        }
    }

    func acceptAcknowledgment(_ result: Result<String, Error>, owner token: UUID) {
        guard ownsSend(token), ownedSend?.receivedTerminal == false,
              ownedSend?.runID == nil else { return }
        switch result {
        case .success(let runID):
            ownedSend?.runID = runID
            currentRunId = runID
        case .failure(let error):
            ownedSend?.receivedTerminal = true
            self.error = error
            isProcessing = false
            isBufferingForTTS = false
        }
    }

    func ownerForEvent(_ runID: String) -> UUID? {
        guard let owner = ownedSend, owner.runID == runID,
              !owner.receivedTerminal, ownsSend(owner.token) else { return nil }
        return owner.token
    }

    func receiveDelta(runID: String, text: String) {
        guard let token = ownerForEvent(runID) else { return }
        let previous = accumulatedResponse
        if isNewAssistantSegment(text, comparedTo: previous) {
            persistAssistantMessageIfNeeded(previous, owner: token)
        }
        accumulatedResponse = text
        streamingResponse = text
    }

    func receiveFinal(runID: String, text: String) {
        guard let token = ownerForEvent(runID) else { return }
        ownedSend?.receivedTerminal = true
        let response = text.isEmpty ? accumulatedResponse : text
        currentRunId = nil
        isProcessing = false
        streamingResponse = ""
        accumulatedResponse = ""
        persistAssistantMessageIfNeeded(response, owner: token)
        let batch = pendingAssistantResponses
        pendingAssistantResponses = []
        dependencies.updateActivity(self)
        responseTask = Task { @MainActor [weak self] in
            guard let self, self.ownsSend(token), !Task.isCancelled else { return }
            defer {
                if self.ownedSend?.token == token { self.responseTask = nil }
            }
            if self.dependencies.canSpeak(self) {
                await self.dependencies.speak(self, batch, token)
            }
            guard self.ownsSend(token), !Task.isCancelled else { return }
            self.isBufferingForTTS = false
            await self.dependencies.resumeListening(self)
        }
    }

    func receiveError(runID: String, message: String) {
        guard let token = ownerForEvent(runID), ownsSend(token) else { return }
        ownedSend?.receivedTerminal = true
        currentRunId = nil
        error = OpenClawError.serverError(message)
        isProcessing = false
        streamingResponse = ""
        accumulatedResponse = ""
        pendingAssistantResponses = []
        isBufferingForTTS = false
    }

    func persistAssistantMessageIfNeeded(_ text: String, owner token: UUID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, ownsSend(token), let owner = ownedSend,
              let conversation = dependencies.conversation(owner.conversationID) else { return }
        if conversation.messages.last?.role == "assistant",
           conversation.messages.last?.content == trimmed { return }
        dependencies.addMessage(.init(role: "assistant", content: trimmed), owner.conversationID)
        currentConversation = dependencies.conversation(owner.conversationID)
        pendingAssistantResponses.append(trimmed)
    }
}
#endif
