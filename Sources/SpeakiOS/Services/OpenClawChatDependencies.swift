#if os(iOS)
import Foundation
import SpeakCore

@MainActor
protocol OpenClawVoiceCapture: AnyObject {
    var partialText: String { get }
    func startCapture() async throws
    func stopCapture() async -> TranscriptionResult
    func cancelCapture()
}

extension TranscriberCoordinator: OpenClawVoiceCapture {
    func startCapture() async throws { try await start() }
    func stopCapture() async -> TranscriptionResult { await stop() }
    func cancelCapture() { cancel() }
}

struct OpenClawConversationPolicy {
    var conversationModeEnabled = false
    var autoResumeListening = false
    var keywordAcknowledgeEnabled = false
    var keywordAcknowledgePhrase = ""
}

/// Only the existing chat operations. Injected construction has no platform observers,
/// personal store, gateway, credentials or speech output unless explicitly supplied.
@MainActor
struct OpenClawChatDependencies {
    typealias Acknowledgment = @MainActor @Sendable (Result<String, Error>) -> Void
    struct Callbacks: Sendable {
        let connection: @MainActor @Sendable (OpenClawClient.ConnectionState) -> Void
        let delta: @MainActor @Sendable (String, String) -> Void
        let final: @MainActor @Sendable (String, String) -> Void
        let error: @MainActor @Sendable (String, String) -> Void
    }

    var installCallbacks: (Callbacks) -> Void
    var isConfigured: () -> Bool
    var connect: (String?) -> Void
    var disconnect: () -> Void
    var send: (String, String, @escaping Acknowledgment) -> Void
    var createConversation: () -> OpenClawClient.Conversation
    var conversation: (String) -> OpenClawClient.Conversation?
    var addMessage: (OpenClawClient.ChatMessage, String) -> Void
    var makeVoiceCapture: () -> any OpenClawVoiceCapture
    var waitForConnection: (() async throws -> Void)?
    var conversationPolicy: () -> OpenClawConversationPolicy = { .init() }
    var canSpeak: (OpenClawChatCoordinator) -> Bool = { _ in false }
    var speak: (OpenClawChatCoordinator, [String], UUID) async -> Void = { _, _, _ in }
    var stopSpeech: (OpenClawChatCoordinator) -> Void = { _ in }
    var resumeListening: (OpenClawChatCoordinator) async -> Void = { _ in }
    var updateActivity: (OpenClawChatCoordinator) -> Void = { _ in }
    var endActivity: (OpenClawChatCoordinator) -> Void = { _ in }

    private static func installLiveCallbacks(_ client: OpenClawClient, callbacks: Callbacks) {
        client.onConnectionStateChanged = { state in
            Task { @MainActor in callbacks.connection(state) }
        }
        client.onChatDelta = { runID, text in
            Task { @MainActor in callbacks.delta(runID, text) }
        }
        client.onChatFinal = { runID, text in
            Task { @MainActor in callbacks.final(runID, text) }
        }
        client.onChatError = { runID, message in
            Task { @MainActor in callbacks.error(runID, message) }
        }
    }

    static func live() -> Self {
        let client = OpenClawClient()
        let store = ConversationStore.shared
        let settings = OpenClawSettings.shared
        return Self(
            installCallbacks: { installLiveCallbacks(client, callbacks: $0) },
            isConfigured: { settings.isConfigured },
            connect: { sessionKey in
                client.connect(config: OpenClawClient.ConnectConfig(
                    gatewayURL: settings.gatewayURL, token: settings.token,
                    clientName: "speak-ios", sessionKey: sessionKey ?? "speak-ios:voice"
                ))
            },
            disconnect: { client.disconnect() },
            send: { text, sessionKey, completion in
                client.sendMessage(text, sessionKey: sessionKey) { result in
                    Task { @MainActor in completion(result) }
                }
            },
            createConversation: { store.createConversation() },
            conversation: { id in store.conversations.first { $0.id == id } },
            addMessage: { message, id in store.addMessage(message, to: id) },
            makeVoiceCapture: {
                TranscriberCoordinator(
                    networkSnapshot: CaptureNetworkPathMonitor.liveSnapshotProvider(),
                    localRecognitionCapability: AppleLegacyRecognitionCapabilityProbe.capability(for:)
                )
            },
            waitForConnection: nil,
            conversationPolicy: {
                OpenClawConversationPolicy(
                    conversationModeEnabled: settings.conversationModeEnabled,
                    autoResumeListening: settings.autoResumeListening,
                    keywordAcknowledgeEnabled: settings.keywordAcknowledgeEnabled,
                    keywordAcknowledgePhrase: settings.keywordAcknowledgePhrase
                )
            },
            canSpeak: { owner in owner.settings.ttsEnabled && owner.hasSelectedVoiceOutputKey },
            speak: { owner, responses, token in await owner.speakAssistantResponses(responses, owner: token) },
            stopSpeech: { $0.ttsClient.stop() },
            resumeListening: { await $0.maybeResumeConversationListening() },
            updateActivity: { $0.updateLiveActivityState() },
            endActivity: { $0.openClawActivityManager.endActivity() }
        )
    }
}
#endif
