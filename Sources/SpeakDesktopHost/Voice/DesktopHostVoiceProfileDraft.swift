import Foundation
import SpeakCore
import SpeakDesktop

final class DesktopHostVoiceProfileDraft {
    let session: UUID
    var deletion: VoiceProfile?
    var current: VoiceProfilePreparedClip?
    var clips: [VoiceProfileStore.ClipInput] = []
    var capture: (any DesktopRecordingCapture)?
    var samples: DesktopProfileSamples?
    var meter: Task<Void, Never>?
    var preview: Task<Void, Never>?

    init(session: UUID) { self.session = session }

    func clipInput(transcript: String) throws -> VoiceProfileStore.ClipInput {
        guard let current else { throw DesktopHostError(message: "Choose or record a reference clip first.") }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DesktopHostError(message: "Enter the words spoken in this clip.")
        }
        return .init(pcmBuffer: current.pcmBuffer, targetFormat: .pcm16k,
            transcript: transcript, source: current.source)
    }
}

final class DesktopProfileSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var peak: Float = 0
    static let rate = 16_000

    init() { samples.reserveCapacity(Self.rate * 30) }

    func append(_ values: UnsafePointer<Int16>, count: Int) {
        lock.withLock {
            let remaining = Self.rate * 30 - samples.count
            for sample in UnsafeBufferPointer(start: values, count: min(remaining, count)) {
                let normalized = Float(sample) / 32_768
                peak = max(peak, abs(normalized))
                samples.append(normalized)
            }
        }
    }

    func meter() -> (seconds: Double, peak: Float) {
        lock.withLock {
            defer { peak = 0 }
            return (Double(samples.count) / Double(Self.rate), peak)
        }
    }

    func buffer() -> VoiceProfilePCMBuffer {
        lock.withLock { .init(samples: samples, sampleRate: Self.rate) }
    }
}

// The draft gives its capture to a single cleanup operation before leaving the controller.
private final class RetiredProfileCapture: @unchecked Sendable {
    private let capture: any DesktopRecordingCapture
    init(_ capture: any DesktopRecordingCapture) { self.capture = capture }

    func stop() {
        try? capture.stop()
        capture.destroy()
    }
}

extension DesktopHostController {
    func retireVoiceProfileDraft() {
        guard let draft = voiceProfileDraft else { return }
        voiceProfileDraft = nil
        draft.preview?.cancel()
        draft.meter?.cancel()
        guard let capture = draft.capture else { return }
        draft.capture = nil
        draft.samples = nil
        let retired = RetiredProfileCapture(capture)
        if closed {
            // close() counts this busy operation against its existing shutdown deadline.
            Task.detached {
                retired.stop()
                await self.finishBusyOperation()
            }
        } else {
            retired.stop()
            finishBusyOperation()
        }
    }
}

extension DesktopHostController where Platform: DesktopNativeWindowPlatform {
    func handleVoiceProfileCommand(_ command: DesktopVoiceProfileCommand) async {
        guard !closed else { return }
        if command.operation == .prepare, voiceProfileDraft?.session != command.session {
            retireVoiceProfileDraft()
            let draft = DesktopHostVoiceProfileDraft(session: command.session)
            voiceProfileDraft = draft
            presentProfileList(draft)
        }
        guard let draft = voiceProfileDraft, draft.session == command.session else { return }
        do {
            try await applyVoiceProfileCommand(command, draft: draft)
        } catch {
            showVoiceProfile(draft, phase: -1, status: error.localizedDescription)
        }
    }

    private func applyVoiceProfileCommand(
        _ command: DesktopVoiceProfileCommand, draft: DesktopHostVoiceProfileDraft
    ) async throws {
        switch command.operation {
        case .prepare: try await prepareNativeProfileReference(command.reference, draft: draft)
        case .transcribe: try await transcribeNativeProfileReference(draft)
        case .preview: try previewVoiceProfileClip(draft)
        case .addClip, .save: try commitNativeProfileClip(command, draft: draft)
        case .inspectDeletion, .delete:
            try manageVoiceProfile(command, draft: draft)
        case .record: try startVoiceProfileRecording(draft)
        case .stopRecording: try finishVoiceProfileRecording(draft)
        case .close: retireVoiceProfileDraft()
        }
    }

