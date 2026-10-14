import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController {
    func startRecording(
        target: Platform.InsertionTarget?, deviceID: String, profile: DesktopProfileSession,
        textOutput: Platform.TextOutputOptions, trigger: HotKeySessionTrigger = .other,
        handsFree: DesktopHandsFreeRun<Platform>? = nil
    ) async throws {
        let key = try requireCredentialOrLocalModel(profile.modelIdentifier)
        try requireAzureResource(forLive: profile.modelIdentifier)
        // Holds a profile's or the app's on-device model while startup suspends;
        // the recording holds it once capture starts.
        let localModel = beginLocalUse(profile.modelIdentifier)
        defer { endLocalUse(localModel) }
        let id = UUID()
        await recordingFeedback?.recordingRequested(id)
        guard !closed, handsFree == nil || handsFreeRun?.id == handsFree?.id else { throw CancellationError() }
        let filename = id.uuidString + ".wav"
        let audio = directory.appendingPathComponent("History").appendingPathComponent(filename)
        let rate = DesktopLiveTranscription.route(forID: profile.modelIdentifier)?.sampleRate
            ?? PCMRecordingFile.sampleRate
        let file: PCMRecordingFile
        do { file = try PCMRecordingFile(url: audio, sampleRate: rate) } catch {
            await recordingFeedback?.cancelRecording(id)
            throw error
        }
        let record = profileRecord(id: id, filename: filename, profile: profile)
        var live: DesktopLiveSession?
        do {
            // The parent operation remains active through every metadata write,
            // so shutdown cannot return while startup is suspended here.
            try await saveRecord(record)
            guard !closed, handsFree == nil || handsFreeRun?.id == handsFree?.id else { throw CancellationError() }
            live = makeLiveSession(model: profile.modelIdentifier, key: key, id: id, language: profile.language)
            live?.start()
            let context = captureContext(file: file, live: live, rate: rate, id: id, handsFree: handsFree != nil)
            let capture = try handsFree.map { run -> any DesktopRecordingCapture in
                DesktopHandsFreeUtteranceCapture(audio: run.audio, context: context)
            }
                ?? effects.makeCapture(
                    context: context, deviceID: deviceID, sampleRate: rate,
                    frameMilliseconds: DesktopLiveTranscription.captureFrameMilliseconds(forID: profile.modelIdentifier)
                )
            do { try capture.start() } catch {
                capture.destroy()
                throw error
            }
            recording = Recording(
                capture: capture, context: context, file: file, handsFree: handsFree != nil,
                record: record, target: target, live: live, profile: profile,
                textOutput: textOutput, trigger: trigger
            )
            if let live { monitorLive(live) }
            await notifyRecordingFeedback(id, handsFree: handsFree != nil, captureReady: true)
        } catch {
            await recordingFeedback?.cancelRecording(id)
            live?.cancel()
            try await saveFailedRecordingStartup(record, file: file, failure: error)
            throw error
        }
        guard !closed, recording?.record.id == id else { return }
        announceRecording(id, profile: profile, trigger: trigger)
    }

    private func captureContext(
        file: PCMRecordingFile, live: DesktopLiveSession?, rate: Int, id: UUID, handsFree: Bool
    ) -> DesktopCaptureContext {
        let configuration = settings.configuration
        let silence = !handsFree && configuration?.enabled("silenceDetectionEnabled") == true
            ? DictationSilenceMonitor(
                threshold: configuration?.number("silenceThreshold") ?? DictationSilencePolicy.defaultThreshold,
                duration: configuration?.number("silenceDuration") ?? DictationSilencePolicy.defaultDuration
            ) : nil
        return DesktopCaptureContext(
            file: file, live: live, sampleRate: rate, silence: silence,
            onSilence: { Task { await self.stopForSilence(recordingID: id) } },
            onFailure: { message in Task { await self.captureFailed(message, recordingID: id) } }
        )
    }

    private func saveFailedRecordingStartup(
        _ record: DesktopRecordingStore.Record, file: PCMRecordingFile, failure: Error
    ) async throws {
        var failed = record
        failed.failure = closed ? "Recording cancelled when the app closed. Audio retained."
            : failure.localizedDescription
        do { _ = try file.finish() } catch {
            failed.failure = "\(failed.failure ?? "Recording failed.") "
                + "Audio finalization failed: \(error.localizedDescription)"
        }
        do { try await saveRecord(failed) } catch {
            throw DesktopHostError(message: "\(failed.failure ?? "Recording failed.") "
                + "History could not be saved: \(error.localizedDescription)")
        }
    }

    func stopCapture() throws -> StoppedRecording? {
        guard let active = recording else { return nil }
        recording = nil
        cancelRecordingTail()
        liveUpdates?.cancel()
        liveUpdates = nil
        let duration: TimeInterval
        do { duration = try DesktopHostRecordingStop.stop(active.capture, file: active.file) } catch {
            active.live?.cancel()
            throw error
        }
        return StoppedRecording(
            record: active.record, duration: duration, target: active.target, live: active.live,
            profile: active.profile, textOutput: active.textOutput
        )
    }

    func stopForSilence(recordingID: UUID) async {
        while busy {
            guard !closed, recording?.record.id == recordingID else { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard !closed, recording?.record.id == recordingID, recording?.handsFree == false else { return }
        beginBusyOperation()
        defer { finishBusyOperation() }
        await stopAndTranscribe()
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
