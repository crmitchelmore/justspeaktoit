import SpeakCore

/// The Mac's WhisperKit live identifiers. The derivation is shared with the
/// desktop hosts' whisper.cpp live models through `LocalModelIdentity`.
enum WhisperKitStreamingModel {
    static let prefix = LocalModelIdentity.whisperLivePrefix

    static func id(for model: LocalTranscriptionModel) -> String {
        id(forBatchModelID: model.id)
    }

    static func id(forBatchModelID modelID: String) -> String {
        LocalModelIdentity.whisperLiveModelID(forBatchModelID: modelID)
    }

    static func batchModelID(from streamingID: String) -> String? {
        LocalModelIdentity.whisperBatchModelID(fromLiveModelID: streamingID)
    }

    static func matches(_ modelID: String) -> Bool {
        batchModelID(from: modelID) != nil
    }
}
