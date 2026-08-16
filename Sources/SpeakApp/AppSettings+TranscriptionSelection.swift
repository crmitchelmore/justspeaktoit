import Foundation
import SpeakCore

/// Transcription placement selection, owned by `AppSettings` so it is a
/// persisted, testable source of truth rather than settings-screen state.
extension AppSettings {
    enum TranscriptionLocation: String, CaseIterable, Identifiable {
        case remote
        case local

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .remote: return "Remote"
            case .local: return "Local"
            }
        }
    }

    enum RemoteTranscriptionMode: String, CaseIterable, Identifiable {
        case streaming
        case batch

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .streaming: return "Remote Streaming"
            case .batch: return "Remote Batch"
            }
        }
    }

    enum LocalTranscriptionSource: String, CaseIterable, Identifiable {
        case apple
        case downloaded

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .apple: return "Apple Speech"
            case .downloaded: return "Downloaded Model"
            }
        }
    }

    // MARK: - Derived state

    var isAppleOnDeviceTranscriptionSelected: Bool {
        transcriptionMode == .liveNative
            && ModelCatalog.isOnDeviceLiveTranscriptionModel(liveTranscriptionModel)
    }

    var isLocalTranscriptionSelected: Bool {
        transcriptionMode == .localModel || isAppleOnDeviceTranscriptionSelected
    }

    var isRemoteStreamingTranscriptionSelected: Bool {
        transcriptionMode == .liveNative && !isAppleOnDeviceTranscriptionSelected
    }

    var isStreamingTranscriptionSelected: Bool {
        transcriptionMode == .liveNative
            || (transcriptionMode == .localModel && localTranscriptionMode == .streaming)
    }

    var transcriptionLocation: TranscriptionLocation {
        isLocalTranscriptionSelected ? .local : .remote
    }

    var localTranscriptionSource: LocalTranscriptionSource {
        if isLocalTranscriptionSelected {
            return isAppleOnDeviceTranscriptionSelected ? .apple : .downloaded
        }
        return rememberedLocalTranscriptionSource
    }

    var remoteTranscriptionMode: RemoteTranscriptionMode {
        if isLocalTranscriptionSelected { return rememberedRemoteTranscriptionMode }
        return transcriptionMode == .batchRemote ? .batch : .streaming
    }

    // MARK: - Selection

    /// Switches between local and remote transcription, restoring whatever the
    /// user last chose on the side they are returning to. Defaults apply only
    /// when that side has no remembered selection.
    func selectTranscriptionLocation(_ location: TranscriptionLocation) {
        switch location {
        case .local:
            selectLocalTranscriptionSource(rememberedLocalTranscriptionSource)
        case .remote:
            selectRemoteTranscriptionMode(rememberedRemoteTranscriptionMode)
        }
    }

    func selectLocalTranscriptionSource(_ source: LocalTranscriptionSource) {
        rememberedLocalTranscriptionSource = source
        switch source {
        case .apple:
            liveTranscriptionModel = liveTranscriptionSelection.model(
                for: .onDevice,
                activeModel: liveTranscriptionModel
            )
            transcriptionMode = .liveNative
        case .downloaded:
            transcriptionMode = .localModel
        }
    }

    func selectRemoteTranscriptionMode(_ mode: RemoteTranscriptionMode) {
        rememberedRemoteTranscriptionMode = mode
        switch mode {
        case .streaming:
            liveTranscriptionModel = liveTranscriptionSelection.model(
                for: .remote,
                activeModel: liveTranscriptionModel
            )
            transcriptionMode = .liveNative
        case .batch:
            transcriptionMode = .batchRemote
        }
    }

    /// Repairs the remembered local source after a downloaded model is removed.
    /// A remote session stays remote; an active downloaded-local session falls
    /// back to Apple Speech when no installed replacement remains.
    func repairDownloadedTranscriptionSelection(fallbackModelID: String?) {
        if let fallbackModelID {
            localTranscriptionModel = fallbackModelID
            return
        }
        rememberedLocalTranscriptionSource = .apple
        guard transcriptionMode == .localModel else { return }
        selectLocalTranscriptionSource(.apple)
    }
}
