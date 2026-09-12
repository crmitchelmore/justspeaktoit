import AppKit
import Foundation
import SpeakCore
import UniformTypeIdentifiers

/// File and Batch input: import audio and run it through every selected
/// model, one round per file.
extension CompareModelsController {
    func chooseFiles() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = mode == .batch
        panel.canChooseDirectories = false
        panel.message = mode == .batch
            ? "Choose audio files to compare as consecutive rounds"
            : "Choose an audio file to compare"
        guard await panel.begin() == .OK else { return }
        await runFiles(panel.urls)
    }

    func runFiles(_ urls: [URL]) async {
        guard !urls.isEmpty, phase == .idle else { return }
        queuedFiles = Array(urls.dropFirst())
        await runFile(urls[0])
    }

    func runFile(_ url: URL) async {
        guard canStart else {
            errorMessage = ComparisonRunError.noUsableModels.localizedDescription
            return
        }
        let generation = UUID()
        runID = generation
        phase = .transcribing
        errorMessage = nil
        liveTranscripts = [:]
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let sample: ModelComparisonSample
        do {
            sample = try await Task.detached(priority: .userInitiated) {
                try ComparisonFileRunner.sample(for: url)
            }.value
            guard runID == generation else { return }
        } catch {
            guard runID == generation else { return }
            queuedFiles = []
            phase = .idle
            errorMessage = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
            return
        }
        let selection = selectedUsableCandidates
        let placeholders = selection.map {
            ModelComparisonEntry(
                modelID: $0.modelID, modelDisplayName: $0.displayName, providerDisplayName: $0.providerDisplayName
            )
        }
        let roundMode: ModelComparisonInputMode = mode == .batch || !queuedFiles.isEmpty ? .batch : .file
        var round = makeRound(entries: placeholders, mode: roundMode, sample: sample)
        currentRound = round
        statusMessage = "Transcribing \(sample.name) with \(selection.count) models…"
        let request = ComparisonFileRunner.Request(
            fileURL: url,
            durationSeconds: sample.durationSeconds,
            language: environment.settings.preferredModelLanguage,
            localeIdentifier: environment.settings.resolvedPreferredLocaleIdentifier
        )
        let idsByModel = Dictionary(uniqueKeysWithValues: placeholders.map { ($0.modelID, $0.id) })
        let task = Task { [fileRunner] in
            await fileRunner.run(request, candidates: selection) { [weak self] entry in
                guard self?.runID == generation, let id = idsByModel[entry.modelID] else { return }
                self?.liveTranscripts[id] = entry.didFail ? "" : entry.transcript
            }
        }
        fileTask = task
        let entries = await task.value
        guard runID == generation else { return }
        fileTask = nil
        // Keep the placeholder ids so the blind order drawn up front holds.
        round.entries = entries.map { Self.rekeyed($0, idsByModel: idsByModel) }
        beginJudging(round)
    }

    private static func rekeyed(_ entry: ModelComparisonEntry, idsByModel: [String: UUID]) -> ModelComparisonEntry {
        guard let id = idsByModel[entry.modelID] else { return entry }
        return ModelComparisonEntry(
            id: id,
            modelID: entry.modelID,
            modelDisplayName: entry.modelDisplayName,
            providerDisplayName: entry.providerDisplayName,
            transcript: entry.transcript,
            errorDescription: entry.errorDescription,
            timeToFirstPartialMs: entry.timeToFirstPartialMs,
            timeToFinalMs: entry.timeToFinalMs,
            estimatedCostUSD: entry.estimatedCostUSD
        )
    }
}
