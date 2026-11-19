import Foundation

/// Canonical xAI Voice model identifiers shared by the catalogue, routing,
/// platform settings, and the realtime client.
public enum XAIVoiceModels {
    /// Grok Voice 3.0, xAI's current speech-to-speech model. Same endpoint,
    /// session parameters, events and price as 2.0 (docs.x.ai release notes,
    /// October 2026; checked 2026-11-11).
    public static let voice3CatalogID = "xai/grok-voice-3.0-streaming"
    public static let voice3APIName = "grok-voice-3.0"
    /// Retired Grok Voice 2.0 route, kept only so saved selections migrate to
    /// `voice3CatalogID`; xAI deprecated the 2.0 generation in October 2026.
    public static let thinkFast2CatalogID = "xai/grok-voice-think-fast-2.0-streaming"
    public static let thinkFast2APIName = "grok-voice-think-fast-2.0"
    public static let inputTranscriptionAPIName = "grok-transcribe"
}
