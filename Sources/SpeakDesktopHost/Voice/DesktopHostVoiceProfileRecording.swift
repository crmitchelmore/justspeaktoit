import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController where Platform: DesktopNativeWindowPlatform {
    func startVoiceProfileRecording(_ draft: DesktopHostVoiceProfileDraft) throws {
        guard canUseHistory, draft.capture == nil, ownedCaptureStartup == nil, ownedDictation == nil,
              ownedDictationAdmission == nil, !handsFreeMachine.isArmed else {
            throw DesktopHostError(message: "Finish the current audio operation before recording a voice profile.")
        }
        stopReadAloud()
        draft.preview?.cancel()
        let samples = DesktopProfileSamples()
        let context = DesktopCaptureContext(
            onPCM: { samples.append($0, count: $1) },
            onFailure: { [weak self] message in
                Task { await self?.voiceProfileRecordingFailed(samples: samples, message: message) }
            }
        )
        let capture = try effects.makeCapture(context: context, deviceID: settings.microphoneDeviceID ?? "",
            sampleRate: DesktopProfileSamples.rate, frameMilliseconds: 100)
        do { try capture.start() } catch {
            try? capture.stop()
            capture.destroy()
            throw error
        }
        beginBusyOperation()
        draft.current = nil
        draft.capture = capture
        draft.samples = samples
        let script = VoiceProfilePromptCatalog.defaultScript()
        showVoiceProfile(draft, phase: 3, status: "Recording. Read the script aloud, then choose Stop.",
            transcript: script.fullText)
        draft.meter = Task {
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard !closed, voiceProfileDraft === draft, draft.samples === samples else { return }
                let measured = samples.meter()
                if ContinuousClock.now >= deadline || measured.seconds >= 30 {
                    do { try finishVoiceProfileRecording(draft) } catch {
                        showVoiceProfile(draft, phase: -1, status: error.localizedDescription)
                    }
                    return
                }
                let level = measured.peak >= 0.99 ? "clipping" : "\(Int(measured.peak * 100))%"
                showVoiceProfile(draft, phase: 4, status: String(format: "%.1f s · Level %@", measured.seconds, level))
            }
        }
    }

    func voiceProfileRecordingFailed(samples: DesktopProfileSamples, message: String) {
        guard let draft = voiceProfileDraft, draft.samples === samples else { return }
        _ = try? stopProfileCapture(draft)
        showVoiceProfile(draft, phase: -1, status: message)
    }

    func finishVoiceProfileRecording(_ draft: DesktopHostVoiceProfileDraft) throws {
        let buffer = try stopProfileCapture(draft)
        let clip = VoiceProfilePreparedClip(pcmBuffer: buffer,
            qualityReport: VoiceProfileQualityGate().evaluate(buffer),
            trimResult: nil, suggestedTranscript: VoiceProfilePromptCatalog.defaultScript().fullText, source: .recorded)
        try stageVoiceProfileClip(clip, draft: draft)
    }

    private func stopProfileCapture(_ draft: DesktopHostVoiceProfileDraft) throws -> VoiceProfilePCMBuffer {
        guard let capture = draft.capture, let samples = draft.samples else { throw CancellationError() }
        draft.meter?.cancel()
        draft.meter = nil
        draft.capture = nil
        draft.samples = nil
        defer {
            capture.destroy()
            finishBusyOperation()
        }
        try capture.stop()
        return samples.buffer()
    }
}
