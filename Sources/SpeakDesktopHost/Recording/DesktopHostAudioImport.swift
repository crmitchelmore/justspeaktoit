import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController {
    package func importAudio(path: String, modelIndex: Int) async {
        guard isReady, !busy, !closed, recording == nil,
              DesktopHostModels.all.indices.contains(modelIndex),
              !DesktopHostModels.isLive(DesktopHostModels.all[modelIndex].id),
              !DesktopHostModels.isLocalLive(DesktopHostModels.all[modelIndex].id) else { return }
        cancelOutput()
        guard selectModel(modelIndex) else { return }
        busy = true
        activeOperations += 1
        defer { busy = false; finishOperation() }
        do {
            try await playback.stopAndWait()
            guard !closed else { return }
            _ = try requireCredentialOrLocalModel(settings.model)
            let localModel = beginLocalUse(settings.model) // Held across the save until transcription ends.
            defer { endLocalUse(localModel) }
            let source = URL(fileURLWithPath: path)
            try DesktopHostImport.validate(source)
            let id = UUID()
            let filename = id.uuidString + "." + source.pathExtension
            let destination = directory.appendingPathComponent("History").appendingPathComponent(filename)
            try FileManager.default.copyItem(at: source, to: destination)
            var record = DesktopRecordingStore.Record(id: id, audioFilename: filename, modelIdentifier: settings.model)
            record.languageIdentifier = settings.configuration?.language
            try await saveRecord(record)
            if closed {
                var cancelled = record
                cancelled.failure = "Import cancelled when the app closed. Audio retained."
                try await saveRecord(cancelled)
                return
            }
            // An import has no recording hotkey, so it never outputs automatically.
            await transcribe(record, duration: 0, output: nil)
        } catch { update(error.localizedDescription, state: 0) }
    }
}
