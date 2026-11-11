import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController {
    func preflightComparisonSamples(
        _ paths: [String], mode: ModelComparisonInputMode, configuration: DesktopComparisonConfiguration
    ) async throws -> [DesktopComparisonImportPlan] {
        var plans: [DesktopComparisonImportPlan] = []
        do {
            for path in paths {
                try Task.checkCancellation()
                let source = URL(fileURLWithPath: path)
                try DesktopHostImport.validate(source)
                let sourceBytes = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                let id = UUID()
                let audioBytes = (try? NativePCM16WAVReader.canonicalDuration(at: source)) == nil
                    ? DesktopComparisonStaging.scratchBytes : sourceBytes
                let sample = ModelComparisonSample(
                    name: source.lastPathComponent, contentHash: String(repeating: "0", count: 64), durationSeconds: 0
                )
                let round = interruptedRound(id: id, sample: sample, mode: mode, selected: configuration.selected)
                let metadata = try DesktopComparisonImportBudget.metadataBytes(round)
                try comparisonStaging.reserve(
                    id: id, bytes: audioBytes + metadata + DesktopComparisonImportBudget.margin(round.entries.count)
                )
                plans.append(.init(source: source, id: id, sourceBytes: sourceBytes))
                await Task.yield()
            }
            return plans
        } catch {
            comparisonStaging.releaseOwners(Set(plans.map(\.id)))
            throw error
        }
    }

    func prepareComparisonSample(
        _ plan: DesktopComparisonImportPlan, mode: ModelComparisonInputMode,
        configuration: DesktopComparisonConfiguration
    ) async throws -> ComparisonSampleSnapshot {
        guard let comparisons else { throw DesktopHostError(message: "Comparison storage is unavailable.") }
        let scratch = try comparisonStaging.beginScratch()
        defer { comparisonStaging.endScratch(scratch) }
        let samples = comparisons.directory.appendingPathComponent("Samples")
        try Platform.preparePrivateDirectory(samples)
        let snapshot = samples.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(plan.source.pathExtension)
        let audio = samples.appendingPathComponent(plan.id.uuidString + ".wav")
        var ready = false
        defer {
            discardComparisonImport(snapshot)
            if !ready { discardComparisonImport(audio) }
        }
        try copyComparisonImport(plan.source, to: snapshot, maximumBytes: plan.sourceBytes)
        try DesktopHostImport.validate(snapshot)
        let duration: TimeInterval
        if let canonical = try? NativePCM16WAVReader.canonicalDuration(at: snapshot) {
            try copyComparisonImport(snapshot, to: audio, maximumBytes: plan.sourceBytes)
            duration = canonical
        } else {
            try reserveComparisonConversion(plan, mode: mode, configuration: configuration)
            duration = try await Platform.convertAudio(input: snapshot, output: audio)
        }
        try Task.checkCancellation()
        guard let digest = Platform.comparisonDigest else {
            throw DesktopHostError(message: "Comparison SHA-256 is unavailable on this host.")
        }
        let sample = ModelComparisonSample(
            name: plan.source.lastPathComponent, contentHash: try digest.sha256(ofFileAt: audio),
            durationSeconds: duration
        )
        let round = interruptedRound(id: plan.id, sample: sample, mode: mode, selected: configuration.selected)
        let bytes = try audio.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes > 0, bytes <= DesktopComparisonStaging.scratchBytes else {
            throw DesktopHostError(message: "The converted comparison sample exceeds the 25 MB safety limit.")
        }
        let budget = try DesktopComparisonImportBudget(round: round, audioBytes: bytes, staging: comparisonStaging)
        ready = true
        return ComparisonSampleSnapshot(audio: audio, round: round, budget: budget)
    }

    private func reserveComparisonConversion(
        _ plan: DesktopComparisonImportPlan, mode: ModelComparisonInputMode,
        configuration: DesktopComparisonConfiguration
    ) throws {
        let sample = ModelComparisonSample(
            name: plan.source.lastPathComponent, contentHash: String(repeating: "0", count: 64), durationSeconds: 0
        )
        let round = interruptedRound(id: plan.id, sample: sample, mode: mode, selected: configuration.selected)
        try comparisonStaging.reserve(
            id: plan.id, bytes: DesktopComparisonStaging.scratchBytes
                + DesktopComparisonImportBudget.metadataBytes(round)
                + DesktopComparisonImportBudget.margin(round.entries.count)
        )
    }

    private func copyComparisonImport(_ source: URL, to destination: URL, maximumBytes: Int) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw DesktopHostError(message: "The comparison snapshot could not be created.")
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var copied = 0
        while let chunk = try input.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation()
            guard chunk.count <= maximumBytes - copied else {
                throw DesktopHostError(message: "The audio grew after preflight. Choose the files again.")
            }
            try output.write(contentsOf: chunk)
            copied += chunk.count
        }
    }

    func discardComparisonImport(_ url: URL) {
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        } catch {
            let message = "Unused comparison snapshot cleanup failed: \(error.localizedDescription)"
            FileHandle.standardError.write(Data((message + "\n").utf8))
            comparisonStatus(message)
        }
    }
}
