import Foundation

public enum AppInformationLink: String, CaseIterable, Sendable {
    case repository, issues, privacy, releases, featureRequest, license

    public var title: String {
        switch self {
        case .repository: "View on GitHub"
        case .issues: "Report an Issue"
        case .privacy: "Privacy Policy"
        case .releases: "View Releases"
        case .featureRequest: "Request Feature"
        case .license: "View License (MIT)"
        }
    }

    public var url: URL {
        let repository = "https://github.com/crmitchelmore/justspeaktoit"
        switch self {
        case .repository: return URL(string: repository)!
        case .issues: return URL(string: repository + "/issues")!
        case .privacy: return PrivacyPolicy.url
        case .releases: return URL(string: repository + "/releases")!
        case .featureRequest: return URL(string: repository + "/issues/new?template=feature_request.md")!
        case .license: return URL(string: repository + "/blob/main/LICENSE")!
        }
    }
}
