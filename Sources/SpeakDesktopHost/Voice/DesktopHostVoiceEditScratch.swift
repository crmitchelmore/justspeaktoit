import Foundation
import SpeakDesktop

extension DesktopHostController {
    func voiceEditScratch() async throws -> DesktopVoiceEditScratch {
        guard !closed else { throw CancellationError() }
        if let scratch = voiceEdit.scratchOwner { return scratch }
        let base = directory.appendingPathComponent("VoiceEdit-v2", isDirectory: true)
        let opening: (id: UUID, task: Task<DesktopVoiceEditScratch, Error>)
        if let pending = voiceEdit.scratchOpening {
            opening = pending
        } else {
            opening = (UUID(), Task.detached {
                try Platform.preparePrivateDirectory(base)
                return try DesktopVoiceEditScratch(preparedDirectory: base)
            })
            voiceEdit.scratchOpening = opening
        }
        defer {
            if voiceEdit.scratchOpening?.id == opening.id { voiceEdit.scratchOpening = nil }
        }
        let scratch = try await opening.task.value
        guard !closed else { throw CancellationError() }
        voiceEdit.scratchOwner = scratch
        voiceEdit.cleanupNotice = legacyVoiceEditScratchNotice()
        return scratch
    }

    func recoverVoiceEditScratch() async {
        guard !closed else { return }
        voiceEdit.cleanupNotice = legacyVoiceEditScratchNotice()
        let base = directory.appendingPathComponent("VoiceEdit-v2", isDirectory: true)
        guard FileManager.default.fileExists(atPath: base.path) else { return }
        do { _ = try await voiceEditScratch() } catch {
            let failure = "Private voice-edit audio cleanup needs attention: \(error.localizedDescription)"
            voiceEdit.cleanupNotice = [voiceEdit.cleanupNotice, failure].compactMap { $0 }.joined(separator: " ")
        }
    }

    private func legacyVoiceEditScratchNotice() -> String? {
        guard FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("VoiceEdit", isDirectory: true).path
        ) else { return nil }
        return "Legacy private voice-edit storage remains; that format cannot be automatically cleaned safely."
    }
}
