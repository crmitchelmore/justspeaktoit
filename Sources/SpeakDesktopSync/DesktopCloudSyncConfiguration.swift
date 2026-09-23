import Foundation
import SpeakCore
import SpeakSync

/// Where a desktop build's CloudKit Web Services settings come from.
///
/// The API token belongs to the developer's CloudKit container and is created
/// in CloudKit Console; nothing in an Apple app build can stand in for it. A
/// build receives it at build time (the `CLOUDKIT_WEB_API_TOKEN` CI secret,
/// written into the build by `scripts/windows-cloudkit/configure-cloudkit-web.py`).
/// Developers may override it at run time with `JSTI_CLOUDKIT_WEB_API_TOKEN`
/// and `JSTI_CLOUDKIT_WEB_ENVIRONMENT`. Without a token, sync is unavailable
/// and says why; every other feature keeps working.
public enum DesktopCloudSyncConfiguration {
    public static let tokenVariable = "JSTI_CLOUDKIT_WEB_API_TOKEN"
    public static let environmentVariable = "JSTI_CLOUDKIT_WEB_ENVIRONMENT"

    /// The Mac container family: Windows joins the Mac App Store build's
    /// History, so a user's Mac History appears on Windows.
    public static let family = SyncContainerFamily.macOS

    public enum Resolution: Equatable, Sendable {
        case available(CloudKitWebServicesConfiguration)
        case unavailable(reason: String)

        public var configuration: CloudKitWebServicesConfiguration? {
            if case .available(let configuration) = self { return configuration }
            return nil
        }
    }

    public static func resolve(
        buildToken: String?,
        buildEnvironment: String,
        processEnvironment: [String: String],
        train: ReleaseTrain = .current
    ) -> Resolution {
        let override = processEnvironment[tokenVariable]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = (override?.isEmpty == false ? override : buildToken)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else {
            return .unavailable(
                reason: "iCloud sync is not available in this build: it was built without a CloudKit API token."
            )
        }
        let environmentName = processEnvironment[environmentVariable] ?? buildEnvironment
        guard let environment = CloudKitWebServicesConfiguration.Environment(rawValue: environmentName) else {
            return .unavailable(
                reason: "iCloud sync is misconfigured: “\(environmentName)” is not a CloudKit environment."
            )
        }
        do {
            return .available(try CloudKitWebServicesConfiguration(
                family: family, train: train, environment: environment, apiToken: token
            ))
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }
}

/// The platform credential store (Windows Credential Manager on Windows).
public protocol DesktopCredentialVault: Sendable {
    func readCredential(_ name: String) throws -> String?
    func writeCredential(_ value: String, name: String) throws
    func deleteCredential(_ name: String) throws
}

/// Credential names for sync secrets, beside the provider API keys.
public enum DesktopCloudSyncCredential {
    public static let webAuthToken = "cloudkit.webAuthToken"
    public static let apiKeySyncKey = "cloudkit.apiKeySyncKey"
}

/// The rotating CloudKit web auth token, kept in the credential vault.
public struct VaultWebAuthTokenStore: CloudKitWebAuthTokenStore {
    private let vault: any DesktopCredentialVault

    public init(vault: any DesktopCredentialVault) {
        self.vault = vault
    }

    public func loadWebAuthToken() async throws -> String? {
        let token = try vault.readCredential(DesktopCloudSyncCredential.webAuthToken)
        return token?.isEmpty == false ? token : nil
    }

    public func saveWebAuthToken(_ token: String) async throws {
        try vault.writeCredential(token, name: DesktopCloudSyncCredential.webAuthToken)
    }

    public func clearWebAuthToken() async throws {
        try vault.deleteCredential(DesktopCloudSyncCredential.webAuthToken)
    }
}

/// The loopback sign-in callback registered on the container's API token.
///
/// Apple's web sign-in finishes by redirecting the browser to the API token's
/// sign-in callback with `?ckWebAuthToken=…`. A packaged desktop app receives
/// that on a fixed loopback port it listens on only during sign-in. The URL
/// must match the token's callback in CloudKit Console exactly.
public enum DesktopCloudSyncSignIn {
    public static let callbackHost = "127.0.0.1"
    public static let callbackPort: UInt16 = 47_823
    public static let callbackPath = "/cloudkit-sign-in"
    public static var callbackURL: String { "http://\(callbackHost):\(callbackPort)\(callbackPath)" }

    /// The web auth token from a callback request target such as
    /// `/cloudkit-sign-in?ckWebAuthToken=…`, or `nil` for anything else.
    public static func webAuthToken(fromRequestTarget target: String) -> String? {
        guard let components = URLComponents(string: "http://\(callbackHost)" + target),
              components.path == callbackPath,
              let token = components.queryItems?.first(where: { $0.name == "ckWebAuthToken" })?.value,
              !token.isEmpty else {
            return nil
        }
        return token
    }

    /// Only Apple's own HTTPS sign-in pages are opened in the browser.
    public static func isTrustedSignInURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return ["apple.com", "icloud.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
