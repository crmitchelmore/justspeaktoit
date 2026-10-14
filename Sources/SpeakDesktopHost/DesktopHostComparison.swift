import Foundation
import SpeakCore
import SpeakDesktop

package struct DesktopComparisonPresentation: Sendable {
    package let models: String
    package let rounds: String
    package let detail: String
    package let busy: Bool
    package let recording: Bool
    package let selected: String
    package let judgeable: Bool
    package var sync = DesktopComparisonSyncControls()
    package var references = ""
    package var reference = ""
    package var batch = DesktopComparisonBatchControls()
}

package struct DesktopHostComparisonCapture {
    let capture: any DesktopRecordingCapture
    let file: PCMRecordingFile
}

struct DesktopComparisonConfiguration {
    let selected: [DesktopComparisonCandidate]
    let keys: [String: String]
    let language: String?
    let endpoint: String
    let deviceID: String
    let generation: UUID
}

final class DesktopHostComparisonClosingCapture: @unchecked Sendable {
    let active: DesktopHostComparisonCapture
    init(_ active: DesktopHostComparisonCapture) { self.active = active }
    func finish() async throws -> TimeInterval {
        try await Task.detached {
            try DesktopHostRecordingStop.stop(self.active.capture, file: self.active.file)
        }.value
    }
    func stop() {
        do { _ = try DesktopHostRecordingStop.stop(active.capture, file: active.file) } catch {
            FileHandle.standardError.write(Data("Comparison capture cleanup: \(error.localizedDescription)\n".utf8))
        }
    }
}

extension DesktopHostController {
    package func openComparison() async {
        comparisonVisible = true
        do {
            _ = try await loadComparisonStore()
            await refreshComparison()
        } catch {
            guard !closed else { return }
            comparisonStatus("Could not open comparisons: \(error.localizedDescription)")
            Platform.comparisonPresentation(.init(
                models: "", rounds: "", detail: comparisonNotice, busy: false, recording: false,
                selected: "", judgeable: false
            ))
        }
    }

    package func selectComparison(_ identifier: String) async {
        comparisonSelection = UUID(uuidString: identifier)
        comparisonReference = nil
        await refreshComparison()
    }

    package func comparisonEvent(_ event: Int32, text: String, index: Int32) async {
        if await comparisonSupplementEvent(event, text: text, index: index) {
            await refreshComparison()
            return
        }
        switch event {
        case 100: await openComparison()
        case 101: await selectComparison(text)
        case 102, 103: await startComparison(text, live: event == 103)
        case 104: requestComparisonStop()
        case 105: await cancelComparison()
        case 106: await judgeComparison(text)
        case 107, 126, 127: await comparisonExportEvent(event, text: text, index: index)
        case 108: await playComparison(text)
        default: break
        }
        await refreshComparison()
    }

    private func startComparison(_ payload: String, live: Bool) async {
        guard !Task.isCancelled else { return }
        guard !closed, !busy, recording == nil, comparisonCapture == nil,
              comparisonTask == nil, comparisonFinalization == nil, comparisonBatch == nil else {
            comparisonStatus("Finish or cancel the current recording or comparison first.")
            return
        }
        busy = true
        activeOperations += 1
        let generation = UUID()
        comparisonGeneration = generation
        var transferred = false
        defer {
            if !transferred {
                if comparisonGeneration == generation { comparisonGeneration = UUID() }
                busy = false
                finishOperation()
            }
        }
        do {
            await openComparison()
            guard !closed, !Task.isCancelled, comparisonVisible,
                  comparisonGeneration == generation, comparisons != nil else { return }
            let lines = payload.components(separatedBy: "\n")
            guard lines.count >= 2 else { throw DesktopHostError(message: "Invalid comparison request.") }
            let language = lines[0].isEmpty ? nil : lines[0]
            cancelOutput()
            try await playback.stopAndWait()
            guard !closed, !Task.isCancelled, comparisonVisible, comparisonGeneration == generation else { return }
            let configuration = try comparisonAdmission(
                lines[1].components(separatedBy: "\t"), live: live, language: language, generation: generation
            )
            comparisonLanguage = language
            let paths = Array(lines.dropFirst(2))
            launchComparison(configuration, live: live, paths: paths)
            transferred = true
            await refreshComparison()
        } catch { comparisonStatus("Comparison could not start: \(error.localizedDescription)") }
    }

    func launchComparison(
        _ configuration: DesktopComparisonConfiguration, live: Bool, paths: [String],
        sample: ComparisonSampleSnapshot? = nil
    ) {
        comparisonTask = Task {
            do {
                if live {
                    try await self.startComparisonCapture(configuration)
                } else if let sample {
                    try await self.runComparisonSample(sample, configuration: configuration)
                } else {
                    try await self.runComparisonFiles(paths, configuration: configuration)
                }
            } catch {
                if self.comparisonGeneration == configuration.generation {
                    self.comparisonStatus("Comparison stopped: \(error.localizedDescription)")
                    self.comparisonLive?.cancel()
                    self.comparisonLive = nil
                    self.comparisonBatch = nil
                }
            }
            if self.comparisonGeneration == configuration.generation {
                if self.comparisonCapture == nil {
                    await self.releaseComparisonFileExecution()
                }
                self.comparisonTask = nil
                if self.comparisonCapture == nil { self.busy = false }
                self.finishOperation()
                await self.refreshComparison()
            }
        }
    }

