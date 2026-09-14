import Foundation
import SpeakCore

/// The bring-your-own-key client that ``PaidAccessProxyClient`` wraps.
///
/// Named as a capability rather than as a vendor: the proxy needs something that
/// can do the work with the user's own credentials, and nothing about it should
/// depend on that thing being OpenRouter. `OpenRouterAPIClient` is the only
/// production conformer, and stating the requirement as a protocol is what lets
/// the fallback paths be tested — they are the paths that matter most, since
/// they run whenever paid routing fails and are what keeps a failure from
/// costing the user their dictation.
///
/// Internal to SpeakApp: this is a seam, not a published API.
protocol PaidAccessFallbackClient: StreamingChatLLMClient, BatchTranscriptionClient, Sendable {
    /// Whether serving `model` needs a remote call at all — a local model does not.
    func requiresRemoteAccess(for model: String) async -> Bool

    /// Whether the user has supplied their own credentials for that remote call.
    func hasStoredAPIKey() async -> Bool
}

extension OpenRouterAPIClient: PaidAccessFallbackClient {}
