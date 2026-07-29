import Foundation
import LocalTranscriptionBenchmarkKit

@main
struct LocalTranscriptionBenchmarkCommand {
    static func main() async {
        do {
            switch try ArgumentParser.parse(Array(CommandLine.arguments.dropFirst())) {
            case .run(let arguments):
                try await run(arguments)
            case .compare(let arguments):
                try compare(arguments)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run(_ arguments: RunArguments) async throws {
        let corpus = try loadCorpus(from: arguments.manifestURL)
        let loadStart = ContinuousClock.now
        let runner = try await makeRunner(for: arguments)
        let coldLoadSeconds = durationSeconds(from: loadStart, to: ContinuousClock.now)
        let preparedCases = try prepareCases(corpus, relativeTo: arguments.manifestURL)
        try await warmUp(runner, cases: preparedCases, iterations: arguments.warmupIterations)
        let results = await measure(runner, cases: preparedCases, iterations: arguments.measuredIterations)

        let report = LocalTranscriptionBenchmarkReport(
            engine: runner.engine,
            runtimeVersion: runner.runtimeVersion,
            runtimeCommit: runner.runtimeCommit,
            model: arguments.model,
            modelSource: arguments.modelSource,
            host: HostProfiler.current(),
            coldLoadSeconds: coldLoadSeconds,
            warmupIterations: arguments.warmupIterations,
            measuredIterations: arguments.measuredIterations,
            measurements: results.measurements,
            failures: results.failures
        )
        try writeJSON(report, to: arguments.outputURL)
        printSummary(report.summary, label: runner.engine.identifier)
        if !results.failures.isEmpty { throw BenchmarkRunError.caseFailures(results.failures.count) }
    }

    private static func loadCorpus(from url: URL) throws -> LocalTranscriptionBenchmarkCorpus {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let corpus = try decoder.decode(LocalTranscriptionBenchmarkCorpus.self, from: Data(contentsOf: url))
        try corpus.validate()
        return corpus
    }

    private static func makeRunner(for arguments: RunArguments) async throws -> LocalBenchmarkEngineRunner {
        switch arguments.engine {
        case .whisperKit:
            return try await WhisperKitBenchmarkRunner(model: arguments.model, modelRepo: arguments.modelRepo)
        case .transcribeCpp:
            return try TranscribeCppBenchmarkRunner(modelPath: arguments.model, backend: arguments.backend)
        case .streaming, .unknown:
            throw CLIError.invalidValue("Unsupported benchmark engine: \(arguments.engine.identifier)")
        }
    }

    private static func prepareCases(
        _ corpus: LocalTranscriptionBenchmarkCorpus,
        relativeTo manifestURL: URL
    ) throws -> [PreparedBenchmarkCase] {
        let manifestDirectory = manifestURL.deletingLastPathComponent()
        return try corpus.cases.map { benchmarkCase in
            let audioURL = URL(
                fileURLWithPath: benchmarkCase.audioPath,
                relativeTo: manifestDirectory
            ).standardizedFileURL
            return PreparedBenchmarkCase(
                benchmarkCase: benchmarkCase,
                audioURL: audioURL,
                wav: try WAVFile(url: audioURL)
            )
        }
    }

    private static func warmUp(
        _ runner: LocalBenchmarkEngineRunner,
        cases: [PreparedBenchmarkCase],
        iterations: Int
    ) async throws {
        for _ in 0..<iterations {
            for prepared in cases {
                _ = try await runner.transcribe(
                    audioURL: prepared.audioURL,
                    wav: prepared.wav,
                    language: prepared.benchmarkCase.language
                )
            }
        }
    }

    private static func measure(
        _ runner: LocalBenchmarkEngineRunner,
        cases: [PreparedBenchmarkCase],
        iterations: Int
    ) async -> BenchmarkResults {
        var results = BenchmarkResults()
        for iteration in 1...iterations {
            for prepared in cases {
                await measure(prepared, with: runner, iteration: iteration, results: &results)
            }
        }
        return results
    }

    private static func measure(
        _ prepared: PreparedBenchmarkCase,
        with runner: LocalBenchmarkEngineRunner,
        iteration: Int,
        results: inout BenchmarkResults
    ) async {
        let resourcesBefore = ProcessResourceSnapshot.capture()
        let start = ContinuousClock.now
        do {
            let transcript = try await runner.transcribe(
                audioURL: prepared.audioURL,
                wav: prepared.wav,
                language: prepared.benchmarkCase.language
            )
            let resources = ProcessResourceSnapshot.capture().delta(from: resourcesBefore)
            results.measurements.append(measurement(
                for: prepared,
                iteration: iteration,
                transcript: transcript,
                wallSeconds: durationSeconds(from: start, to: ContinuousClock.now),
                resources: resources
            ))
        } catch {
            results.failures.append(LocalTranscriptionBenchmarkFailure(
                caseID: prepared.benchmarkCase.id,
                iteration: iteration,
                message: error.localizedDescription
            ))
        }
    }

    private static func measurement(
        for prepared: PreparedBenchmarkCase,
        iteration: Int,
        transcript: String,
        wallSeconds: Double,
        resources: ProcessResourceSnapshot
    ) -> LocalTranscriptionBenchmarkMeasurement {
        LocalTranscriptionBenchmarkMeasurement(
            caseID: prepared.benchmarkCase.id,
            iteration: iteration,
            tags: prepared.benchmarkCase.tags,
            language: prepared.benchmarkCase.language,
            referenceTranscript: prepared.benchmarkCase.referenceTranscript,
            transcript: transcript,
            audioSeconds: prepared.wav.durationSeconds,
            wallSeconds: wallSeconds,
            userCPUSeconds: resources.userCPUSeconds,
            systemCPUSeconds: resources.systemCPUSeconds,
            peakResidentMemoryMB: resources.peakResidentMemoryMB
        )
    }

    private static func compare(_ arguments: CompareArguments) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let baseline = try decoder.decode(
            LocalTranscriptionBenchmarkReport.self,
            from: Data(contentsOf: arguments.baselineURL)
        )
        let candidate = try decoder.decode(
            LocalTranscriptionBenchmarkReport.self,
            from: Data(contentsOf: arguments.candidateURL)
        )
        let evidence = try decoder.decode(
            LocalTranscriptionAssessmentEvidence.self,
            from: Data(contentsOf: arguments.evidenceURL)
        )
        let decision = LocalTranscriptionAssessmentGate.evaluate(
            baseline: baseline,
            candidate: candidate,
            evidence: evidence
        )
        try writeJSON(decision, to: arguments.outputURL)
        print("decision: \(decision.status.rawValue)")
        decision.reasons.forEach { print("- \($0)") }
    }

    private static func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private static func durationSeconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Double {
        let components = start.duration(to: end).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static func printSummary(_ summary: LocalTranscriptionBenchmarkSummary, label: String) {
        print("\(label): WER \(percent(summary.wordErrorRate)), CER \(percent(summary.characterErrorRate))")
        print(String(format: "median %.3fs, RTF %.4f, peak RSS %.1f MB", summary.medianWallSeconds,
                     summary.medianRealTimeFactor, summary.peakResidentMemoryMB))
        print("cases \(summary.caseCount), failures \(summary.failureCount)")
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.2f%%", value * 100)
    }
}

private struct PreparedBenchmarkCase {
    let benchmarkCase: LocalTranscriptionBenchmarkCase
    let audioURL: URL
    let wav: WAVFile
}

private struct BenchmarkResults {
    var measurements: [LocalTranscriptionBenchmarkMeasurement] = []
    var failures: [LocalTranscriptionBenchmarkFailure] = []
}

enum BenchmarkRunError: Error, LocalizedError {
    case caseFailures(Int)

    var errorDescription: String? {
        switch self {
        case .caseFailures(let count): return "Benchmark completed with \(count) failed case(s); report was written."
        }
    }
}
