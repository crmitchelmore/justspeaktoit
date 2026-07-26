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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let corpus = try decoder.decode(
            LocalTranscriptionBenchmarkCorpus.self,
            from: Data(contentsOf: arguments.manifestURL)
        )
        try corpus.validate()

        let loadStart = ContinuousClock.now
        let runner: LocalBenchmarkEngineRunner
        switch arguments.engine {
        case .whisperKit:
            runner = try await WhisperKitBenchmarkRunner(model: arguments.model, modelRepo: arguments.modelRepo)
        case .transcribeCpp:
            runner = try TranscribeCppBenchmarkRunner(modelPath: arguments.model, backend: arguments.backend)
        case .streaming, .unknown:
            throw CLIError.invalidValue("Unsupported benchmark engine: \(arguments.engine.identifier)")
        }
        let coldLoadSeconds = durationSeconds(from: loadStart, to: ContinuousClock.now)

        let manifestDirectory = arguments.manifestURL.deletingLastPathComponent()
        let preparedCases = try corpus.cases.map { benchmarkCase -> (LocalTranscriptionBenchmarkCase, URL, WAVFile) in
            let audioURL = URL(
                fileURLWithPath: benchmarkCase.audioPath,
                relativeTo: manifestDirectory
            ).standardizedFileURL
            return (benchmarkCase, audioURL, try WAVFile(url: audioURL))
        }

        for _ in 0..<arguments.warmupIterations {
            for (benchmarkCase, audioURL, wav) in preparedCases {
                _ = try await runner.transcribe(audioURL: audioURL, wav: wav, language: benchmarkCase.language)
            }
        }

        var measurements: [LocalTranscriptionBenchmarkMeasurement] = []
        var failures: [LocalTranscriptionBenchmarkFailure] = []
        for iteration in 1...arguments.measuredIterations {
            for (benchmarkCase, audioURL, wav) in preparedCases {
                let resourcesBefore = ProcessResourceSnapshot.capture()
                let start = ContinuousClock.now
                do {
                    let transcript = try await runner.transcribe(
                        audioURL: audioURL,
                        wav: wav,
                        language: benchmarkCase.language
                    )
                    let wallSeconds = durationSeconds(from: start, to: ContinuousClock.now)
                    let resources = ProcessResourceSnapshot.capture().delta(from: resourcesBefore)
                    measurements.append(LocalTranscriptionBenchmarkMeasurement(
                        caseID: benchmarkCase.id,
                        iteration: iteration,
                        tags: benchmarkCase.tags,
                        referenceTranscript: benchmarkCase.referenceTranscript,
                        transcript: transcript,
                        audioSeconds: wav.durationSeconds,
                        wallSeconds: wallSeconds,
                        userCPUSeconds: resources.userCPUSeconds,
                        systemCPUSeconds: resources.systemCPUSeconds,
                        peakResidentMemoryMB: resources.peakResidentMemoryMB
                    ))
                } catch {
                    failures.append(LocalTranscriptionBenchmarkFailure(
                        caseID: benchmarkCase.id,
                        iteration: iteration,
                        message: error.localizedDescription
                    ))
                }
            }
        }

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
            measurements: measurements,
            failures: failures
        )
        try writeJSON(report, to: arguments.outputURL)
        printSummary(report.summary, label: runner.engine.identifier)
        if !failures.isEmpty { throw BenchmarkRunError.caseFailures(failures.count) }
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

enum BenchmarkRunError: Error, LocalizedError {
    case caseFailures(Int)

    var errorDescription: String? {
        switch self {
        case .caseFailures(let count): return "Benchmark completed with \(count) failed case(s); report was written."
        }
    }
}
