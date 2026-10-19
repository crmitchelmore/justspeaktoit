import Foundation
import SpeakCore
import SpeakDesktop

/// Pastes a transcript just captured on an iPhone or Apple Watch at the
/// cursor when iCloud sync brings it here, under the macOS rules in
/// `RemoteTranscriptArrival`: opt-in only, phone or watch captures only,
/// never an entry this host already had, and only within the freshness
/// window. It never interrupts a dictation, and it uses the saved text output
/// with the field focused when the arrival is applied, so Clipboard only
/// copies instead. With several arrivals in one sync, only the newest is
/// pasted; the rest stay in History.
extension DesktopHostController {
    typealias RemoteArrival = (alert: RemoteTranscriptArrival.Alert, recordID: UUID, createdAt: Date)

    func remoteArrival(
        _ record: DesktopRecordingStore.Record, isNew: Bool, now: Date = Date()
    ) -> RemoteArrival? {
        guard let origin = record.originPlatform else { return nil }
        let decision = RemoteTranscriptArrival.decide(.init(
            originPlatform: origin, createdAt: record.createdAt, text: record.displayText ?? "",
            isNewToThisMac: isNew,
            autoPasteEnabled: settings.configuration?.pasteRemoteTranscriptsAtCursor ?? false
        ), now: now)
        guard case .pasteAtCursor(let alert) = decision else { return nil }
        return (alert, record.id, record.createdAt)
    }

    func pasteRemoteArrival(_ arrival: RemoteArrival) async {
        guard remoteArrivalPasteAllowed, let options = remoteArrivalTextOutput else { return }
        let target: Platform.InsertionTarget?
        if Platform.requiresInsertionTarget(options) {
            target = try? await effects.captureInsertionTarget()
        } else { target = nil }
        // Capturing the field suspends; a dictation may have started meanwhile.
        guard remoteArrivalPasteAllowed else { return }
        let start = beginOutput(
            arrival.alert.transcript, output: .init(options: options, target: target), recordID: arrival.recordID
        )
        update(Self.remoteArrivalStatus(arrival.alert, start: start))
    }

    private var remoteArrivalPasteAllowed: Bool {
        !closed && settings.configuration?.pasteRemoteTranscriptsAtCursor == true && recording == nil
            && handsFreeRun == nil && ownedDictation == nil && ownedCaptureStartup == nil
            && outputSlot.task == nil
    }

    private var remoteArrivalTextOutput: Platform.TextOutputOptions? {
        if let saved = settings.textOutput { return saved }
        guard let platform = Platform.self as? any DesktopHostDefaultTextOutputPlatform.Type else { return nil }
        return Self.defaultTextOutput(of: platform) as? Platform.TextOutputOptions
    }

    private static func defaultTextOutput<P: DesktopHostDefaultTextOutputPlatform>(of _: P.Type) -> Any {
        P.defaultTextOutput
    }

    static func remoteArrivalStatus(
        _ alert: RemoteTranscriptArrival.Alert, start: DesktopHostOutputStart
    ) -> String {
        switch start {
        case .inserting: return "\(alert.title): pasting at the cursor…"
        case .copying: return "\(alert.title): copying to the clipboard…"
        case .busy: return "\(alert.title): saved in History; an earlier output is still finishing."
        case .unavailable: return "\(alert.title): saved in History; no text field was focused to paste into."
        }
    }
}
