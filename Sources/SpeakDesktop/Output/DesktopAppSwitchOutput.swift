import SpeakCore

/// The policy lives in the recording's native output options, not a second store.
public protocol DesktopAppSwitchOutputOptions: Codable, Sendable {
    var appSwitchDelivery: AppSwitchDelivery? { get set }
    init(appSwitchDelivery: AppSwitchDelivery?)
}

public enum DesktopAppSwitchOutput {
    public static func project(
        _ policy: AppSwitchDelivery?, over configuration: DesktopConfiguration, editor: Bool = false
    ) throws -> DesktopConfiguration {
        var values = configuration.values
        values[AppSwitchDelivery.preferenceKey] = policy.map { AnyCodable(.string($0.rawValue)) }
        if editor && policy == nil { values[AppSwitchDelivery.preferenceKey] = AnyCodable(.string("")) }
        return try DesktopConfiguration(values: values)
    }

    public static func importPolicy(
        from configuration: DesktopConfiguration, into options: inout any DesktopAppSwitchOutputOptions
    ) throws -> DesktopConfiguration {
        var values = configuration.values
        if let value = values.removeValue(forKey: AppSwitchDelivery.preferenceKey) {
            guard case .string(let raw) = value.storage else {
                throw DesktopConfigurationError.invalidField(AppSwitchDelivery.settingName)
            }
            guard raw.isEmpty || AppSwitchDelivery(rawValue: raw) != nil else {
                throw DesktopConfigurationError.invalidField(AppSwitchDelivery.settingName)
            }
            options.appSwitchDelivery = AppSwitchDelivery(rawValue: raw)
        }
        return try DesktopConfiguration(values: values)
    }
}
