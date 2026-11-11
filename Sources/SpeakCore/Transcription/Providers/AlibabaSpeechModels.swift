import Foundation

public enum AlibabaSpeechModels {
    public static let funFlash = "alibaba/fun-asr-flash-2026-06-15"
    public static let funLive = "alibaba/fun-asr-realtime-streaming"
    public static let qwen35 = "alibaba/qwen3.5-omni-plus"
    public static let qwen38 = "alibaba/qwen3.8-omni-flash"
    public static let batchIDs: Set<String> = [funFlash, qwen35, qwen38]
    public static let allIDs = batchIDs.union([funLive])

    public static let liveOptions: [ModelCatalog.Option] = [
        .init(id: funLive, displayName: "Alibaba Fun-ASR (Streaming)",
              description: "Genuine PCM WebSocket transcription. Beijing or Singapore workspace required; "
                + "automatic language detection.", latencyTier: .fast)
    ]
    public static let batchOptions: [ModelCatalog.Option] = [
        .init(id: funFlash, displayName: "Alibaba Fun-ASR-Flash (June 2026)",
              description: "Dedicated recorded speech recognition, up to 5 minutes. "
                + "Beijing or Singapore workspace required; local inline audio only.", latencyTier: .fast),
        .init(id: qwen35, displayName: "Alibaba Qwen3.5-Omni-Plus",
              description: "Audio understanding prompted for verbatim transcription, not dedicated ASR. "
                + "Beijing or Singapore workspace required; local inline audio only.", latencyTier: .medium),
        .init(id: qwen38, displayName: "Alibaba Qwen3.8-Omni-Flash",
              description: "Alibaba's current recommended audio-understanding model, prompted for transcription. "
                + "Text output only; not realtime ASR. Local inline audio only.", latencyTier: .medium)
    ]

    public static func apiModel(for identifier: String) throws -> String {
        guard allIDs.contains(identifier) else { throw AlibabaSpeechError.unsupportedModel }
        return identifier == funLive ? "fun-asr-realtime" : String(identifier.dropFirst("alibaba/".count))
    }
}
