#if os(iOS)
import SpeakCore
import SwiftUI

public struct KeyboardCaptureView: View {
    @StateObject private var coordinator: KeyboardHandoffCaptureCoordinator
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(requestID: UUID) {
        _coordinator = StateObject(
            wrappedValue: KeyboardHandoffCaptureCoordinator(requestID: requestID)
        )
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: dynamicTypeSize.isAccessibilitySize ? 22 : 30) {
                    statusHero
                    privacyCard
                    actions
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Keyboard Transcription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if canDismiss {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            dismiss()
                        }
                    }
                }
            }
        }
        .interactiveDismissDisabled(!canDismiss)
        .task {
            await coordinator.start()
        }
    }

    private var statusHero: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(heroTint.opacity(0.14))
                    .frame(width: 112, height: 112)
                Image(systemName: heroSymbol)
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(heroTint)
                    .symbolEffect(.pulse, isActive: coordinator.phase == .recording)
            }
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("keyboardCaptureTitle")
                Text(coordinator.message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("keyboardCaptureMessage")
            }

            if coordinator.phase == .recording || coordinator.phase == .transcribing {
                HStack(spacing: 5) {
                    ForEach(0..<7, id: \.self) { index in
                        Capsule()
                            .fill(heroTint.gradient)
                            .frame(width: 5, height: CGFloat(12 + (index % 4) * 8))
                    }
                }
                .accessibilityHidden(true)
            }

            Label(selectedModelName, systemImage: "cpu")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Selected model: \(selectedModelName)")
        }
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Private handoff", systemImage: "lock.shield")
                .font(.headline)
            Text(
                "The keyboard cannot access the microphone. Just Speak records here with your selected model, "
                    + "saves the completed transcript to History, and clears the temporary handoff after insertion or timeout."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Text("Audio, API keys, surrounding text, and partial transcripts are never placed in shared storage.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var actions: some View {
        switch coordinator.phase {
        case .preparing:
            ProgressView("Preparing…")
                .controlSize(.large)

        case .recording:
            VStack(spacing: 12) {
                Button {
                    Task {
                        await coordinator.finish()
                    }
                } label: {
                    Label("Finish & Transcribe", systemImage: "stop.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .accessibilityIdentifier("finishKeyboardRecordingButton")

                Button("Cancel", role: .cancel) {
                    coordinator.cancel()
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("cancelKeyboardRecordingButton")
            }

        case .transcribing:
            ProgressView("Finalising transcript…")
                .controlSize(.large)
                .accessibilityIdentifier("keyboardTranscribingProgress")

        case .ready:
            Button {
                dismiss()
            } label: {
                Label("Done", systemImage: "checkmark")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("keyboardResultReadyButton")

        case .cancelled, .error:
            Button("Return to Just Speak") {
                dismiss()
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
        }
    }

    private var canDismiss: Bool {
        switch coordinator.phase {
        case .preparing, .recording, .transcribing:
            return false
        case .ready, .cancelled, .error:
            return true
        }
    }

    private var title: String {
        switch coordinator.phase {
        case .preparing: return "Getting Ready"
        case .recording: return "Listening"
        case .transcribing: return "Transcribing"
        case .ready: return "Ready to Insert"
        case .cancelled: return "Cancelled"
        case .error: return "Couldn’t Complete"
        }
    }

    private var heroSymbol: String {
        switch coordinator.phase {
        case .preparing: return "waveform"
        case .recording: return "mic.fill"
        case .transcribing: return "ellipsis.bubble.fill"
        case .ready: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var heroTint: Color {
        switch coordinator.phase {
        case .recording: return .red
        case .ready: return .green
        case .error: return .orange
        default: return .accentColor
        }
    }

    private var selectedModelName: String {
        let modelID = settings.transcriptionMode == .batch
            ? settings.batchTranscriptionModel
            : settings.selectedModel
        return ModelCatalog.friendlyName(for: modelID)
    }
}
#endif
