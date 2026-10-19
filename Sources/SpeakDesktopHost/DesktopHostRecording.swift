import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController {
    func startRecording(
        target: Platform.InsertionTarget?, deviceID: String, profile: DesktopProfileSession,
        textOutput: Platform.TextOutputOptions, trigger: HotKeySessionTrigger = .other,
        handsFree: DesktopHandsFreeRun<Platform>? = nil
    ) async throws {
        try await startRecording(.init(
            target: target, deviceID: deviceID, profile: profile, textOutput: textOutput,
            trigger: trigger, handsFree: handsFree, capturePolicy: nil
        ))
    }

    func startRecording(_ request: DesktopHostRecordingStart<Platform>) async throws {
        pauseConnectionPreWarming()
        connectionWarmCapture = nil
        let warmGeneration = connectionWarmGeneration
        cancelCorrectionObservation()
        let (target, deviceID, capturedProfile, textOutput, trigger, handsFree) = (
            request.target, request.deviceID, request.profile, request.textOutput, request.trigger, request.handsFree
        )
        if handsFree == nil, let capability = ownedDictationCapability {
            try await startOwnedDictation(
                target: target, deviceID: deviceID, profile: capturedProfile,
                textOutput: textOutput, trigger: trigger, capability: capability
            )
            return
        }
        let key = try requireCredentialOrLocalModel(capturedProfile.modelIdentifier)
        try requireAzureResource(forLive: capturedProfile.modelIdentifier)
        let polish = captureLivePolish(capturedProfile)
        var profile = capturedProfile
        if DesktopHostModels.provider(for: profile.modelIdentifier)?.id == "assemblyai" {
            let options = profile.transcriptionOptions ?? settings.configuration?.liveOptions ?? .desktopDefaults
            let hints = try await recognitionVocabulary()
            try Task.checkCancellation()
            guard !closed, handsFree == nil || handsFreeRun?.id == handsFree?.id else { throw CancellationError() }
            profile = profile.capturingTranscriptionOptions(options.includingPronunciationWords(hints.pronunciationWords))
        }
        // Holds a profile's or the app's on-device model while startup suspends;
        // the recording holds it once capture starts.
        let localModel = beginLocalUse(profile.modelIdentifier)
        defer { endLocalUse(localModel) }
        let id = UUID()
        capturedCleanup[id] = captureCleanup(profile.postProcessing)
        defer {
            if recording?.record.id != id { capturedCleanup.removeValue(forKey: id) }
        }
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
        try await beginLiveRecording(
            LiveRecordingStart(
                key: key, profile: profile, id: id, record: record, file: file, rate: rate,
                target: target, deviceID: deviceID, textOutput: textOutput, trigger: trigger, handsFree: handsFree,
                polish: polish, capturePolicy: request.capturePolicy, warmGeneration: warmGeneration
            )
        )
        guard !closed, recording?.record.id == id else { return }
        announceRecording(id, profile: profile, trigger: trigger)
    }

    /// Groups the parameters needed to start a live session and capture for an
    /// already-saved recording, keeping `beginLiveRecording` within the project's
    /// parameter-count limit without changing any argument semantics.
    private struct LiveRecordingStart {
        let key: String
        let profile: DesktopProfileSession
        let id: UUID
        let record: DesktopRecordingStore.Record
        let file: PCMRecordingFile
        let rate: Int
        let target: Platform.InsertionTarget?
        let deviceID: String
        let textOutput: Platform.TextOutputOptions
        let trigger: HotKeySessionTrigger
        let handsFree: DesktopHandsFreeRun<Platform>?
        let polish: DesktopHostLivePolishInput?
        let capturePolicy: DesktopHostCapturePolicy?
        let warmGeneration: UUID
    }

    /// Starts the live session and capture for an already-saved recording,
    /// saving a startup-failure record and rethrowing when either step fails.
    private func beginLiveRecording(_ start: LiveRecordingStart) async throws {
        let (key, profile, id, file, rate) = (
            start.key, start.profile, start.id, start.file, start.rate
        )
        var record = start.record
        let (target, deviceID, textOutput, trigger, handsFree) = (
            start.target, start.deviceID, start.textOutput, start.trigger, start.handsFree
        )
        var live: DesktopLiveSession?
        do {
            // The parent operation remains active through every metadata write,
            // so shutdown cannot return while startup is suspended here.
            try await saveRecord(record)
            guard !closed, handsFree == nil || handsFreeRun?.id == handsFree?.id else { throw CancellationError() }
            live = try await makeLiveSession(
                model: profile.modelIdentifier, key: key, id: id, language: profile.language,
                options: profile.transcriptionOptions, polish: start.polish
            )
            record = try await retainingLiveKeywordNotice(live?.keywordLimitation, in: record)
            guard !closed, handsFree == nil || handsFreeRun?.id == handsFree?.id else { throw CancellationError() }
            live?.start()
            let context = captureContext(start, live: live)
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
            if handsFree == nil {
                acknowledgeConnectionWarmCapture(
                    generation: start.warmGeneration, recordID: id,
                    model: profile.modelIdentifier, options: profile.postProcessing
                )
            }
            recording = Recording(
                capture: capture, context: context, file: file, handsFree: handsFree != nil,
                record: record, target: target, live: live, profile: profile,
                textOutput: textOutput, trigger: trigger
            )
            recordingCapturePolicy = start.capturePolicy.map { (recordID: id, value: $0) }
            if let live { monitorLive(live) }
            await notifyRecordingFeedback(id, handsFree: handsFree != nil, captureReady: true)
        } catch {
            await recordingFeedback?.cancelRecording(id)
            live?.cancel()
            try await saveStartupFailure(error, record: record, file: file)
            throw error
        }
    }

    private func retainingLiveKeywordNotice(
        _ notice: String?, in original: DesktopRecordingStore.Record
    ) async throws -> DesktopRecordingStore.Record {
        guard let notice, !(original.profileNotes ?? []).contains(notice) else { return original }
        var record = original
        record.profileNotes = (record.profileNotes ?? []) + [notice]
        try await saveRecord(record)
        return record
    }

    private func captureContext(_ start: LiveRecordingStart, live: DesktopLiveSession?) -> DesktopCaptureContext {
        let configuration: DesktopConfiguration?
        if let policy = start.capturePolicy {
            configuration = policy.configuration
        } else { configuration = settings.configuration }
        let silence = start.handsFree == nil && configuration?.enabled("silenceDetectionEnabled") == true
            ? DictationSilenceMonitor(
                threshold: configuration?.number("silenceThreshold") ?? DictationSilencePolicy.defaultThreshold,
                duration: configuration?.number("silenceDuration") ?? DictationSilencePolicy.defaultDuration
            ) : nil
        let id = start.id
        return DesktopCaptureContext(
            file: start.file, live: live, sampleRate: start.rate, silence: silence,
            onSilence: { Task { await self.stopForSilence(recordingID: id) } },
            onFailure: { message in Task { await self.captureFailed(message, recordingID: id) } }
        )
    }

    func saveStartupFailure(
        _ startupFailure: Error, record: DesktopRecordingStore.Record, file: PCMRecordingFile
    ) async throws {
        capturedCleanup.removeValue(forKey: record.id)
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
        recordingCapturePolicy = nil
        cancelRecordingTail()
        liveUpdates?.cancel()
        liveUpdates = nil
        active.live?.livePolish?.pause()
        let duration: TimeInterval
        do { duration = try DesktopHostRecordingStop.stop(active.capture, file: active.file) } catch {
            capturedCleanup.removeValue(forKey: active.record.id)
            active.live?.cancel()
            throw error
        }
        return StoppedRecording(
            record: active.record, duration: duration, target: active.target, live: active.live,
            profile: active.profile, textOutput: active.textOutput
        )
    }

    func stopForSilence(recordingID: UUID) async {
        if ownedDictation?.id == recordingID {
            await stopOwnedDictation(requestID: recordingID)
            return
        }
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

enum DesktopHostStartupRecord {
    static func failed(_ record: DesktopRecordingStore.Record, message: String) -> DesktopRecordingStore.Record {
        var record = record
        record.failure = message
        return record
    }
}

package enum DesktopHostOwnedFileStep: Sendable {
    case create, initialSave, finish, finalSave
}

/// The only writer handoff is a synchronous capability on the bounded relay drain.
package actor DesktopHostOwnedStartupFile {
    private let store: DesktopRecordingStore
    private let url: URL
    private let rate: Int
    private let before: @Sendable (DesktopHostOwnedFileStep) async -> Void
    private let afterFinish: @Sendable () throws -> Void
    private var file: PCMRecordingFile?
    private var finishAttempted = false
    private var capturedStatus: String?
    private var retained: DesktopRecordingStore.Record
    package private(set) var finishCount = 0
    package private(set) var audioFailure: String?
    package private(set) var historyFailure: String?

    package init(
        store: DesktopRecordingStore, directory: URL, record: DesktopRecordingStore.Record, rate: Int,
        before: @escaping @Sendable (DesktopHostOwnedFileStep) async -> Void = { _ in },
        afterFinish: @escaping @Sendable () throws -> Void = {}
    ) {
        self.store = store
        self.retained = record
        self.url = directory.appendingPathComponent(record.audioFilename)
        self.rate = rate
        self.before = before
        self.afterFinish = afterFinish
    }

    func prepare() async throws {
        await before(.create)
        do { file = try PCMRecordingFile(url: url, sampleRate: rate) } catch {
            audioFailure = "Recording file creation failed: \(error.localizedDescription)"
            throw error
        }
        await before(.initialSave)
        do { try await store.save(retained) } catch {
            throw DesktopHostError(message: "Initial History could not be saved: \(error.localizedDescription)")
        }
    }

    func dispose(message: String, captured: Bool = false) async -> Bool {
        let message = captured
            ? "Audio captured. No dictation or transcription was requested. Audio retained for retry." : message
        retained = DesktopHostStartupRecord.failed(retained, message: message)
        if !finishAttempted {
            finishAttempted = true
            if let file {
                await before(.finish)
                finishCount += 1
                do {
                    let duration = try file.finish()
                    if captured {
                        retained.recordedDuration = duration
                        capturedStatus = duration == 0 || file.isDigitalSilence
                            ? "No audio signal captured. No dictation was requested. Audio retained." : message
                    }
                    try afterFinish()
                } catch {
                    audioFailure = error.localizedDescription
                }
            }
        }
        if let capturedStatus { retained.failure = capturedStatus }
        if let audioFailure {
            retained.failure = "\(message) Audio finalization failed: \(audioFailure)"
        }
        await before(.finalSave)
        do {
            try await store.save(retained)
            historyFailure = nil
            return true
        } catch {
            historyFailure = "History could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    package func record() -> DesktopRecordingStore.Record { retained }

    func delivery(
        token: DesktopPressCaptureToken, identity: DesktopPressCaptureIdentity,
        before: @escaping @Sendable (Int) throws -> Void, failure: @escaping @Sendable (String) -> Void
    ) throws -> @Sendable (DesktopPressCapturePCMDelivery) -> Void {
        guard !finishAttempted, let file else { throw DesktopPressCaptureError.invalidPhase }
        let memory = try DesktopHostOwnedPCMMemory(sampleRate: rate)
        let context = DesktopCaptureContext(file: file, sampleRate: rate, onFailure: failure)
        return { delivery in
            guard delivery.token == token, delivery.identity == identity else {
                context.fail("Mismatched owned PCM delivery.")
                return
            }
            memory.deliver(delivery.data, before: {
                do { try before($0) } catch { context.fail(error.localizedDescription) }
            }, receive: { context.receive($0, count: $1) })
        }
    }
}
