import Foundation

/// Version-pinned Voxtral 3 public-preview models (20 October 2026).
/// Keep existing Voxtral 2 selections: adding a model must not change a saved route.
/// Contracts: https://docs.mistral.ai/studio/audio/migrate-from-voxtral-2
public enum MistralVoxtral3 {
    public static let miniBatchID = "mistral/voxtral-mini-transcribe-3-0"
    public static let smallBatchID = "mistral/voxtral-small-transcribe-3-0"
    public static let realtimeAPIModelID = "voxtral-mini-transcribe-realtime-3-0"
    public static let realtimeID = "mistral/" + realtimeAPIModelID + "-streaming"

    /// Batch models supported by the existing file transcription endpoint.
    public static let batchIDs = [miniBatchID, smallBatchID]
}