    private func startComparisonCapture(_ configuration: DesktopComparisonConfiguration) async throws {
        let generation = configuration.generation
        let lanes = try configuration.selected.map { candidate in
            guard let route = LiveTranscriptionRouting.route(for: candidate.modelID),
                  let client = effects.makeLiveClient(
                    model: candidate.modelID, key: configuration.keys[candidate.modelID] ?? "",
                    language: configuration.language, azureEndpoint: configuration.endpoint
                  ) else { throw DesktopTranscriptionError.unsupportedModel }
            return DesktopComparisonLive.Lane(candidate: candidate, client: client, sampleRate: route.sampleRate)
        }

        let fanOut = try DesktopComparisonLive(lanes: lanes)
        comparisonLive = fanOut
        comparisonStatus("Preparing comparison models… Microphone is not recording yet.")
        await refreshComparison()
        try await fanOut.prepare()
        try Task.checkCancellation()
        guard !closed, comparisonGeneration == generation, let comparisons else { throw CancellationError() }
        let samples = comparisons.directory.appendingPathComponent("Samples")
        try Platform.preparePrivateDirectory(samples)
        let roundID = UUID()
        let file = try PCMRecordingFile(
            url: samples.appendingPathComponent(roundID.uuidString + ".wav"), sampleRate: fanOut.captureSampleRate
        )
        let pending = interruptedRound(
            id: roundID, sample: .init(name: file.url.lastPathComponent, contentHash: nil, durationSeconds: 0),
            mode: .streaming, selected: configuration.selected
        )
        try await comparisons.upsert(pending, isExecuting: true)
        comparisonOwnedRoundIDs.insert(pending.id)
        comparisonPending = pending
        let context = DesktopCaptureContext(file: file, comparison: fanOut) { [weak self] message in
            Task { await self?.comparisonCaptureFailed(message, generation: generation) }
        }
        let capture = try effects.makeCapture(
            context: context, deviceID: configuration.deviceID,
            sampleRate: fanOut.captureSampleRate, frameMilliseconds: 100
        )
        let deadline = ContinuousClock.now.advanced(by: DesktopComparisonLive.maximumCaptureDuration)
        do { try fanOut.beginCapture(); try capture.start() } catch { capture.destroy(); throw error }
        comparisonCapture = DesktopHostComparisonCapture(capture: capture, file: file)
        comparisonSelection = pending.id
        startComparisonUpdates(generation: generation, deadline: deadline)
        comparisonStatus("Comparing one microphone capture. Stop to judge the raw results.")
    }

    func isComparisonCapturing(_ generation: UUID) -> Bool {
        !closed && comparisonGeneration == generation && comparisonCapture != nil
    }

