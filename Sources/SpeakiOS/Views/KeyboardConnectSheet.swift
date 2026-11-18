#if os(iOS)
import SpeakCore
import SwiftUI

/// Shown when the keyboard opened the app to connect Instant Dictation.
///
/// The app cannot send the user back to the app they were typing in (iOS has
/// no API for that), so the sheet confirms the connection and says how to go
/// back. Recording starts by itself when the keyboard reappears.
public struct KeyboardConnectSheet: View {
    @ObservedObject private var instantDictation = KeyboardInstantDictationCoordinator.shared
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: symbol)
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(isConnected ? Color.green : Color.accentColor)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if !isConnected, instantDictation.errorMessage == nil {
                    ProgressView()
                        .accessibilityLabel("Connecting")
                }
                if instantDictation.errorMessage != nil {
                    Button {
                        Task { await instantDictation.connectFromKeyboard() }
                    } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("keyboardConnectRetryButton")
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("keyboardConnectDoneButton")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var isConnected: Bool {
        instantDictation.isReady || instantDictation.isRecording
    }

    private var symbol: String {
        if isConnected { return "checkmark.circle.fill" }
        return instantDictation.errorMessage == nil ? "keyboard.badge.ellipsis" : "exclamationmark.triangle.fill"
    }

    private var title: String {
        if isConnected { return "Keyboard connected" }
        return instantDictation.errorMessage == nil ? "Connecting the keyboard…" : "Couldn't connect the keyboard"
    }

    private var detail: String {
        if isConnected {
            return "Go back to the app you were typing in: tap its name at the top left, "
                + "or swipe right along the bottom edge. Recording starts when the keyboard reappears. "
                + "Just Speak keeps the microphone ready for the keyboard; idle audio is discarded, "
                + "never saved or sent."
        }
        return instantDictation.errorMessage
            ?? "Just Speak is starting Instant Dictation so the keyboard can record."
    }
}
#endif
