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
        defer { active.capture.destroy() }
        var stopFailure: Error?
        do { try active.capture.stop() } catch { stopFailure = error }
        let duration: TimeInterval
        do { duration = try active.context.file.finish() } catch { active.live?.cancel(); throw error }
        if let stopFailure { active.live?.cancel(); throw stopFailure }
        return StoppedRecording(
            record: active.record, duration: active.context.file.isDigitalSilence ? 0 : duration,
            target: active.target, live: active.live, profile: active.profile, textOutput: active.textOutput
        )
    }
}
