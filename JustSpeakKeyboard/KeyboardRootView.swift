import SpeakCore
import SwiftUI
import UIKit

/// Compact dictation-first keyboard surface.
///
/// Layout is a live transcript strip above one control row:
/// globe · language chip · mic/stop · delete · return. There is deliberately
/// no QWERTY layer — the globe key returns to the system keyboard for typing.
struct KeyboardRootView: View {
    @ObservedObject var model: KeyboardViewModel
    let showsInputModeSwitch: Bool
    let insertText: (String) -> Void
    let deleteBackward: () -> Void
    let showInputModeList: (UIButton, UIEvent) -> Void

    var body: some View {
        VStack(spacing: 8) {
            transcriptStrip
            controlRow
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    // MARK: - Transcript strip

    private var transcriptStrip: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: stripSymbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(stripTint)
                .padding(.top, 2)
                .accessibilityHidden(true)
            Text(stripText)
                .font(.subheadline.weight(stripShowsLiveText ? .medium : .regular))
                .foregroundStyle(stripShowsLiveText ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityLabel(stripAccessibilityLabel)
                .accessibilityIdentifier("keyboardLiveTranscript")
            if showsCancel {
                Button("Cancel") {
                    model.cancelTapped()
                }
                .font(.footnote.weight(.semibold))
                .accessibilityIdentifier("keyboardCancelButton")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
        .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.easeInOut(duration: 0.15), value: stripText)
    }

    // MARK: - Control row

    private var controlRow: some View {
        HStack(spacing: 8) {
            if showsInputModeSwitch {
                InputModeSwitchButton(action: showInputModeList)
                    .frame(width: 46, height: 46)
                    .background(keyBackground)
                    .accessibilityLabel("Next keyboard")
                    .accessibilityHint("Touch and hold to choose another keyboard")
            }

            if let chip = model.languageChipLabel, model.mode == .direct {
                Button {
                    model.cycleLanguage()
                } label: {
                    Text(chip)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 10)
                        .frame(height: 46)
                }
                .background(keyBackground)
                .disabled(model.isCapturing)
                .accessibilityLabel("Dictation language \(chip). Tap to switch.")
                .accessibilityIdentifier("keyboardLanguageChip")
            }

            micButton

            Button {
                deleteBackward()
            } label: {
                Image(systemName: "delete.left")
                    .font(.body.weight(.medium))
                    .frame(width: 46, height: 46)
            }
            .background(keyBackground)
            .disabled(controlsDisabled)
            .accessibilityLabel("Delete backward")
            .accessibilityIdentifier("keyboardDeleteButton")

            Button {
                insertText("\n")
            } label: {
                Image(systemName: "return")
                    .font(.body.weight(.medium))
                    .frame(width: 46, height: 46)
            }
            .background(keyBackground)
            .disabled(controlsDisabled)
            .accessibilityLabel("Return")
            .accessibilityIdentifier("keyboardReturnButton")
        }
        .foregroundStyle(.primary)
    }

    private var micButton: some View {
        Button {
            model.micTapped()
        } label: {
            HStack(spacing: 8) {
                if micShowsProgress {
                    ProgressView()
                } else {
                    Image(systemName: micSymbol)
                        .font(.title3.weight(.semibold))
                }
                if let caption = micCaption {
                    Text(caption)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .foregroundStyle(.white)
            .background(
                micTint,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(micDisabled)
        .accessibilityLabel(micAccessibilityLabel)
        .accessibilityIdentifier("keyboardMicButton")
    }

    private var keyBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground))
    }

    // MARK: - Strip content

    private var stripShowsLiveText: Bool {
        !currentLiveText.isEmpty
    }

    private var currentLiveText: String {
        switch model.mode {
        case .direct:
            return model.liveText
        case .handoff:
            return model.handoff.liveTranscript
        case .blocked:
            return ""
        }
    }

    private var stripText: String {
        if stripShowsLiveText {
            return currentLiveText
        }
        switch model.mode {
        case .direct:
            switch model.directState {
            case .idle:
                return "Tap the mic and speak. Words appear as you talk."
            case .starting:
                return "Starting the microphone…"
            case .recording:
                return "Listening…"
            case .stopping:
                return "Finishing…"
            case .finished:
                return "Inserted. Tap the mic to dictate more."
            case let .failed(failure):
                return Self.failureCopy(failure)
            }
        case .handoff:
            return Self.handoffCopy(model.handoff.presentation)
        case let .blocked(reason):
            switch reason {
            case .fullAccessRequired:
                return "Turn on Allow Full Access for Just Speak in Settings › General › Keyboard to dictate."
            case .sharedContainerUnavailable:
                return "Open the Just Speak app once, then try this keyboard again."
            }
        }
    }

    private static func failureCopy(_ failure: KeyboardDictationMachine.Failure) -> String {
        switch failure {
        case .microphoneUnavailable:
            return "The keyboard can't use the microphone. Allow it in Settings, or open Just Speak and enable Instant Dictation."
        case .speechRecognitionUnavailable:
            return "Speech recognition isn't available. Allow it in Settings, then try again."
        case .audioInterrupted:
            return "Audio was interrupted. Tap the mic to try again."
        case .targetChanged:
            return "The text field changed, so dictation stopped. Tap the mic to continue here."
        case .noSpeech:
            return "No speech detected. Tap the mic and try again."
        }
    }

    private static func handoffCopy(_ presentation: KeyboardHandoffController.Presentation) -> String {
        switch presentation {
        case .idle:
            return "Instant Dictation ready. Tap the mic to speak."
        case .starting:
            return "Connecting to Just Speak…"
        case .waitingForApp:
            return "Open Just Speak once to reconnect Instant Dictation, then return here."
        case .recording:
            return "Listening via Just Speak…"
        case .transcribing:
            return "Finishing transcript…"
        case .inserted:
            return "Inserted. Tap the mic to dictate more."
        case .unavailable:
            return "Just Speak is unavailable. Open the app once, then tap the mic to retry."
        case .cancelled:
            return "Cancelled. Nothing was inserted."
        case .targetChanged:
            return "The text field changed, so nothing was inserted. Tap the mic to retry."
        case let .error(code):
            return Self.handoffErrorCopy(code)
        }
    }

    private static func handoffErrorCopy(_ code: KeyboardHandoffRecord.FailureCode) -> String {
        switch code {
        case .fullAccessRequired:
            return "Turn on Full Access in Settings, then try again."
        case .appUnavailable:
            return "Open Just Speak from the Home Screen, then tap the mic to retry."
        case .recordingUnavailable:
            return "Recording could not start. Check the microphone permission in Just Speak."
        case .noSpeech:
            return "No speech detected. Nothing was inserted."
        case .timedOut:
            return "The request expired. Tap the mic to retry."
        case .invalidRequest, .unknown:
            return "The handoff ended safely. Tap the mic to retry."
        case .targetChanged:
            return "The destination changed, so nothing was inserted. Tap the mic to retry."
        }
    }

    /// The status symbol is hidden from assistive technology, so VoiceOver
    /// reads the strip as status plus content.
    private var stripAccessibilityLabel: String {
        guard stripShowsLiveText else { return stripText }
        return "\(liveStatusDescription). \(stripText)"
    }

    private var liveStatusDescription: String {
        switch model.mode {
        case .direct:
            switch model.directState {
            case .stopping: return "Finishing dictation"
            case .finished: return "Dictation inserted"
            default: return "Dictating"
            }
        case .handoff:
            switch model.handoff.presentation {
            case .transcribing: return "Finishing dictation"
            case .inserted: return "Dictation inserted"
            default: return "Dictating"
            }
        case .blocked:
            return "Dictation unavailable"
        }
    }

    private var stripSymbol: String {
        switch model.mode {
        case .direct:
            switch model.directState {
            case .recording, .stopping: return "waveform"
            case .finished: return "checkmark.circle.fill"
            case .failed: return "exclamationmark.triangle.fill"
            default: return "mic"
            }
        case .handoff:
            switch model.handoff.presentation {
            case .recording, .transcribing: return "waveform"
            case .inserted: return "checkmark.circle.fill"
            case .waitingForApp: return "arrow.up.forward.app"
            case .unavailable, .targetChanged, .error: return "exclamationmark.triangle.fill"
            default: return "mic"
            }
        case .blocked:
            return "lock.trianglebadge.exclamationmark"
        }
    }

    private var stripTint: Color {
        switch stripSymbol {
        case "checkmark.circle.fill": return .green
        case "exclamationmark.triangle.fill", "lock.trianglebadge.exclamationmark": return .orange
        case "waveform": return .red
        default: return .secondary
        }
    }

    // MARK: - Mic button state

    private var micSymbol: String {
        if isActivelyCapturing {
            return "stop.fill"
        }
        return "mic.fill"
    }

    private var micTint: Color {
        if isActivelyCapturing {
            return .red
        }
        return micDisabled ? Color.gray.opacity(0.5) : .blue
    }

    private var micCaption: String? {
        if isActivelyCapturing {
            return "Stop"
        }
        switch model.mode {
        case .direct, .handoff:
            return "Speak"
        case .blocked:
            return nil
        }
    }

    private var micShowsProgress: Bool {
        switch model.mode {
        case .direct:
            return model.directState == .starting || model.directState == .stopping
        case .handoff:
            let presentation = model.handoff.presentation
            return presentation == .starting || presentation == .transcribing
        case .blocked:
            return false
        }
    }

    private var isActivelyCapturing: Bool {
        switch model.mode {
        case .direct:
            return model.directState == .recording
        case .handoff:
            return model.handoff.presentation == .recording
        case .blocked:
            return false
        }
    }

    private var micDisabled: Bool {
        switch model.mode {
        case .direct:
            return model.directState == .stopping
        case .handoff:
            let presentation = model.handoff.presentation
            return presentation == .transcribing || presentation == .waitingForApp
        case .blocked:
            return true
        }
    }

    private var micAccessibilityLabel: String {
        isActivelyCapturing ? "Stop dictation" : "Start dictation"
    }

    private var controlsDisabled: Bool {
        switch model.mode {
        case .direct:
            return model.isCapturing
        case .handoff:
            let presentation = model.handoff.presentation
            return presentation == .recording || presentation == .transcribing
        case .blocked:
            return false
        }
    }

    private var showsCancel: Bool {
        switch model.mode {
        case .direct:
            return model.directState == .recording || model.directState == .starting
        case .handoff:
            let presentation = model.handoff.presentation
            return presentation == .starting || presentation == .recording
                || presentation == .transcribing
        case .blocked:
            return false
        }
    }
}

struct InputModeSwitchButton: UIViewRepresentable {
    let action: (UIButton, UIEvent) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "globe"), for: .normal)
        button.tintColor = .label
        button.accessibilityLabel = "Next keyboard"
        button.addTarget(
            context.coordinator,
            action: #selector(Coordinator.handle(_:event:)),
            for: .allTouchEvents
        )
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}

    final class Coordinator: NSObject {
        let action: (UIButton, UIEvent) -> Void

        init(action: @escaping (UIButton, UIEvent) -> Void) {
            self.action = action
        }

        @objc func handle(_ sender: UIButton, event: UIEvent) {
            action(sender, event)
        }
    }
}
