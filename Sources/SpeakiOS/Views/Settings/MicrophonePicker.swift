#if os(iOS)
import AVFoundation
import SpeakCore
import SwiftUI

/// A connected audio input the user can prefer for recording.
struct MicrophoneOption: Identifiable, Equatable {
    let uid: String
    let name: String
    let kind: AudioInputKind

    var id: String { uid }

    /// The inputs the recording category offers now. `availableInputs` is
    /// empty outside a recording category, so an idle session is moved to the
    /// mixable recording category first; that never interrupts other audio.
    @MainActor
    static func available() -> [MicrophoneOption] {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord, session.category != .record {
            try? session.setCategory(
                .playAndRecord, mode: .measurement, options: AudioSessionManager.mixableRecordingOptions
            )
        }
        return (session.availableInputs ?? []).map {
            MicrophoneOption(uid: $0.uid, name: $0.portName, kind: AudioInputKind(portType: $0.portType.rawValue))
        }
    }
}

/// Picker for the microphone recording prefers, with System Default first.
struct MicrophonePicker: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var inputs: [MicrophoneOption] = []

    var body: some View {
        Picker(selection: selection) {
            Text("System Default").tag("")
            ForEach(inputs) { input in
                Label(input.name, systemImage: input.kind.systemImage).tag(input.uid)
            }
            if let missing = missingSavedUID {
                Text("Saved Microphone (Not Connected)").tag(missing)
            }
        } label: {
            Label("Microphone", systemImage: "mic")
        }
        .accessibilityIdentifier("microphonePicker")
        .task { inputs = MicrophoneOption.available() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            Task { @MainActor in inputs = MicrophoneOption.available() }
        }

        SettingsFootnote(footnote, alwaysShown: true)
            .accessibilityIdentifier("microphoneFootnote")
    }

    private var selection: Binding<String> {
        Binding(
            get: { settings.preferredAudioInputUID ?? "" },
            set: { settings.preferredAudioInputUID = $0.isEmpty ? nil : $0 }
        )
    }

    private var resolution: PreferredAudioInputResolution {
        PreferredAudioInputResolution(storedUID: settings.preferredAudioInputUID, availableUIDs: inputs.map(\.uid))
    }

    private var missingSavedUID: String? {
        if case .unavailable(let uid) = resolution { return uid }
        return nil
    }

    private var footnote: String {
        switch resolution {
        case .systemDefault:
            "Recording follows the system route: a connected headset or Bluetooth microphone, "
                + "otherwise the built-in one."
        case .selected:
            "Used whenever it's connected. If it disconnects, recording falls back to the system default."
        case .unavailable:
            "**Your chosen microphone isn't connected.** Recording uses the system default until it's back."
        }
    }
}
#endif
