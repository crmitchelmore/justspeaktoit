import Foundation
import SpeakCore

/// A staged clip prepared for the Voice Profile creator sheet before saving.
struct VoiceProfileStagedClip: Identifiable, Equatable {
    let id: UUID
    var pcmBuffer: VoiceProfilePCMBuffer
    var transcript: String
    let source: VoiceProfileClipSource
    let qualityReport: VoiceProfileQualityReport
    let trimSummary: String?
    var previewURL: URL?

    init(
        id: UUID = UUID(),
        pcmBuffer: VoiceProfilePCMBuffer,
        transcript: String,
        source: VoiceProfileClipSource,
        qualityReport: VoiceProfileQualityReport,
        trimSummary: String? = nil,
        previewURL: URL? = nil
    ) {
        self.id = id
        self.pcmBuffer = pcmBuffer
        self.transcript = transcript
        self.source = source
        self.qualityReport = qualityReport
        self.trimSummary = trimSummary
        self.previewURL = previewURL
    }
}

/// Manages private on-device voice profiles, History trimming, file import and Read Aloud picker projection.
@MainActor
final class VoiceProfileManager: ObservableObject {
    @Published private(set) var profiles: [VoiceProfile] = []
    @Published private(set) var lastError: String?

    let store: VoiceProfileStore
    var transcribeFile: (@MainActor (URL) async throws -> String)?

    init(store: VoiceProfileStore? = nil, fileManager: FileManager = .default) {
        if let store {
            self.store = store
        } else {
            let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser
            let supportDirectory = root.appendingPathComponent(ReleaseTrain.current.supportDirectory, isDirectory: true)
            self.store = VoiceProfileStore(directory: VoiceProfileStore.defaultDirectory(in: supportDirectory))
        }
        reload()
    }

    var myVoicePickerEntries: [MyVoicePickerEntry] {
        VoiceProfilePickerCatalog.entries(from: profiles)
    }

    var myTTSVoices: [TTSVoice] {
        myVoicePickerEntries.map { entry in
            TTSVoice(
                id: entry.id,
                name: entry.displayName,
                provider: Self.ttsProvider(forEngineID: entry.engineID, voiceID: entry.id),
                traits: [.builtin],
                previewURL: nil,
                customGroupTitle: VoiceProfilePickerCatalog.groupTitle
            )
        }
    }

