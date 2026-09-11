import Foundation

public enum AzureTranscriptionModels {
    public static let fast = "azure/fast-transcription"
    public static let mai2 = "azure/mai-transcribe-2"
    public static let mai15 = "azure/mai-transcribe-1.5"
    public static let speechLive = "azure/azure-speech-streaming"
    public static let maiLive = "azure/mai-transcribe-streaming"
    public static let batchIDs: Set<String> = [fast, mai2, mai15]

    public static let batchOptions: [ModelCatalog.Option] = [
        .init(id: fast, displayName: "Azure Fast Transcription",
              description: "Recorded audio through your Azure Speech resource. Requires an eligible tier and region."),
        .init(id: mai2, displayName: "Azure MAI-Transcribe-2 (Preview)",
              description: "Multilingual recorded-audio transcription. Requires an eligible Azure Speech resource."),
        .init(id: mai15, displayName: "Azure MAI-Transcribe-1.5 (Preview)",
              description: "Previous-generation MAI recorded-audio transcription through Azure Speech.")
    ]
    public static let liveOptions: [ModelCatalog.Option] = [
        .init(id: speechLive, displayName: "Azure Speech (Voice Live)",
              description: "Live input transcription through Azure Voice Live, with assistant responses disabled."),
        .init(id: maiLive, displayName: "Azure MAI Transcribe (Voice Live, Preview)",
              description: "Live MAI transcription uses an Azure-selected version, separate from the MAI-2 file API.")
    ]
}
