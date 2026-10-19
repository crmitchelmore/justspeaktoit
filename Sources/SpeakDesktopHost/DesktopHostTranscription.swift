import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController {
    /// Output is the recording's own authority; imports and retries pass nil.
    package func transcribe( // swiftlint:disable:this function_body_length
        _ original: DesktopRecordingStore.Record, duration: TimeInterval, output: DesktopHostRecordingOutput<Platform>?,
        profile: DesktopProfileSession? = nil, azureEndpoint: String? = nil,
        input: DesktopHostRecordingInput? = nil
    ) async {
        // existing owned transcription orchestration; no behavior change.
        var record = original
        defer { capturedCleanup.removeValue(forKey: original.id) }
        if capturedCleanup[record.id] == nil {
            capturedCleanup[record.id] = captureCleanup(profile?.postProcessing ?? settings.postProcessing ?? .init())
        }
        cancellationRequested = false
        // The record's on-device model, a profile's or the app's, stays in use until this finishes.
        let localModel = beginLocalUse(record.modelIdentifier)
        defer { endLocalUse(localModel) }
        let session = profile ?? .defaults(
            modelIdentifier: record.modelIdentifier, postProcessing: settings.postProcessing ?? .init(),
            language: record.languageIdentifier
        ).capturingModulateFeatures(settings.configuration?.modulateBatchFeatures ?? .init())
        let keywords = batchKeywords(for: record.modelIdentifier, options: session.transcriptionOptions)
        let modulateFeatures = session.modulateBatchFeatures
        do {
            guard !closed else { throw CancellationError() }
            let key: String
            if let input { key = input.key } else { key = try transcriptionKey(for: record.modelIdentifier) }
            let audio = try await store.audioURL(for: record)
            guard !closed else { throw CancellationError() }
            try checkUploadSize(audio, model: record.modelIdentifier)
            update(transcribingStatus(for: record.modelIdentifier), state: 2)
            hud(record.id, .transcribing())
            let vocabulary: [String]
            if let input { vocabulary = input.vocabulary } else { vocabulary = try await vocabularyKeywords() }
            var request = DesktopHostTranscriptionRequest(
                audio: audio, model: record.modelIdentifier, key: key, duration: duration, language: session.language,
                keywords: keywords + vocabulary, azureEndpoint: input?.azureEndpoint ?? azureEndpoint
            )
            request.modulateFeatures = modulateFeatures
            noteKeywordLimitation(&record, keywords: request.keywords)
            let effects = self.effects
            let task = Task {
                try Task.checkCancellation()
                return try await effects.transcribe(request, with: self)
            }
            transcriptionTask = task
            defer { transcriptionTask = nil }
            // A Cancel while the audio was being found had no request to cancel yet.
            if cancellationRequested { task.cancel() }
            let result = try await task.value
            record = recordWithResult(result, replacing: record, skippedPolishReason: session.skippedPolishReason)
            try await saveRecord(record)
            record = try await applyVoiceCommands(record)
            record = try await applyVocabulary(record)
            record = await postProcess(record, options: session.postProcessing)
            if cancellationRequested { record.failure = "Cancelled. Completed transcription and audio retained." }
            try await saveRecord(record)
            // A response already received is still durably saved during shutdown,
            // but closing must never insert text or update a destroyed window.
            guard !closed else { return }
            present(record, output: output)
        } catch {
            if cancellationRequested {
                record.failure = record.result == nil
                    ? "Transcription cancelled. Audio retained."
                    : "Cancelled. Completed transcription and audio retained."
            } else {
                record.failure = error.localizedDescription
            }
            do { try await saveRecord(record) } catch {
                reportFailure("History could not be saved: \(error.localizedDescription)", for: record.id)
                return
            }
            let failure = record.failure ?? "Audio retained in History."
            reportFailure(failure, for: record.id, headline: "Transcription failed")
        }
    }

    func batchKeywords(for model: String, options: LiveClientOptions?) -> [String] {
        let snapshot = options ?? settings.configuration?.liveOptions ?? .init()
        return DesktopTranscription.provider(for: model)?.id == "assemblyai"
            ? snapshot.assemblyAIKeyterms : snapshot.keywords
    }

    private func noteKeywordLimitation(_ record: inout DesktopRecordingStore.Record, keywords: [String]) {
        guard let notice = DesktopTranscription.keywordLimitation(model: record.modelIdentifier) else { return }
        record.profileNotes?.removeAll { $0 == notice }
        guard !keywords.isEmpty else { return }
        record.profileNotes = (record.profileNotes ?? []) + [notice]
        update("Transcribing… " + notice, state: 2)
    }

    private func recordWithResult(
        _ result: TranscriptionResult, replacing original: DesktopRecordingStore.Record, skippedPolishReason: String?
    ) -> DesktopRecordingStore.Record {
        var record = original
        record.result = result
        record.failure = nil
        record.processedText = nil
        record.correctedText = nil
        record.lexiconSummary = nil
        record.lexiconDirectives = nil
        record.lexiconContextTags = nil
        record.postProcessingModelIdentifier = nil
        record.postProcessingFailure = skippedPolishReason
        record.livePolishResult = nil
        return record
    }

    /// Shows a saved record. Work finishing after `close()` never reaches the
    /// window: its record is already saved, and nothing is output.
    func present(_ record: DesktopRecordingStore.Record, output: DesktopHostRecordingOutput<Platform>?) {
        guard !closed else { return }
        selectedHistoryID = record.id
        transcriptVariant = .processed
        refreshHistory(selectRecord: true)
        transcript = record.displayText ?? ""
        var status = record.failure ?? "Saved to History. Select Copy to use the transcript."
        if let failure = record.postProcessingFailure {
            status = "Original transcript saved; post-processing failed. \(failure)"
        }
        var start = DesktopHostOutputStart.unavailable
        if let output, !transcript.isEmpty, record.failure == nil, record.postProcessingFailure == nil {
            start = beginOutput(transcript, output: output, recordID: record.id)
            if let started = start.status { status = started }
        }
        presentHUD(record, status: status, output: start)
        if selectedHistoryID == record.id {
            Platform.recordingState(0)
            Platform.historyPresentation(record, variant: .processed, status: status + profileContext(record))
        } else {
            // An active search keeps its rows; the result is still shown here.
            status += " This recording is hidden by the current History search."
            update(status + profileContext(record), transcript: transcript, state: 0)
        }
    }

    // existing owned cancellation dispatch across capture modes; no behavior change.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    package func cancelTranscription() {
        guard !closed else { return }
        if ownedDictation == nil, let admission = ownedDictationAdmission {
            cancellationRequested = true
            admission.operation.cancel()
            return
        }
        if let active = ownedDictation {
            cancellationRequested = true
            cancelRecordingTail()
            transcriptionTask?.cancel()
            voiceCommandTask?.cancel()
            postProcessingTask?.cancel()
            liveFinalisation?.cancel()
            requestOwnedDictationStop(requestID: active.id, reason: "Recording cancelled. Audio retained.")
            return
        }
        if ownedCaptureStartup != nil {
            requestOwnedStartupAbort()
            return
        }
        if let inspection = migrationInspectionWorker {
            inspection.cancel()
            update("Stopping backup inspection... No application data will be changed.", state: 2)
            return
        }
        if let export = migrationExportWorker {
            export.cancel()
            update("Stopping History backup... Existing files will be kept.", state: 2)
            return
        }
        if let cleanup = audioCleanupTask {
            cleanup.cancel()
            update("Stopping audio cleanup... Remaining audio and History will be kept.", state: 2)
            return
        }
        if historyDeletionInProgress {
            cancellationRequested = true
            update("Stopping History deletion… Remaining recordings will be kept.", state: 2)
            return
        }
        if let runID = handsFreeRun?.id {
            Task {
                guard self.handsFreeRun?.id == runID else { return }
                await self.disarmHandsFree()
            }
        } else if handsFreeMachine.isArmed {
            _ = handsFreeMachine.handle(.userDisarmed)
        }
        cancelOutput()
        guard busy else { return }
        cancellationRequested = true
        recordingTail?.task.cancel()
        transcriptionTask?.cancel()
        voiceCommandTask?.cancel()
        postProcessingTask?.cancel()
        liveFinalisation?.cancel()
        update("Cancelling… Saved audio and completed results will be retained.", state: 2)
    }
}