    package func transcribeComparison(
        _ request: DesktopHostTranscriptionRequest, endpoint: String
    ) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        try checkUploadSize(request.audio, model: request.model)
        if DesktopHostModels.isLocal(request.model) {
            let held = beginLocalUse(request.model)
            defer { endLocalUse(held) }
            return try await Platform.transcribeLocally(
                request.audio, model: request.model, language: request.language, controller: self
            )
        }
        return try await DesktopTranscription.transcribe(
            audioURL: request.audio, model: request.model, apiKey: request.key,
            duration: request.duration, language: request.language,
            azureEndpoint: endpoint, staging: uploadStaging
        )
    }

    private func comparisonCaptureFailed(_ message: String, generation: UUID) async {
        guard comparisonGeneration == generation else { return }
        await cancelComparison()
        guard comparisonGeneration == generation else { return }
        comparisonStatus("Comparison microphone failed: \(message). Audio and recovery results were retained.")
        await refreshComparison()
    }

    func interruptedRound(
        id: UUID, sample: ModelComparisonSample, mode: ModelComparisonInputMode,
        selected: [DesktopComparisonCandidate]
    ) -> ModelComparisonRound {
        let entries = selected.map {
            var entry = $0.entry()
            entry.errorDescription = "Comparison interrupted before completion. Audio retained locally."
            return entry
        }
        return ModelComparisonRound(
            id: id, inputMode: mode, sample: sample, language: comparisonLanguage,
            originPlatform: Platform.displayName.lowercased(), entries: entries,
            blindOrder: ModelComparisonRound.makeBlindOrder(for: entries)
        )
    }

    private func playComparison(_ identifier: String) async {
        guard !closed, !busy, recording == nil, let id = UUID(uuidString: identifier), let comparisons else { return }
        do {
            let rounds = await comparisons.rounds()
            guard let round = rounds.first(where: { $0.id == id }) else {
                throw DesktopHostError(message: "This comparison is no longer available.")
            }
            let file = comparisons.directory.appendingPathComponent("Samples")
                .appendingPathComponent(id.uuidString + ".wav")
            try playback.play(recordID: id, path: file.path, knownDuration: round.sample.durationSeconds)
        } catch { comparisonStatus("Comparison playback failed: \(error.localizedDescription)") }
    }

    package func cancelComparison() async {
        playback.stop(announcing: false)
        comparisonAdmissionTask?.cancel()
        if comparisonTask == nil, comparisonCapture == nil, comparisonFinalization == nil {
            comparisonGeneration = UUID()
        }
        discardComparisonBatch()
        comparisonOperations.cancelAll()
        comparisonTask?.cancel()
        comparisonFinalization?.cancel()
        comparisonLive?.cancel()
        if comparisonCapture != nil { await stopComparison() }
    }

    private func judgeComparison(_ payload: String) async {
        let lines = payload.components(separatedBy: "\n")
        do {
            guard !busy, !closed else {
                throw DesktopHostError(message: "Finish or cancel the comparison before judging its results.")
            }
            guard lines.count == 2, let id = UUID(uuidString: lines[0]), let comparisons else {
                throw DesktopHostError(message: "Select a saved comparison to judge.")
            }
            guard comparisonBatch?.queuedIDs.contains(id) != true else {
                throw DesktopHostError(
                    message: "This sample is queued. Judge the current round, then choose Next file."
                )
            }
            let values = lines[1].components(separatedBy: ",")
            let ranks = values.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard ranks.count == values.count else { throw DesktopHostError(message: "Enter comma-separated ranks.") }
            try await comparisons.judge(id: id, ranksInBlindOrder: ranks)
            comparisonSync?.changed()
            comparisonSelection = id
            await refreshComparison()
        } catch { comparisonStatus("Ranking was not saved: \(error.localizedDescription)") }
    }

    package func refreshComparison() async {
        guard !closed, comparisonVisible, let comparisons else { return }
        comparisonPresentationRevision &+= 1
        let presentationRevision = comparisonPresentationRevision
        let rounds = await comparisons.rounds()
        let round = comparisonPreview(rounds.first { $0.id == comparisonSelection } ?? rounds.first)
        let queued = round.map { comparisonBatch?.queuedIDs.contains($0.id) == true } ?? false
        let state = DesktopComparisonRoundPresentation(round: round, busy: busy || queued)
        comparisonSelection = round?.id
        let reference = round.flatMap { current in
            current.entriesInBlindOrder.first { $0.id == comparisonReference }
                ?? current.entriesInBlindOrder.first { !$0.didFail }
                ?? current.entriesInBlindOrder.first
        }
        comparisonReference = reference?.id
        let selectedModels = await comparisons.selectedModelIDs()
        playback.stop(unless: round?.id ?? UUID())
        let rows = rounds.map { "\($0.id.uuidString)\t\(DesktopHostModels.uiText($0.sample.name))" }
            .joined(separator: "\n")
        var detail = comparisonNotice + "\n\n"
            + "Choose at least two File/Batch models; Live supports two to eight on one microphone.\n"
            + "Raw transcripts only. No insertion, post-processing or History changes.\n"
        detail += comparisonBatchNotice(queued: queued)
        if let round {
            detail += await comparisonRoundDetail(round, state: state, reference: reference)
        }
        detail += "\n" + ModelComparisonExport.scoreboardMarkdown(rounds: rounds)
        let sync = await comparisonSyncPresentation()
        guard !closed, comparisonVisible, presentationRevision == comparisonPresentationRevision else { return }
        let (models, unavailable) = comparisonModelPresentation(selectedModels: selectedModels)
        if models.isEmpty {
            detail = "No comparison models are ready. Add API keys in Settings or prepare a local model; "
                + "specific reasons are below.\n\n" + detail
        }
        if !unavailable.isEmpty {
            detail += "\nUnavailable comparison models (not selectable):\n" + unavailable.joined(separator: "\n")
        }
        detail += "\n" + sync.status
        Platform.comparisonPresentation(.init(
            models: models, rounds: rows, detail: detail, busy: busy, recording: comparisonCapture != nil,
            selected: round?.id.uuidString ?? "", judgeable: state.judgeable,
            sync: sync.controls,
            references: round?.entriesInBlindOrder.map {
                "\($0.id.uuidString)\tResult \(round?.blindLabel(for: $0.id) ?? "")"
            }.joined(separator: "\n") ?? "",
            reference: reference?.id.uuidString ?? "",
            batch: comparisonBatchControls(round: round)
        ))
    }

    func comparisonStatus(_ message: String) {
        comparisonNotice = message
        update(message)
    }

    private func comparisonPreview(_ saved: ModelComparisonRound?) -> ModelComparisonRound? {
        guard comparisonCapture != nil, let pending = comparisonPending, let live = comparisonLive else { return saved }
        do {
            return try DesktopComparisonRunner.completing(pending, entries: live.snapshot(), sample: pending.sample)
        } catch {
            comparisonStatus("Comparison preview failed: \(error.localizedDescription)")
            return saved
        }
    }
}
