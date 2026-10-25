#if os(iOS)
import SpeakCore

/// Canonical destination plus its cause; resolved values are never reclassified as user Stop inputs.
struct CaptureDestinationSelection: Equatable, Sendable {
    enum Origin: String, Sendable {
        case explicitStart
        case explicitStop
        case keyboardProfile
        case focus
        case global
        case legacy
    }

    let destination: HardwareTriggerDestination
    let origin: Origin

    init(destination: HardwareTriggerDestination, origin: Origin) {
        self.destination = destination
        self.origin = origin
    }

    init(configuration: EffectiveCaptureConfiguration, keyboardProfile: Bool) {
        self.destination = HardwareTriggerDestination(rawValue: configuration.destinationID) ?? .clipboard
        if keyboardProfile {
            self.origin = .keyboardProfile
        } else {
            switch configuration.destinationOrigin {
            case .explicit: self.origin = .explicitStart
            case .focus: self.origin = .focus
            case .global: self.origin = .global
            }
        }
    }
}
#endif
