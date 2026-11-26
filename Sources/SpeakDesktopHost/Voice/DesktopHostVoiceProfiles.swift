import Foundation
import SpeakCore
import SpeakDesktop

/// A reference clip staged from History or file import before saving to `VoiceProfileStore`.
package struct VoiceProfilePreparedClip: Equatable, Sendable {
    package let pcmBuffer: VoiceProfilePCMBuffer
    package let qualityReport: VoiceProfileQualityReport
    package let trimResult: VoiceProfileTrimResult?
    package let suggestedTranscript: String
    package let source: VoiceProfileClipSource
}

extension DesktopHostController {
    package func listVoiceProfiles() -> [VoiceProfile] {
        (try? voiceProfiles.listProfiles()) ?? []
    }

    package func loadVoiceProfiles() throws -> [VoiceProfile] {
        try voiceProfiles.listProfiles()
    }

    package func myVoicePickerEntries() -> [MyVoicePickerEntry] {
        VoiceProfilePickerCatalog.entries(from: listVoiceProfiles())
    }

    package func prepareVoiceProfileClipFromHistory(
        recordID: UUID,
        targetFormat: VoiceProfileAudioFormat = .pcm16k
    ) async throws -> VoiceProfilePreparedClip {
        let record = try await store.record(id: recordID)
        let audioURL = try await store.audioURL(for: record)
        let decoded = try await decodeAudioFileToMonoPCM(at: audioURL, targetFormat: targetFormat)
        let trimResult = VoiceProfileClipTrimmer().trim(decoded)
        let resampled = VoiceProfileWAVCodec.resample(trimResult.buffer, to: targetFormat)
        let report = VoiceProfileQualityGate().evaluate(resampled)
        let adjustedTrim = VoiceProfileTrimResult(
            buffer: resampled,
            startTimeSeconds: trimResult.startTimeSeconds,
            endTimeSeconds: trimResult.endTimeSeconds,
            originalDurationSeconds: trimResult.originalDurationSeconds,
            qualityReport: report
        )
        let wasTrimmed = trimResult.startTimeSeconds > 0.25
            || (trimResult.originalDurationSeconds - trimResult.endTimeSeconds) > 0.25
        let verbatimTranscript = [record.originalText, record.displayText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let transcript = wasTrimmed ? "" : verbatimTranscript
        return VoiceProfilePreparedClip(
            pcmBuffer: resampled,
            qualityReport: report,
            trimResult: adjustedTrim,
            suggestedTranscript: transcript,
            source: .history
        )
    }

    package func prepareVoiceProfileClipFromFile(
        at url: URL,
        targetFormat: VoiceProfileAudioFormat = .pcm16k
    ) async throws -> VoiceProfilePreparedClip {
        try DesktopHostImport.validate(url)
        let decoded = try await decodeAudioFileToMonoPCM(at: url, targetFormat: targetFormat)
        let report = VoiceProfileQualityGate().evaluate(decoded)
        return VoiceProfilePreparedClip(
            pcmBuffer: decoded,
            qualityReport: report,
            trimResult: nil,
            suggestedTranscript: "",
            source: .imported
        )
    }

    /// Transcribes a prepared clip using the host's configured batch/local transcription model.
    package func transcribeVoiceProfileClip(_ buffer: VoiceProfilePCMBuffer) async throws -> String {
        guard !closed else { throw CancellationError() }
        let model = batchTranscriptionModelForVoiceProfile()
        _ = try requireCredentialOrLocalModel(model)
        try requireCloudSharing([DesktopHostCloudSharing.transcription(model: model)])
        let key = try transcriptionKey(for: model)

        let stagingRoot = directory.appendingPathComponent("VoiceProfileStaging", isDirectory: true)
        try Platform.preparePrivateDirectory(stagingRoot)
        let tempURL = stagingRoot.appendingPathComponent("clip-\(UUID().uuidString).wav", isDirectory: false)
        let wavData = try VoiceProfileWAVCodec.encodeWAV(buffer, format: .pcm16k)
        try wavData.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try checkUploadSize(tempURL, model: model)
        let heldLocal = beginLocalUse(model)
        defer { endLocalUse(heldLocal) }

        let request = DesktopHostTranscriptionRequest(
            audio: tempURL,
            model: model,
            key: key,
            duration: buffer.durationSeconds,
            language: settings.configuration?.language
        )
        let result = try await effects.transcribe(request, with: self)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    package func createVoiceProfile(
        name: String,
        language: String,
        clips: [VoiceProfileStore.ClipInput],
        consent: ConsentAttestation?
    ) throws -> VoiceProfile {
        try voiceProfiles.createProfile(
            name: name,
            language: language,
            clips: clips,
            consent: consent
        )
    }

    package func updateVoiceProfileClipTranscript(
        profileID: UUID,
        clipID: UUID,
        transcript: String
    ) throws -> VoiceProfile {
        try voiceProfiles.updateClipTranscript(
            profileID: profileID,
            clipID: clipID,
            transcript: transcript
        )
    }

    package func upsertVoiceProfileBinding(
        _ binding: VoiceProfileEngineBinding,
        for profileID: UUID
    ) throws -> VoiceProfile {
        try voiceProfiles.upsertEngineBinding(binding, for: profileID)
    }

    package func removeVoiceProfileBinding(
        engineID: String,
        from profileID: UUID
    ) throws -> VoiceProfile {
        try voiceProfiles.removeEngineBinding(engineID: engineID, from: profileID)
    }

    package func deleteVoiceProfile(id: UUID) throws -> VoiceProfileStore.DeletionResult {
        try voiceProfiles.deleteProfile(id: id)
    }

    private func decodeAudioFileToMonoPCM(
        at url: URL,
        targetFormat: VoiceProfileAudioFormat
    ) async throws -> VoiceProfilePCMBuffer {
        if url.pathExtension.lowercased() == "wav" {
            let decoded = try VoiceProfileWAVCodec.decodeWAV(at: url)
            return VoiceProfileWAVCodec.resample(decoded, to: targetFormat)
        }
        let stagingRoot = directory.appendingPathComponent("VoiceProfileStaging", isDirectory: true)
        try Platform.preparePrivateDirectory(stagingRoot)
        let tempURL = stagingRoot.appendingPathComponent("import-\(UUID().uuidString).wav", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        _ = try await Platform.convertAudio(input: url, output: tempURL)
        let decoded = try VoiceProfileWAVCodec.decodeWAV(at: tempURL)
        return VoiceProfileWAVCodec.resample(decoded, to: targetFormat)
    }

    private func batchTranscriptionModelForVoiceProfile() -> String {
        if DesktopHostModels.isLocal(settings.model) && !DesktopHostModels.isLocalLive(settings.model) {
            return settings.model
        }
        if !DesktopHostModels.isLive(settings.model) && !DesktopHostModels.isLocalLive(settings.model) {
            return settings.model
        }
        if DesktopHostModels.isLocalLive(settings.model), let localBatch = settings.localModel {
            return localBatch
        }
        return settings.batchModel ?? ModelCatalog.defaultBatchTranscriptionModel
    }
}
