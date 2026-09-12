import AVFoundation
import CryptoKit
import Foundation
import SpeakCore

/// Runs one audio file through every selected model concurrently and reports
/// each raw transcript as it lands (issue #1101).
///
/// Dispatch mirrors `TranscriptionManager.transcribeFile(at:)` but takes the
/// model per call instead of reading the app's configured model, and never
/// applies lexicon, live polish or LLM cleanup: the comparison measures the
/// speech model alone.
struct ComparisonFileRunner {
    let secureStorage: SecureAppStorage
    let openRouter: OpenRouterAPIClient

    struct Request: Sendable {
        let fileURL: URL
        let durationSeconds: Double
        let language: String?
        let localeIdentifier: String
    }

    func run(
        _ request: Request,
        candidates: [ComparisonCandidate],
        onEntry: @escaping @MainActor (ModelComparisonEntry) -> Void
    ) async -> [ModelComparisonEntry] {
        await withTaskGroup(of: ModelComparisonEntry.self) { group in
            for candidate in candidates {
                group.addTask {
                    let outcome = await BoundedOperation.run(timeout: .seconds(120)) {
                        await self.transcribe(request, with: candidate)
                    }
                    let entry: ModelComparisonEntry
                    if case .success(let result) = outcome {
                        entry = result
                    } else {
                        entry = ModelComparisonEntry(
                            modelID: candidate.modelID, modelDisplayName: candidate.displayName,
                            providerDisplayName: candidate.providerDisplayName,
                            errorDescription: "The model did not finish within its time limit.", timeToFinalMs: 120_000
                        )
                    }
                    await onEntry(entry)
                    return entry
                }
            }
            var entries: [ModelComparisonEntry] = []
            for await entry in group {
                entries.append(entry)
            }
            // Task completion order is arbitrary; keep the selection order.
            let order = Dictionary(uniqueKeysWithValues: candidates.enumerated().map { ($1.modelID, $0) })
            return entries.sorted { (order[$0.modelID] ?? .max) < (order[$1.modelID] ?? .max) }
        }
    }

    private func transcribe(_ request: Request, with candidate: ComparisonCandidate) async -> ModelComparisonEntry {
        var entry = ModelComparisonEntry(
            modelID: candidate.modelID,
            modelDisplayName: candidate.displayName,
            providerDisplayName: candidate.providerDisplayName
        )
        let started = Date()
        do {
            let result = try await transcribeFile(request, with: candidate)
            entry.timeToFinalMs = SessionLatencyMetrics.milliseconds(from: started, to: Date())
            entry.transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.estimatedCostUSD = Self.cost(
                reported: result.cost,
                modelID: candidate.modelID,
                durationSeconds: request.durationSeconds
            )
            if entry.transcript.isEmpty {
                entry.errorDescription = "The model returned an empty transcript"
            }
        } catch {
            entry.timeToFinalMs = SessionLatencyMetrics.milliseconds(from: started, to: Date())
            entry.errorDescription = error.localizedDescription
        }
        return entry
    }

    private func transcribeFile(_ request: Request, with candidate: ComparisonCandidate) async throws
        -> TranscriptionResult {
        switch candidate.engine {
        case .appleSpeechAnalyzer:
            guard #available(macOS 26.0, *) else { throw AppleLocalModelError.speechTranscriberUnavailable }
            return try await AppleSpeechAnalyzerTranscriber.transcribeFile(
                at: request.fileURL,
                localeIdentifier: request.localeIdentifier,
                engine: AppleSpeechAnalyzerEngine(modelID: candidate.modelID)
            )
        case .downloadedLocal:
            return try await LocalModelManager.shared.transcribeFile(
                at: request.fileURL,
                modelID: candidate.modelID,
                language: request.language
            )
        case .cloudBatch:
            if let provider = await TranscriptionProviderRegistry.shared.provider(forModel: candidate.modelID) {
                let apiKey = try await loadAPIKey(identifier: provider.metadata.apiKeyIdentifier)
                return try await provider.transcribeFile(
                    at: request.fileURL,
                    apiKey: apiKey,
                    model: candidate.modelID,
                    language: request.language
                )
            }
            return try await openRouter.transcribeFile(
                at: request.fileURL,
                model: candidate.modelID,
                language: request.language
            )
        case .sharedStreamingClient:
            throw ComparisonRunError.streamingOnly(candidate.displayName)
        }
    }

    private func loadAPIKey(identifier: String) async throws -> String {
        let apiKey: String
        do {
            apiKey = try await secureStorage.secret(identifier: identifier)
        } catch let error as SecureAppStorageError {
            if case .valueNotFound = error { throw TranscriptionProviderError.apiKeyMissing }
            throw error
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptionProviderError.apiKeyMissing
        }
        return apiKey
    }

    /// A provider-reported cost wins over the list-price estimate.
    static func cost(reported: ChatCostBreakdown?, modelID: String, durationSeconds: Double) -> Decimal? {
        if let reported, reported.totalCost > 0 { return reported.totalCost }
        return TranscriptionPricing.estimatedCostUSD(modelID: modelID, durationSeconds: durationSeconds)
    }

    // MARK: Sample identity

    static func sample(for url: URL) throws -> ModelComparisonSample {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 100 * 1_024 * 1_024 else {
            throw ComparisonRunError.captureFailed("Choose a recording smaller than 100 MB.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let audioFile = try AVAudioFile(forReading: url)
        let duration = audioFile.processingFormat.sampleRate > 0
            ? Double(audioFile.length) / audioFile.processingFormat.sampleRate
            : 0
        return ModelComparisonSample(name: url.lastPathComponent, contentHash: digest, durationSeconds: duration)
    }
}

enum ComparisonRunError: LocalizedError {
    case streamingOnly(String)
    case notStreamable(String)
    case noUsableModels
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .streamingOnly(let name):
            return "\(name) only supports live streaming"
        case .notStreamable(let name):
            return "\(name) cannot stream from the microphone"
        case .noUsableModels:
            return "Select at least two models that are ready to run"
        case .captureFailed(let reason):
            return reason
        }
    }
}
