import Foundation

/// Product identity and persistence, independent of direct/App Store capabilities.
/// The same catalogue is read by Tuist and the release scripts.
public enum ReleaseTrain: String, Codable, CaseIterable, Sendable {
    case stable
    case alpha

    public static var current: ReleaseTrain {
        #if ALPHA
        return .alpha
        #else
        return resolve(
            metadata: Bundle.main.object(forInfoDictionaryKey: "SpeakReleaseTrain") as? String,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
        #endif
    }

    public static func resolve(metadata: String?, bundleIdentifier: String?) -> ReleaseTrain {
        let alphaIdentity = bundleIdentifier?.split(separator: ".").contains("alpha") == true
        if let metadata {
            guard let train = Self(rawValue: metadata) else {
                preconditionFailure("Invalid SpeakReleaseTrain metadata")
            }
            precondition(!alphaIdentity || train == .alpha, "Alpha identity cannot use Stable storage")
            return train
        }
        // Legacy Stable apps and test runners have no metadata. An Alpha bundle
        // must never fall back to Stable persistence, even before archive validation.
        return alphaIdentity ? .alpha : .stable
    }

    public var supportDirectory: String { value("applicationSupportDirectory") }
    public var displayName: String { value("displayName") }
    public var iosAppGroup: String { value("iosAppGroup") }
    public var watchAppGroup: String { value("watchAppGroup") }
    public var iosCloudContainer: String { value("iosCloudContainer") }
    public var macCloudContainer: String { value("macCloudContainer") }
    public var urlScheme: String { value("urlScheme") }
    public var bonjourService: String { value("transportServiceType") }
    public var feedURL: String { value("feedURL") }
    public var arm64FeedURL: String { value("arm64FeedURL") }
    public var cliDownloadURL: String { value("cliDownloadURL") }
    public var cliExecutableName: String { value("cliExecutableName") }

    /// Preserve every existing Stable name. Alpha never reads legacy Stable keys.
    public func namespace(_ stableName: String) -> String {
        self == .stable ? stableName : stableName + ".alpha"
    }

    public func acceptsPeer(_ advertisedTrain: ReleaseTrain?) -> Bool {
        (advertisedTrain ?? .stable) == self
    }

    public func deepLink(_ route: String) -> URL? {
        URL(string: "\(urlScheme)://\(route)")
    }

    public func value(_ key: String) -> String {
        guard let result = Self.catalogue[rawValue]?[key], !result.isEmpty else {
            preconditionFailure("Missing release configuration: \(rawValue).\(key)")
        }
        return result
    }

    private static let catalogue = ReleaseTrainCatalogue.values
}
