import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController {
    func startRecording(
        target: Platform.InsertionTarget?, deviceID: String, profile: DesktopProfileSession,
        textOutput: Platform.TextOutputOptions, trigger: HotKeySessionTrigger = .other,
        handsFree: DesktopHandsFreeRun<Platform>? = nil, profileNotice: String? = nil
    ) async throws {
        let rate = DesktopLiveTranscription.route(forID: profile.modelIdentifier)?.sampleRate
            ?? PCMRecordingFile.sampleRate
        let options = DesktopHostRecordingConfiguration(
            configuration: settings.configuration, azureEndpoint: azureResourceEndpoint(), sampleRate: rate
        )
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
        let file = try await makeRecordingFile(filename: filename, sampleRate: rate, id: id)
        var record = profileRecord(id: id, filename: filename, profile: profile)
        if let profileNotice { record.profileNotes = (record.profileNotes ?? []) + [profileNotice] }
        var live: DesktopLiveSession?
        do {
            // The parent operation remains active through every metadata write,
            // so shutdown cannot return while startup is suspended here.
            try await saveRecord(record)
            guard !closed, handsFree == nil || handsFreeRun?.id == handsFree?.id else { throw CancellationError() }
            live = try await makeLiveSession(
                model: profile.modelIdentifier, key: key, id: id, language: profile.language, options: options
            )
            guard !closed, handsFree == nil || handsFreeRun?.id == handsFree?.id else { throw CancellationError() }
            live?.start()
            let context = captureContext(
                file: file, live: live, id: id, handsFree: handsFree != nil, options: options
            )
            let capture = try makeRecordingCapture(
                context: context, deviceID: deviceID, model: profile.modelIdentifier, handsFree: handsFree
            )
            do { try capture.start() } catch {
                capture.destroy()
                throw error
            }
            recording = Recording(
                capture: capture, context: context, file: file, handsFree: handsFree != nil,
                record: record, target: target, live: live, profile: profile, options: options,
                textOutput: textOutput, trigger: trigger
            )
            if let live { monitorLive(live) }
            await notifyRecordingFeedback(id, handsFree: handsFree != nil, captureReady: true)
        } catch {
            await recordingFeedback?.cancelRecording(id)
            live?.cancel()
            try await saveStartupFailure(error, record: record, file: file)
            throw error
        }
        guard !closed, recording?.record.id == id else { return }
        announceRecording(id, profile: profile, trigger: trigger)
    }

    private func makeRecordingFile(filename: String, sampleRate: Int, id: UUID) async throws -> PCMRecordingFile {
        let audio = directory.appendingPathComponent("History").appendingPathComponent(filename)
        do { return try PCMRecordingFile(url: audio, sampleRate: sampleRate) } catch {
            await recordingFeedback?.cancelRecording(id)
            throw error
        }
    }

    private func makeRecordingCapture(
        context: DesktopCaptureContext, deviceID: String, model: String, handsFree: DesktopHandsFreeRun<Platform>?
    ) throws -> any DesktopRecordingCapture {
        if let handsFree { return DesktopHandsFreeUtteranceCapture(audio: handsFree.audio, context: context) }
        let rate = DesktopLiveTranscription.route(forID: model)?.sampleRate ?? PCMRecordingFile.sampleRate
        return try effects.makeCapture(
            context: context, deviceID: deviceID, sampleRate: rate,
            frameMilliseconds: DesktopLiveTranscription.captureFrameMilliseconds(forID: model)
        )
    }

    private func captureContext(
        file: PCMRecordingFile, live: DesktopLiveSession?, id: UUID, handsFree: Bool,
        options: DesktopHostRecordingConfiguration
    ) -> DesktopCaptureContext {
        let configuration = options.configuration
        let silence = !handsFree && configuration?.enabled("silenceDetectionEnabled") == true
            ? DictationSilenceMonitor(
                threshold: configuration?.number("silenceThreshold") ?? DictationSilencePolicy.defaultThreshold,
                duration: configuration?.number("silenceDuration") ?? DictationSilencePolicy.defaultDuration
            ) : nil
        return DesktopCaptureContext(
            file: file, live: live, sampleRate: options.sampleRate, silence: silence,
            onSilence: { Task { await self.stopForSilence(recordingID: id) } },
            onFailure: { message in Task { await self.captureFailed(message, recordingID: id) } }
        )
    }

    private func saveStartupFailure(
        _ startupFailure: Error, record: DesktopRecordingStore.Record, file: PCMRecordingFile
    ) async throws {
        // Always close the WAV, including failure before native allocation.
        var failed = record
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
            profile: active.profile, options: active.options, textOutput: active.textOutput
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
