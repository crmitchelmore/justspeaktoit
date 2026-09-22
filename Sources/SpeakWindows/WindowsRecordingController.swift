import Foundation
import SpeakCore
import SpeakDesktop
import SpeakWindowsPlatform
import CWindowsSupport

extension WindowsAppController {
    func startRecording(
        target: WindowsInsertionTarget?, deviceID: String, profile: DesktopProfileSession
    ) async throws {
        let key = try WindowsNative.apiKey(name: credentialIdentifier(for: profile.modelIdentifier))
        guard !key.isEmpty else { throw TranscriptionProviderError.apiKeyMissing }
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
            let context = WindowsCaptureContext(file: file, live: live) { message in
                Task { await self.captureFailed(message, recordingID: id) }
            }
            let native = try WindowsNative.createCapture(
                context: context, deviceID: deviceID, sampleRate: rate,
                frameMilliseconds: DesktopLiveTranscription.captureFrameMilliseconds(forID: profile.modelIdentifier)
            )
            do { try WindowsNative.checked { jsti_capture_start(native, $0, $1) } } catch {
                withExtendedLifetime(context) { jsti_capture_destroy(native) }
                throw error
            }
            recording = Recording(
                native: native, context: context, record: record, target: target, live: live, profile: profile
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
                throw WindowsNativeError(message: "\(failed.failure ?? "Recording failed.") "
                    + "History could not be saved: \(error.localizedDescription)")
            }
            throw startupFailure
        }
        update(profileRecordingStatus(profile), state: 1)
    }
}
