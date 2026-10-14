import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController where Platform: DesktopHostReadAloudPlatform {
    package func performVoiceEvent(
        _ event: DesktopHistoryEvent,
        imported: @escaping @Sendable (String, Result<String, Error>) -> Void
    ) async {
        switch event {
        case .voiceRead(let snapshot): await readVoiceSource(snapshot)
        case .voiceExport(let snapshot, let path): exportVoiceSource(snapshot, path: path)
        case .voiceImport(let path, let requestID):
            importVoiceText(path: path, requestID: requestID) { imported(requestID, $0) }
        case .voiceImportCancel(let requestID): cancelVoiceTextImport(requestID: requestID)
        case .voiceGenerate(let snapshot, let options): generateVoiceSource(snapshot, options: options)
        case .voiceGeneratedPlay(let identifier): playGeneratedVoice(identifier)
        case .voiceGeneratedExport(let identifier, let path): exportGeneratedVoice(identifier, path: path)
        default: update("That action is not a Voice Output action.")
        }
    }
}
