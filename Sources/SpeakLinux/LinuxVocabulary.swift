import Foundation
import SpeakDesktop
import CLinuxSupport

func linuxVocabularyEvent(_ event: Int32, payload: String, kind: Int, holder: LinuxEventContext) {
    holder.enqueueSettings {
        do {
            if event == 72 {
                let snapshot = try await holder.controller.vocabularyHistoryPresentation(payload)
                if snapshot.withCString({ jsti_vocabulary_set(2, $0, 0) }) != 0 {
                    LinuxHostPlatform.update("Correction results could not be displayed.", transcript: nil, state: -1)
                }
                return
            }
            let notice = event == 70 ? try await holder.controller.vocabularyEvent(kind: kind, payload: payload) : ""
            let preview = payload.hasPrefix("preview\t")
            let snapshot = preview ? notice : try await holder.controller.vocabularyPresentation(
                kind: kind, notice: notice, reload: event == 71
            )
            if snapshot.withCString({ jsti_vocabulary_set(Int32(kind), $0, preview ? 0 : 1) }) != 0 {
                LinuxHostPlatform.update("Vocabulary response could not be displayed. Reopen the editor.",
                                         transcript: nil, state: -1)
            }
        } catch {
            if error.localizedDescription.withCString({ jsti_vocabulary_set(Int32(kind), $0, 0) }) != 0 {
                LinuxHostPlatform.update(error.localizedDescription, transcript: nil, state: -1)
            }
        }
    }
}
