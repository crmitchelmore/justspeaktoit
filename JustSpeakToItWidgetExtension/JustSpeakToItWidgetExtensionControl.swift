//
//  JustSpeakToItWidgetExtensionControl.swift
//  JustSpeakToItWidgetExtension
//
//  Created by Chris Mitchelmore on 09/01/2026.
//

import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
struct JustSpeakToItWidgetExtensionControl: ControlWidget {
    static let kind: String = "com.justspeaktoit.ios.JustSpeakToItWidgetExtension"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: Self.kind,
            provider: Provider()
        ) { value in
            ControlWidgetToggle(
                "Transcribe",
                isOn: value.isRecording,
                action: ToggleTranscriptionControlIntent()
            ) { isRecording in
                Label(
                    isRecording ? "Recording..." : "Transcribe",
                    systemImage: isRecording ? "stop.circle.fill" : "mic.fill"
                )
            }
        }
        .displayName("Transcribe Voice")
        .description("Start or stop voice transcription. Copies result to clipboard.")
    }
}

@available(iOS 18.0, *)
extension JustSpeakToItWidgetExtensionControl {
    struct Value {
        var isRecording: Bool
    }

    struct Provider: AppIntentControlValueProvider {
        func previewValue(configuration: TranscriptionControlConfiguration) -> Value {
            Value(isRecording: false)
        }

        func currentValue(configuration: TranscriptionControlConfiguration) async throws -> Value {
            let defaults = UserDefaults(suiteName: "group.com.speak.ios")
            let isRecording = defaults?.bool(forKey: "isRecording") ?? false
            return Value(isRecording: isRecording)
        }
    }
}

@available(iOS 18.0, *)
struct TranscriptionControlConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Transcription Configuration"
}

@available(iOS 18.0, *)
struct ToggleTranscriptionControlIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Toggle Transcription"

    @Parameter(title: "Recording")
    var value: Bool

    init() {}

    func perform() async throws -> some IntentResult {
        let service = await TranscriptionRecordingService.shared
        if value {
            try await service.startRecording()
        } else {
            await service.stopRecording()
        }
        return .result()
    }
}
