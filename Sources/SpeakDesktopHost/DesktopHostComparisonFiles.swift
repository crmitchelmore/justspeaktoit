import Foundation
import SpeakCore
import SpeakDesktop

private struct ComparisonSampleSnapshot {
    let audio: URL
    let round: ModelComparisonRound
}

extension DesktopHostController {
    func runComparisonFiles(_ paths: [String], configuration: DesktopComparisonConfiguration) async throws {
        guard !paths.isEmpty, paths.count <= 32, let comparisons else {
            throw DesktopHostError(message: "Choose one to 32 audio samples.")
        }
        var prepared: [ComparisonSampleSnapshot] = []
        let mode: ModelComparisonInputMode = paths.count == 1 ? .file : .batch
        for path in paths {
            try Task.checkCancellation()
            let snapshot = try await prepareComparisonSample(path, mode: mode, configuration: configuration)
            try await comparisons.upsert(snapshot.round, isExecuting: true)
            comparisonOwnedRoundIDs.insert(snapshot.round.id)
            prepared.append(snapshot)
        }
        for snapshot in prepared {
            try Task.checkCancellation()
            comparisonSelection = snapshot.round.id
            comparisonStatus("Comparing \(snapshot.round.sample.name)… Raw requests only.")
            await refreshComparison()
            let round = try await DesktopComparisonRunner.file(
                audio: snapshot.audio, pending: snapshot.round, candidates: configuration.selected
            ) { audio, candidate, language in
                guard let key = configuration.keys[candidate.modelID] else {
                    throw DesktopHostError(message: "The comparison credential snapshot is missing.")
                }
                return try await self.effects.transcribeComparison(
                    .init(audio: audio, model: candidate.modelID, key: key,
                          duration: snapshot.round.sample.durationSeconds, language: language),
                    azureEndpoint: configuration.endpoint, with: self
                )
            }
            try await comparisons.upsert(round)
            guard comparisonGeneration == configuration.generation else { return }
            comparisonSelection = round.id
            await refreshComparison()
        }
        comparisonStatus("Comparison results saved. Review or rank the results below.")
    }

    private func prepareComparisonSample(
        _ path: String, mode: ModelComparisonInputMode, configuration: DesktopComparisonConfiguration
    ) async throws -> ComparisonSampleSnapshot {
        guard let comparisons else { throw DesktopHostError(message: "Comparison storage is unavailable.") }
        let source = URL(fileURLWithPath: path)
        try DesktopHostImport.validate(source)
        let sampleDirectory = comparisons.directory.appendingPathComponent("Samples")
        try Platform.preparePrivateDirectory(sampleDirectory)
        let snapshot = sampleDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(source.pathExtension)
        try FileManager.default.copyItem(at: source, to: snapshot)
        defer {
            do { try FileManager.default.removeItem(at: snapshot) } catch {
                let message = "An unused comparison import snapshot could not be removed: \(error.localizedDescription)"
                FileHandle.standardError.write(Data((message + "\n").utf8))
                comparisonStatus(message)
            }
        }
        try DesktopHostImport.validate(snapshot)
        let roundID = UUID()
        let audio = sampleDirectory.appendingPathComponent(roundID.uuidString + ".wav")
        let duration: TimeInterval
        if let canonical = try? NativePCM16WAVReader.canonicalDuration(at: snapshot) {
            try FileManager.default.copyItem(at: snapshot, to: audio)
            duration = canonical
        } else {
            duration = try await Platform.convertAudio(input: snapshot, output: audio)
        }
        guard let digest = Platform.comparisonDigest else {
            throw DesktopHostError(message: "Comparison SHA-256 is unavailable on this host.")
        }
        let sample = ModelComparisonSample(
            name: source.lastPathComponent, contentHash: try digest.sha256(ofFileAt: audio), durationSeconds: duration
        )
        let pending = interruptedRound(id: roundID, sample: sample, mode: mode, selected: configuration.selected)
        return ComparisonSampleSnapshot(audio: audio, round: pending)
    }
}
