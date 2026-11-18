#if os(iOS)
import SpeakCore
import SwiftUI

/// Shows the consent sheet whenever an upload path refused for a provider
/// without consent (issue #1805). Allow retries the Share extension's waiting
/// recordings; a refused recording start is retried by the user.
struct IOSCloudSharingConsentPresenter: ViewModifier {
    @ObservedObject private var prompt = IOSCloudSharingConsentPrompt.shared

    private var isPresented: Binding<Bool> {
        Binding(get: { !prompt.pending.isEmpty }, set: { if !$0 { prompt.dismiss() } })
    }

    /// On-device replacements exist for transcription and polish, not voices.
    private var onDeviceAvailable: Bool {
        prompt.pending.contains { !Set($0.kinds).isDisjoint(with: [.audio, .transcriptText]) }
    }

    func body(content: Content) -> some View {
        content.sheet(isPresented: isPresented) {
            CloudSharingConsentSheet(
                requests: prompt.pending,
                onDeviceAvailable: onDeviceAvailable,
                onAllow: {
                    prompt.allow()
                    Task { await SharedRecordingImporter.shared.drain() }
                },
                onUseOnDevice: { prompt.useOnDevice() },
                onNotNow: { prompt.dismiss() }
            )
            .presentationDetents([.medium, .large])
        }
    }
}

extension View {
    func cloudSharingConsentSheet() -> some View {
        modifier(IOSCloudSharingConsentPresenter())
    }
}
#endif
