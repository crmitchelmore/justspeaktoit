import Foundation

/// Phonon currently uses an external MLX runtime: direct macOS on Apple silicon only.
/// Keep the entry canonical even where the executable runtime cannot be offered.
public enum PhononLocalModels {
    public static let phonon2 = LocalTranscriptionModel(
        id: "local/phonon/phonon-2",
        displayName: "Phonon-2",
        modelName: "phonon-2",
        engine: .phonon,
        modelRepo: "FermionResearch/Phonon-2",
        approximateSizeMB: 164,
        description: "Compact English transcription by Fermion Research, based on NVIDIA Parakeet. "
            + "Runs offline on Apple silicon. CC-BY-4.0 weights; additional runtime download required.",
        tags: [.fast, .quality, .leading]
    )

    public static func isSupported(channel: DistributionChannel, isAppleSilicon: Bool) -> Bool {
        channel.supportsExternalLocalModelRuntime && isAppleSilicon
    }

    public static var isSupportedOnCurrentPlatform: Bool {
        #if os(macOS) && arch(arm64) && !APP_STORE
        return isSupported(channel: .current, isAppleSilicon: true)
        #else
        return false
        #endif
    }
}

public extension ModelCatalog {
    /// The primary batch recommendation comes first; saved selections are not migrated.
    static var availableLocalTranscription: [LocalTranscriptionModel] {
        let whisperKit = localTranscription.filter { $0.engine == .whisperKit }
        return PhononLocalModels.isSupportedOnCurrentPlatform ? [PhononLocalModels.phonon2] + whisperKit : whisperKit
    }
}
