import AVFoundation
import Darwin
import Foundation
import MLX
import MLXAudioSTT

@main
struct VoxtralLocalQualification {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else {
            throw ProbeError.invalidArguments
        }
        let modelDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let audioURL = URL(fileURLWithPath: arguments[2])
        let reportURL = URL(fileURLWithPath: arguments[3])
        let audio = try readFixture(audioURL)
        Memory.cacheLimit = 128 * 1_024 * 1_024
        let started = ProcessInfo.processInfo.systemUptime
        let model = try VoxtralRealtimeModel.fromDirectory(modelDirectory)
        let loadSeconds = elapsed(since: started)
        print("Loaded supplied local model in \(loadSeconds) seconds; no download API used.")
        fflush(stdout)
        var runs: [[String: Any]] = []
        for iteration in 0..<2 {
            let runStart = ProcessInfo.processInfo.systemUptime
            var session: VoxtralRealtimeStreamSession? = model.makeStreamSession(maxTokens: 256)
            var firstPartialSeconds: Double?
            var steps: [[String: Any]] = []
            var textBeforeFinish = ""
            let chunkSamples = 1_600 // 100 ms, 16 kHz mono, supplied without artificial pacing.
            for offset in stride(from: 0, to: audio.count, by: chunkSamples) {
                let end = min(offset + chunkSamples, audio.count)
                let stepStart = ProcessInfo.processInfo.systemUptime
                let delta = session!.step(Array(audio[offset..<end]))
                if firstPartialSeconds == nil, !delta.text.isEmpty {
                    firstPartialSeconds = elapsed(since: runStart)
                }
                textBeforeFinish = session!.text
                steps.append([
                    "samples_fed": end,
                    "audio_seconds_fed": Double(end) / 16_000,
                    "step_seconds": elapsed(since: stepStart),
                    "delta": delta.text
                ])
            }
            let finishStart = ProcessInfo.processInfo.systemUptime
            let finishDelta = session!.finish()
            let finishSeconds = elapsed(since: finishStart)
            let final = session!.text
            let repeatedFinish = session!.finish()
            let afterFinishStep = session!.step([Float](repeating: 0, count: chunkSamples))
            let unchangedAfterSeal = session!.text == final
            let totalSeconds = elapsed(since: runStart)
            session = nil
            Memory.clearCache()
            runs.append([
                "iteration": iteration,
                "first_partial_seconds": firstPartialSeconds.map { $0 as Any } ?? NSNull(),
                "text_before_finish": textBeforeFinish,
                "finish_delta": finishDelta.text,
                "final_text": final,
                "finish_seconds": finishSeconds,
                "total_seconds": totalSeconds,
                "real_time_factor_unpaced": totalSeconds / (Double(audio.count) / 16_000),
                "repeated_finish_delta": repeatedFinish.text,
                "post_finish_step_delta": afterFinishStep.text,
                "sealed_text_unchanged": unchangedAfterSeal,
                "steps": steps,
                "rss_peak_bytes": peakRSS(),
                "mlx_peak_bytes": Memory.peakMemory,
                "mlx_active_after_session_release_bytes": Memory.activeMemory
            ])
            print("Iteration \(iteration): \(final); finish=\(finishSeconds)s; total=\(totalSeconds)s")
            fflush(stdout)
            let report: [String: Any] = [
                "expected_runtime_revision": "8d86630ade569728aaea3dc1a29fc44e2efa719b",
                "expected_model_revision": "fdebf7b2af834a1db4b8a3c99ab7480b333adf9e",
                "model_hashes_verified_by_probe": false,
                "provenance_requirement": "External model hash and resolved-dependency verification receipts required",
                "mode": "offline-directory; incremental 100ms chunks without wall-clock pacing",
                "fixture_expected_text": "The quick brown fox jumps over the lazy dog.",
                "sample_rate": 16_000,
                "audio_samples": audio.count,
                "audio_seconds": Double(audio.count) / 16_000,
                "load_seconds": loadSeconds,
                "runs": runs,
                "limitations": ["Synthetic fixture only", "No microphone or app integration", "No iOS acceptance"]
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: reportURL, options: .atomic)
        }
    }

    private static func readFixture(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate == 16_000,
              file.processingFormat.channelCount == 1,
              file.length > 0,
              file.length <= 16_000 * 15,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw ProbeError.invalidAudio }
        try file.read(into: buffer)
        guard let samples = buffer.floatChannelData?[0] else { throw ProbeError.invalidAudio }
        return Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
    }

    private static func elapsed(since start: TimeInterval) -> TimeInterval {
        ProcessInfo.processInfo.systemUptime - start
    }

    private static func peakRSS() -> Int64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int64(usage.ru_maxrss)
    }

    private enum ProbeError: Error {
        case invalidArguments
        case invalidAudio
    }
}