    private func prepareNativeProfileReference(_ reference: String, draft: DesktopHostVoiceProfileDraft) async throws {
        draft.preview?.cancel()
        draft.current = nil
        guard !reference.isEmpty else {
            showVoiceProfile(draft, status: "Choose audio or record a guided script.", transcript: "")
            return
        }
        let clip: VoiceProfilePreparedClip
        if let id = UUID(uuidString: reference) {
            clip = try await prepareVoiceProfileClipFromHistory(recordID: id)
        } else {
            clip = try await prepareVoiceProfileClipFromFile(at: URL(fileURLWithPath: reference))
        }
        try stageVoiceProfileClip(clip, draft: draft)
    }

    private func transcribeNativeProfileReference(_ draft: DesktopHostVoiceProfileDraft) async throws {
        guard let clip = draft.current else { throw DesktopHostError(message: "Choose a reference clip first.") }
        guard DesktopHostModels.isLocal(batchTranscriptionModelForVoiceProfile()) else {
            throw DesktopHostError(message: "Select a local transcription model or enter the transcript by hand.")
        }
        let words = try await transcribeVoiceProfileClip(clip.pcmBuffer)
        showVoiceProfile(draft, status: "Review the transcript before saving.", transcript: words)
    }

    private func commitNativeProfileClip(
        _ command: DesktopVoiceProfileCommand, draft: DesktopHostVoiceProfileDraft
    ) throws {
        if command.operation == .addClip {
            guard draft.clips.count < 2 else { throw DesktopHostError(message: "Save with the third reference clip.") }
            draft.clips.append(try draft.clipInput(transcript: command.text))
            draft.current = nil
            showVoiceProfile(draft, phase: 2, status: "Added clip \(draft.clips.count). Choose another.",
                transcript: "")
        } else {
            var clips = draft.clips
            if draft.current != nil { clips.append(try draft.clipInput(transcript: command.text)) }
            _ = try createVoiceProfile(name: command.name, language: command.language, clips: clips, consent: .init())
            let message = "Saved “\(command.name)” on this device."
            showVoiceProfile(draft, phase: 1, status: message)
            update(message)
            retireVoiceProfileDraft()
        }
    }

    func stageVoiceProfileClip(_ clip: VoiceProfilePreparedClip, draft: DesktopHostVoiceProfileDraft) throws {
        guard voiceProfileDraft === draft, !closed else { throw CancellationError() }
        guard clip.qualityReport.passed else { throw VoiceProfileStoreError.qualityCheckFailed(clip.qualityReport) }
        draft.current = clip
        let duration = String(format: "%.1f seconds", clip.pcmBuffer.durationSeconds)
        let window = clip.trimResult.map {
            String(format: " (%.1f–%.1f s)", $0.startTimeSeconds, $0.endTimeSeconds)
        } ?? ""
        showVoiceProfile(draft, phase: 5, status: "Reference clip: \(duration)\(window).",
            transcript: clip.suggestedTranscript)
    }

    private func previewVoiceProfileClip(_ draft: DesktopHostVoiceProfileDraft) throws {
        guard canUseHistory, let clip = draft.current else {
            throw DesktopHostError(message: "Choose a reference clip and finish any active recording first.")
        }
        draft.preview?.cancel()
        stopReadAloud()
        let wav = try VoiceProfileWAVCodec.encodeWAV(clip.pcmBuffer, format: .pcm16k)
        let audio = try VoiceGeneratedAudio(validating: wav, sampleRate: 16_000)
        let speech = try playback.beginSpeech(recordID: draft.session)
        let player = playback
        let root = directory.appendingPathComponent("VoiceProfileStaging")
        draft.preview = Task {
            defer { player.endSpeech(speech) }
            do {
                try await DesktopVoicePlaybackFile.play(audio, directory: root,
                    prepare: Platform.preparePrivateDirectory,
                    through: { try await player.playToCompletion(speech, path: $0.path) })
            } catch where !Task.isCancelled {
                showVoiceProfile(draft, phase: -1, status: error.localizedDescription)
            } catch {}
        }
        showVoiceProfile(draft, status: "Playing the prepared reference clip.")
    }

    func showVoiceProfile(
        _ draft: DesktopHostVoiceProfileDraft, phase: Int32 = 0, status: String, transcript: String? = nil
    ) {
        guard !closed, voiceProfileDraft === draft else { return }
        _ = Platform.nativeVoice.profileResult(draft.session.uuidString.lowercased(), phase, status, transcript)
    }
}
