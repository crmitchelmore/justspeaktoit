import SpeakCore
import SpeakDesktop

extension DesktopHostPlatform {
    package static func appSwitchPolicy(_ options: TextOutputOptions?) -> AppSwitchDelivery? {
        (options as? any DesktopAppSwitchOutputOptions)?.appSwitchDelivery
    }

    package static func importingAppSwitchPolicy(
        from configuration: DesktopConfiguration, into options: inout TextOutputOptions?
    ) throws -> DesktopConfiguration {
        guard configuration.values[AppSwitchDelivery.preferenceKey] != nil else { return configuration }
        guard let outputType = TextOutputOptions.self as? any DesktopAppSwitchOutputOptions.Type else {
            throw DesktopHostError(message: "This host cannot apply app-switch delivery preferences.")
        }
        var output = (options as? any DesktopAppSwitchOutputOptions) ?? outputType.init(appSwitchDelivery: nil)
        let retained = try DesktopAppSwitchOutput.importPolicy(from: configuration, into: &output)
        guard let typed = output as? TextOutputOptions else {
            throw DesktopHostError(message: "The text output preference type changed unexpectedly.")
        }
        options = typed
        return retained
    }
}
