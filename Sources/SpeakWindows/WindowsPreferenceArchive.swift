import SpeakCore
import SpeakDesktopHost

extension WindowsHostPlatform {
    static var nativeConfigurationPlatform: DesktopNativeConfigurationCapture.Platform? { .windows }

    static func archiveNativePreferences(
        textOutput: TextOutputOptions?, hotKey: HotKeySettings?, voiceOutput: VoiceOutputSettings?
    ) -> DesktopHostNativePreferenceProjection {
        var projection = DesktopHostNativePreferenceProjection()
        if let textOutput {
            let method: String
            switch textOutput.method {
            case .smart: method = "smart"
            case .directOnly: method = "accessibilityOnly"
            case .clipboardOnly: method = "clipboardOnly"
            }
            projection.set(.textOutputMethod, .string(method))
            projection.set(.accessibilityInsertionMode,
                           .string(textOutput.insertion == .replaceField ? "replaceAll" : "insertAtCursor"))
            projection.set(.restoreClipboard, .bool(textOutput.restoreClipboard))
        }
        if let hotKey {
            projection.activation(hotKey.style)
            projection.nativeOnly("hotKey.binding", suppressing: .selectedHotKey)
        }
        projection.voice(voiceOutput)
        return projection
    }
}
