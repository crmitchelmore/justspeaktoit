#if os(iOS)
import SpeakCore
import SwiftUI

/// Shows a History send in progress, then whether the Mac received it, and
/// announces the outcome to VoiceOver.
struct SendToMacStatusBanner: View {
    @ObservedObject var sender: SendToMacSender

    var body: some View {
        Group {
            switch sender.activity {
            case .sending, .sent, .sendFailed:
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SendToMacActivityRow(activity: sender.activity)
                        .font(.callout)
                    Spacer(minLength: 8)
                    if !sender.isBusy {
                        Button {
                            sender.clearActivity()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Dismiss Send to Mac status")
                        .accessibilityIdentifier("sendToMacStatusDismissButton")
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial)
                .accessibilityIdentifier("sendToMacStatusBanner")
            default:
                EmptyView()
            }
        }
        .onChange(of: sender.activity) { _, activity in
            announce(activity)
        }
        .task(id: sender.activity) {
            guard case .sent = sender.activity else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            sender.clearActivity()
        }
    }

    private func announce(_ activity: SendToMacSender.Activity) {
        let message: String
        switch activity {
        case .sent(let macName):
            message = "Sent to \(macName)"
        case .sendFailed(let reason):
            message = "Send to Mac failed. \(reason)"
        default:
            return
        }
        AccessibilityNotification.Announcement(message).post()
    }
}

extension View {
    /// Shows `sender`'s send progress and result along the bottom edge.
    func sendToMacStatusBanner(_ sender: SendToMacSender) -> some View {
        safeAreaInset(edge: .bottom) { SendToMacStatusBanner(sender: sender) }
            .task { await sender.load() }
    }
}

extension SendToMacSender {
    /// The action that sends a History transcript, or nil while no Mac is
    /// paired or a send is already running.
    func sendAction(text: String, model: String, duration: TimeInterval) -> (() -> Void)? {
        guard isPaired, !isBusy else { return nil }
        return { Task { await self.send(text, model: model, duration: duration) } }
    }
}
#endif