    func reload() {
        do {
            profiles = try store.listProfiles()
            lastError = nil
        } catch {
            profiles = []
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func createProfile(
        name: String,
        language: String,
        clips: [VoiceProfileStore.ClipInput],
        consent: ConsentAttestation?
    ) throws -> VoiceProfile {
        let created = try store.createProfile(
            name: name,
            language: language,
            clips: clips,
            consent: consent
        )
        reload()
        return created
    }

    @discardableResult
    func renameProfile(id: UUID, name: String, language: String? = nil) throws -> VoiceProfile {
        let updated = try store.renameProfile(id: id, name: name, language: language)
        reload()
        return updated
    }

    @discardableResult
    func updateClipTranscript(profileID: UUID, clipID: UUID, transcript: String) throws -> VoiceProfile {
        let updated = try store.updateClipTranscript(profileID: profileID, clipID: clipID, transcript: transcript)
        reload()
        return updated
    }

    @discardableResult
    func addClip(_ input: VoiceProfileStore.ClipInput, to profileID: UUID) throws -> VoiceProfile {
        let updated = try store.addClip(input, to: profileID)
        reload()
        return updated
    }

    @discardableResult
    func removeClip(clipID: UUID, from profileID: UUID) throws -> VoiceProfile {
        let updated = try store.removeClip(clipID: clipID, from: profileID)
        reload()
        return updated
    }

    @discardableResult
    func upsertEngineBinding(_ binding: VoiceProfileEngineBinding, for profileID: UUID) throws -> VoiceProfile {
        let updated = try store.upsertEngineBinding(binding, for: profileID)
        reload()
        return updated
    }

    @discardableResult
    func removeEngineBinding(engineID: String, from profileID: UUID) throws -> VoiceProfile {
        let updated = try store.removeEngineBinding(engineID: engineID, from: profileID)
        reload()
        return updated
    }

    @discardableResult
    func deleteProfile(id: UUID) throws -> VoiceProfileStore.DeletionResult {
        let result = try store.deleteProfile(id: id)
        reload()
        return result
    }

    func clipURL(for clip: VoiceProfileClip, in profileID: UUID) throws -> URL {
        try store.clipURL(for: clip, in: profileID)
    }

    func prepareClipFromHistory(
        _ item: HistoryItem,
        targetFormat: VoiceProfileAudioFormat = .pcm24k
    ) throws -> VoiceProfileStagedClip {
        guard let url = item.audioFileURL else {
            throw VoiceProfileAudioAdapterError.emptyAudio
        }
        let decoded = try VoiceProfileAudioAdapter.decodeAudioFile(at: url, targetFormat: targetFormat)
        let trimResult = VoiceProfileClipTrimmer().trim(decoded)
        let resampled = VoiceProfileWAVCodec.resample(trimResult.buffer, to: targetFormat)
        let report = VoiceProfileQualityGate().evaluate(resampled)
        let summary = String(
            format: "Trimmed %.1f–%.1f s (%.1f s) from %.1f s recording",
            trimResult.startTimeSeconds,
            trimResult.endTimeSeconds,
            resampled.durationSeconds,
            trimResult.originalDurationSeconds
        )
        let previewURL = try? VoiceProfileAudioAdapter.writeTemporaryPreviewWAV(for: resampled)
        let wasTrimmed = trimResult.startTimeSeconds > 0.25
            || (trimResult.originalDurationSeconds - trimResult.endTimeSeconds) > 0.25
        let verbatimTranscript = [item.rawTranscription, item.postProcessedTranscription]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let transcript = wasTrimmed ? "" : verbatimTranscript
        return VoiceProfileStagedClip(
            pcmBuffer: resampled,
            transcript: transcript,
            source: .history,
            qualityReport: report,
            trimSummary: summary,
            previewURL: previewURL
        )
    }

    func prepareClipFromFile(
        at url: URL,
        targetFormat: VoiceProfileAudioFormat = .pcm24k
    ) throws -> VoiceProfileStagedClip {
        let decoded = try VoiceProfileAudioAdapter.decodeAudioFile(at: url, targetFormat: targetFormat)
        let trimmedOrOriginal: VoiceProfilePCMBuffer
        let trimSummary: String?
        if decoded.durationSeconds > VoiceProfile.maximumClipDuration {
            let trimmed = VoiceProfileClipTrimmer().trim(decoded)
            trimmedOrOriginal = VoiceProfileWAVCodec.resample(trimmed.buffer, to: targetFormat)
            trimSummary = String(
                format: "Trimmed %.1f–%.1f s (%.1f s) from %.1f s file",
                trimmed.startTimeSeconds,
                trimmed.endTimeSeconds,
                trimmedOrOriginal.durationSeconds,
                trimmed.originalDurationSeconds
            )
        } else {
            trimmedOrOriginal = decoded
            trimSummary = nil
        }
        let report = VoiceProfileQualityGate().evaluate(trimmedOrOriginal)
        let previewURL = try? VoiceProfileAudioAdapter.writeTemporaryPreviewWAV(for: trimmedOrOriginal)
        return VoiceProfileStagedClip(
            pcmBuffer: trimmedOrOriginal,
            transcript: "",
            source: .imported,
            qualityReport: report,
            trimSummary: trimSummary,
            previewURL: previewURL
        )
    }

    func stageRecordedClip(
        _ buffer: VoiceProfilePCMBuffer,
        transcript: String
    ) -> VoiceProfileStagedClip {
        let normalized = VoiceProfileWAVCodec.resample(buffer, to: .pcm24k)
        let report = VoiceProfileQualityGate().evaluate(normalized)
        let previewURL = try? VoiceProfileAudioAdapter.writeTemporaryPreviewWAV(for: normalized)
        return VoiceProfileStagedClip(
            pcmBuffer: normalized,
            transcript: transcript,
            source: .recorded,
            qualityReport: report,
            trimSummary: nil,
            previewURL: previewURL
        )
    }

    /// Uses the user's currently configured batch transcription model to auto-fill a clip transcript.
    func transcribeBuffer(_ buffer: VoiceProfilePCMBuffer) async throws -> String {
        guard let transcribeFile else {
            throw VoiceProfileStoreError.storageFailure("Transcription is not available right now.")
        }
        let wavData = try VoiceProfileWAVCodec.encodeWAV(buffer, format: .pcm16k)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-profile-transcribe-\(UUID().uuidString).wav", isDirectory: false)
        try wavData.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        return try await transcribeFile(tempURL).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func ttsProvider(forEngineID engineID: String, voiceID: String) -> TTSProvider {
        let loweredEngine = engineID.lowercased()
        if loweredEngine.hasPrefix("elevenlabs") || voiceID.hasPrefix("elevenlabs/") { return .elevenlabs }
        if loweredEngine.hasPrefix("mistral") || voiceID.hasPrefix("mistral/") { return .mistral }
        if loweredEngine.hasPrefix("xai") || voiceID.hasPrefix("xai/") { return .xai }
        if loweredEngine.hasPrefix("cartesia") || voiceID.hasPrefix("cartesia/") { return .cartesia }
        return .system
    }
}
