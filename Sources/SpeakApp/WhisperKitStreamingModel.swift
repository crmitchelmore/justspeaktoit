import SpeakCore

enum WhisperKitStreamingModel {
    static let prefix = "local/streaming/whisperkit/"
    private static let batchPrefix = "local/whisperkit/"

    static func id(for model: LocalTranscriptionModel) -> String {
        id(forBatchModelID: model.id)
    }

    static func id(forBatchModelID modelID: String) -> String {
        guard modelID.hasPrefix(batchPrefix) else { return prefix + modelID }
        return prefix + modelID.dropFirst(batchPrefix.count)
    }

    static func batchModelID(from streamingID: String) -> String? {
        guard streamingID.hasPrefix(prefix) else { return nil }
        return batchPrefix + streamingID.dropFirst(prefix.count)
    }

    static func matches(_ modelID: String) -> Bool {
        batchModelID(from: modelID) != nil
    }
}
