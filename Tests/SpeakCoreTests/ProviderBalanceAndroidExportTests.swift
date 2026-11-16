import Foundation
import XCTest

@testable import SpeakCore

/// Android's API Keys screen reads a committed JSON asset; this keeps it identical to
/// `ProviderBalanceDirectory` for the providers Android stores keys for.
final class ProviderBalanceAndroidExportTests: XCTestCase {
    private var assetURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("android/app/src/main/assets/provider_balances.json")
    }

    func testAndroidAssetMatchesDirectory() throws {
        let expected = try ProviderBalanceAndroidExport.json()
        if ProcessInfo.processInfo.environment["UPDATE_PROVIDER_BALANCES_ANDROID"] == "1" {
            try expected.write(to: assetURL)
        }
        let committed = try Data(contentsOf: assetURL)
        XCTAssertEqual(
            committed, expected,
            "android/app/src/main/assets/provider_balances.json is stale. Regenerate with "
                + "scripts/update-android-assets"
        )
    }

    func testEveryAndroidKeyHasExactlyOneAccountWithItsPrimaryCard() {
        let accounts = ProviderBalanceAndroidExport.accounts
        XCTAssertEqual(
            accounts.map(\.primaryCredentialIdentifier),
            CloudCatalogAndroidExport.providerCredentialIdentifiers,
            "Each Android provider key owns one balance line"
        )
        XCTAssertEqual(accounts.count, Set(accounts.map(\.id)).count)
    }

    func testReadableAndroidAccountsHaveASharedTransport() throws {
        let object = try JSONSerialization.jsonObject(with: ProviderBalanceAndroidExport.json()) as? [String: Any]
        XCTAssertEqual(object?["requestTimeoutSeconds"] as? Int, 15)
        let accounts = try XCTUnwrap(object?["accounts"] as? [[String: Any]])
        let readable = accounts.filter { $0["support"] as? String == "balance" }.compactMap { $0["id"] as? String }
        XCTAssertEqual(readable, ["deepgram", "elevenlabs", "revai", "openrouter"])
        XCTAssertTrue(Set(readable).isSubset(of: ProviderBalanceSources.accountIDs))
        for account in accounts where account["support"] as? String == "billingLinkOnly" {
            XCTAssertFalse((account["reason"] as? String ?? "").isEmpty, "\(account)")
            XCTAssertNotNil(account["billingUrl"] as? String, "\(account)")
        }
    }
}
