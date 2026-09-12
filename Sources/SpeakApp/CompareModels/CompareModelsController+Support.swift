import AppKit
import Foundation
import SpeakCore
import UniformTypeIdentifiers

/// Export, microphone ownership and capture bookkeeping.
extension CompareModelsController {
    // MARK: Export

    func exportJSON(rounds: [ModelComparisonRound]) -> String? {
        guard let data = try? ModelComparisonExport.json(rounds: rounds) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func exportMarkdown(rounds: [ModelComparisonRound]) -> String {
        if rounds.count == 1 {
            return ModelComparisonExport.markdown(round: rounds[0])
        }
        return ModelComparisonExport.markdown(rounds: rounds)
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "Copied to the clipboard."
    }

    func save(_ text: String, suggestedName: String, type: UTType) async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = suggestedName
        guard await panel.begin() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Saved \(url.lastPathComponent)."
        } catch {
            errorMessage = "Could not save: \(error.localizedDescription)"
        }
    }

    // MARK: Rounds

    func makeRound(
        entries: [ModelComparisonEntry],
        mode: ModelComparisonInputMode,
        sample: ModelComparisonSample
    ) -> ModelComparisonRound {
        ModelComparisonRound(
            inputMode: mode,
            sample: sample,
            language: environment.settings.preferredModelLanguage,
            originPlatform: "macos",
            entries: entries,
            blindOrder: ModelComparisonRound.makeBlindOrder(for: entries)
        )
    }

    // MARK: Microphone ownership

    /// Claims the shared capture so dictation cannot start (or tear the
    /// microphone down) while a comparison is listening (issue #673).
    func reserveCapture() -> Bool {
        guard environment.main.captureOwnership.reserve(.compareModels) else {
            isDictationBusy = true
            errorMessage = "Dictation is recording. Stop it before starting a comparison."
            return false
        }
        isDictationBusy = false
        captureOwnershipHeld = true
        return true
    }

    func releaseCapture() {
        guard captureOwnershipHeld else { return }
        environment.main.captureOwnership.release(.compareModels)
        captureOwnershipHeld = false
    }

    // MARK: Captures

    /// Keeps the microphone sample as a WAV beside the rounds so it can be
    /// re-run through other models in File mode later.
    func saveCapture(_ pcm16: Data, named name: String) throws {
        guard !pcm16.isEmpty,
              let wav = PCMWaveWriter.wavData(pcm: pcm16, sampleRate: ComparisonLiveFanOut.captureSampleRate) else {
            return
        }
        let url = store.samplesDirectory.appendingPathComponent(name, isDirectory: false)
        try wav.write(to: url, options: .atomic)
    }

    static func captureName(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return "Capture \(formatter.string(from: date))-\(UUID().uuidString).wav"
    }
}
