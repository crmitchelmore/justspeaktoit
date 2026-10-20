import SpeakCore
import SpeakDesktopHost
import SpeakLinuxPlatform

extension LinuxHostPlatform {
    static var nativeConfigurationPlatform: DesktopNativeConfigurationCapture.Platform? { .linux }

    static func archiveNativePreferences(
        textOutput: TextOutputOptions?, hotKey: HotKeySettings?, voiceOutput: VoiceOutputSettings?
    ) -> DesktopHostNativePreferenceProjection {
        var projection = DesktopHostNativePreferenceProjection()
        if let textOutput {
            switch textOutput.method {
            case .clipboardOnly: projection.set(.textOutputMethod, .string("clipboardOnly"))
            case .paste: projection.nativeOnly("textOutput.method", suppressing: .textOutputMethod)
            }
            projection.set(.restoreClipboard, .bool(textOutput.restoreClipboard))
            projection.appSwitchDelivery(textOutput.appSwitchDelivery)
        }
        if let hotKey {
            projection.activation(hotKey.style)
            projection.nativeOnly("hotKey.binding", suppressing: .selectedHotKey)
        }
        projection.voice(voiceOutput)
        return projection
    }
}
