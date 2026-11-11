import Foundation
import SpeakDesktop
import SpeakLinuxPlatform
import CLinuxSupport

func linuxVocabularyEvent(_ event: Int32, payload: String, kind: Int, holder: LinuxEventContext) {
    holder.enqueueSettings {
        await holder.controller.nativeVocabularyEvent(
            event, payload: payload, kind: kind, targetAvailability: { LinuxAtspiTarget.availability },
            present: { kind, text, applied in text.withCString { jsti_vocabulary_set(kind, $0, applied ? 1 : 0) } == 0 }
        )
    }
}
