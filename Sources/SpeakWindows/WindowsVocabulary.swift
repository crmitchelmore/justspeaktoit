import Foundation
import SpeakDesktop
import CWindowsSupport

func windowsVocabularyEvent(_ event: Int32, payload: String, kind: Int, holder: WindowsEventContext) {
    holder.enqueueSettings {
        await holder.controller.nativeVocabularyEvent(event, payload: payload, kind: kind) { kind, text, applied in
            text.withCString { jsti_vocabulary_set(kind, $0, applied ? 1 : 0) } == 0
        }
    }
}
