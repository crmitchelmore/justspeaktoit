import Foundation

/// The balance directory as JSON for the Android app, limited to the accounts
/// whose key Android stores, in Android's settings order, so its API Keys
/// screen shows the same balance-or-billing-link decision, reason and billing
/// page as every other platform without keeping its own list.
///
/// Android implements a transport only for each `balance` account it lists;
/// its parity test fails when SpeakCore marks another Android account as
/// readable. `ProviderBalanceAndroidExportTests` fails when the committed asset
/// is stale; regenerate it with `scripts/update-android-assets`.
public enum ProviderBalanceAndroidExport {
    static var accounts: [ProviderBalanceAccount] {
        var seen: Set<String> = []
        return CloudCatalogAndroidExport.providerCredentialIdentifiers.compactMap { identifier in
            guard let account = ProviderBalanceDirectory.account(forCredentialIdentifier: identifier),
                  account.primaryCredentialIdentifier == identifier,
                  seen.insert(account.id).inserted else { return nil }
            return account
        }
    }

    public static func json() throws -> Data {
        struct Account: Encodable {
            let id, displayName, primaryCredentialId, support: String
            let credentialIds: [String]
            /// Billing-link accounts only: why no figure is shown.
            let reason: String?
            let billingUrl: String?
        }
        struct Document: Encodable {
            let version: Int
            /// `ProviderBalanceTransport.requestTimeout`, so Android bounds a check the same way.
            let requestTimeoutSeconds: Int
            let accounts: [Account]
        }
        let document = Document(
            version: 1,
            requestTimeoutSeconds: Int(ProviderBalanceTransport.requestTimeout),
            accounts: accounts.map { account in
                let reason: String?
                switch account.support {
                case .balance: reason = nil
                case .billingLinkOnly(let why): reason = why
                }
                return Account(
                    id: account.id, displayName: account.displayName,
                    primaryCredentialId: account.primaryCredentialIdentifier,
                    support: reason == nil ? "balance" : "billingLinkOnly",
                    credentialIds: account.credentialIdentifiers, reason: reason,
                    billingUrl: account.billingURL?.absoluteString
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(document)
        data.append(0x0A)
        return data
    }
}
