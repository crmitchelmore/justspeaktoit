#if os(iOS)
import SpeakCore
import SwiftUI

extension ContentView {
    /// Status lines above the transcript: why capture stopped, and when the
    /// chosen microphone is missing so recording fell back to the system route.
    @ViewBuilder var captureNotices: some View {
        if let notice = handsFree.captureStopNotice
            ?? coordinator.captureStopNotice ?? backgroundService.captureStopNotice {
            Text(notice)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("captureStopNotice")
        }
        if let notice = microphoneStatus.notice(forSavedUID: settings.preferredAudioInputUID) {
            Label(notice, systemImage: "mic.slash")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("microphoneFallbackNotice")
        }
    }
}
#endif
