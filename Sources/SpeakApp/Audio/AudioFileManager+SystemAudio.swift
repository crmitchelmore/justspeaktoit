import Foundation
import SpeakCore

extension AudioFileManager {
    func startSystemAudioCapture(
        source: AudioCaptureSource,
        owner: AudioRecordingOwner,
        directory preflightDirectory: URL?,
        liveFeed: SystemAudioLiveFeed?
    ) async throws -> RecordingStart {
        guard #available(macOS 14.2, *) else {
            throw SystemAudioCaptureError.unsupportedOS
        }
        let generation = UUID()
        systemCaptureGeneration = generation
        currentRecordingOwner = owner
        do {
            let directory: URL
            if let preflightDirectory {
                directory = preflightDirectory
            } else {
                directory = await MainActor.run { appSettings.recordingsDirectory }
            }
            guard systemCaptureGeneration == generation, !Task.isCancelled else { throw CancellationError() }
            let controller = SystemAudioCaptureController()
            let feed = liveFeed ?? SystemAudioLiveFeed(source: source)
            let started = try await controller.start(
                source: source,
                in: directory,
                liveFeed: feed,
                audioDeviceManager: audioDeviceManager,
                permissionsManager: permissionsManager
            )
            guard systemCaptureGeneration == generation, !Task.isCancelled else {
                await controller.cancel(deleteFile: true)
                throw CancellationError()
            }
            activeSystemCapture = controller
            setSystemMeterProvider { [weak controller] in controller?.currentMeterReading() }
            currentRecordingURL = started.url
            if owner != .dictation { lifecycleHandler?(.auxiliaryStarted) }
            return started
        } catch {
            if systemCaptureGeneration == generation {
                systemCaptureGeneration = nil
                currentRecordingOwner = nil
            }
            throw error
        }
    }

    func stopSystemAudioCaptureIfActive() async throws -> RecordingSummary? {
        guard #available(macOS 14.2, *),
              let controller = activeSystemCapture as? SystemAudioCaptureController else { return nil }
        let owner = currentRecordingOwner
        systemCaptureGeneration = nil
        activeSystemCapture = nil
        setSystemMeterProvider(nil)
        currentRecordingURL = nil
        currentRecordingOwner = nil
        let summary = try await controller.stop()
        if let owner, owner != .dictation { lifecycleHandler?(.auxiliaryEnded) }
        return summary
    }

    func cancelSystemAudioCaptureIfActive(deleteFile: Bool) async -> (handled: Bool, keptURL: URL?) {
        let hadPendingStart = systemCaptureGeneration != nil
        systemCaptureGeneration = nil
        guard #available(macOS 14.2, *),
              let controller = activeSystemCapture as? SystemAudioCaptureController else {
            if hadPendingStart { currentRecordingOwner = nil }
            return (hadPendingStart, nil)
        }
        let owner = currentRecordingOwner
        let url = currentRecordingURL
        activeSystemCapture = nil
        setSystemMeterProvider(nil)
        currentRecordingURL = nil
        currentRecordingOwner = nil
        await controller.cancel(deleteFile: deleteFile)
        if url != nil, let owner, owner != .dictation { lifecycleHandler?(.auxiliaryEnded) }
        return (true, deleteFile ? nil : RecordingFiles.keptRecording(at: url))
    }
}
