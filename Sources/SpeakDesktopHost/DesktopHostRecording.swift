import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController {
    func startRecording(
        target: Platform.InsertionTarget?, deviceID: String, profile: DesktopProfileSession,
        textOutput: Platform.TextOutputOptions, trigger: HotKeySessionTrigger = .other
    ) async throws {
        let key = try requireCredentialOrLocalModel(profile.modelIdentifier)
        try requireAzureResource(forLive: profile.modelIdentifier)
        // Holds a profile's or the app's on-device model while startup suspends;
        // the recording holds it once capture starts.
        let localModel = beginLocalUse(profile.modelIdentifier)
        defer { endLocalUse(localModel) }
        let id = UUID()
        let filename = id.uuidString + ".wav"
        let audio = directory.appendingPathComponent("History").appendingPathComponent(filename)
        let rate = DesktopLiveTranscription.route(forID: profile.modelIdentifier)?.sampleRate
            ?? PCMRecordingFile.sampleRate
        let file = try PCMRecordingFile(url: audio, sampleRate: rate)
        let record = profileRecord(id: id, filename: filename, profile: profile)
        var live: DesktopLiveSession?
        do {
            // The parent operation remains active through every metadata write,
            // so shutdown cannot return while startup is suspended here.
            try await saveRecord(record)
            guard !closed else { throw CancellationError() }
            live = makeLiveSession(model: profile.modelIdentifier, key: key, id: id, language: profile.language)
            live?.start()
            let context = DesktopCaptureContext(file: file, live: live) { message in
                Task { await self.captureFailed(message, recordingID: id) }
            }
            let capture = try effects.makeCapture(
                context: context, deviceID: deviceID, sampleRate: rate,
                frameMilliseconds: DesktopLiveTranscription.captureFrameMilliseconds(forID: profile.modelIdentifier)
            )
            do { try capture.start() } catch {
                capture.destroy()
                throw error
            }
            recording = Recording(
                capture: capture, context: context, record: record, target: target, live: live, profile: profile,
                textOutput: textOutput, trigger: trigger
            )
            if let live { monitorLive(live) }
        } catch {
            live?.cancel()
            // Always close the WAV, including failure before native allocation.
            var failed = record
            let startupFailure = error
            failed.failure = closed ? "Recording cancelled when the app closed. Audio retained."
                : startupFailure.localizedDescription
            do { _ = try file.finish() } catch {
                failed.failure = "\(failed.failure ?? "Recording failed.") "
                    + "Audio finalization failed: \(error.localizedDescription)"
            }
            do { try await saveRecord(failed) } catch {
                throw DesktopHostError(message: "\(failed.failure ?? "Recording failed.") "
                    + "History could not be saved: \(error.localizedDescription)")
            }
            throw startupFailure
        }
        update(profileRecordingStatus(profile, trigger: trigger), state: 1)
    }

    func stopCapture() throws -> StoppedRecording? {
        guard let active = recording else { return nil }
        recording = nil
        liveUpdates?.cancel()
        liveUpdates = nil
        let duration: TimeInterval
        do { duration = try DesktopHostRecordingStop.stop(active.capture, file: active.context.file) } catch {
            active.live?.cancel()
            throw error
        }
        return StoppedRecording(
            record: active.record, duration: duration, target: active.target, live: active.live,
            profile: active.profile, textOutput: active.textOutput
        )
    }
}

/// Ends a recording's capture, shared by stopping and by closing.
enum DesktopHostRecordingStop {
    /// Stops `capture`, finalises its WAV and destroys the capture whatever
    /// fails. Returns the audio's duration, zero when it is digital silence.
    static func stop(_ capture: any DesktopRecordingCapture, file: PCMRecordingFile) throws -> TimeInterval {
        defer { capture.destroy() }
        var stopFailure: Error?
        do { try capture.stop() } catch { stopFailure = error }
        let duration = try file.finish()
        if let stopFailure { throw stopFailure }
        return file.isDigitalSilence ? 0 : duration
    }

    /// A live session's text as a saved result; effectively empty text is empty.
    static func liveResult(_ text: String, model: String, duration: TimeInterval) -> TranscriptionResult {
        let cleaned = TranscriptPostProcessingPolicy.isEffectivelyEmptyTranscript(text) ? "" : text
        return TranscriptionResult(
            text: cleaned, segments: [], confidence: nil, duration: duration,
            modelIdentifier: model, cost: nil, rawPayload: nil, debugInfo: nil
        )
    }
}
