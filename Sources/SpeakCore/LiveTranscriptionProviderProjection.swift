import Foundation

public extension LiveTranscriptionRouting {
    /// Providers iOS can use, in first catalogue order. Privacy surfaces consume
    /// this projection so a new live model cannot leave its processor undisclosed.
    static var iOSSupportedProviders: [LiveTranscriptionProviderID] {
        var seen: Set<LiveTranscriptionProviderID> = []
        return allRoutes.compactMap { route in
            guard route.isSupportedOnIOS, seen.insert(route.provider).inserted else { return nil }
            return route.provider
        }
    }
}
