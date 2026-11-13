import Foundation

/// One optional tip. Tips are consumable and never unlock a feature.
public struct TipProduct: Equatable, Sendable {
    /// The store product ID, identical in App Store Connect and Google Play Console.
    public let id: String
    public let emoji: String
    /// The fallback name shown before the store returns its localised one.
    public let displayName: String
    public let summary: String

    public init(id: String, emoji: String, displayName: String, summary: String) {
        self.id = id
        self.emoji = emoji
        self.displayName = displayName
        self.summary = summary
    }
}

/// The tip jar's products, shared by the Mac app (StoreKit) and Android (Google Play Billing).
///
/// Prices live in each store, not here. Add a tier here and in both stores; Android reads
/// `android/app/src/main/assets/tip_catalog.json`, which `TipCatalogAndroidExport` writes.
public enum TipCatalog {
    public static let products: [TipProduct] = [
        TipProduct(
            id: "com.justspeaktoit.tip.small", emoji: "☕", displayName: "Buy me a coffee",
            summary: "A small token of appreciation"
        ),
        TipProduct(
            id: "com.justspeaktoit.tip.medium", emoji: "🍔", displayName: "Buy me lunch",
            summary: "Help fuel development"
        ),
        TipProduct(
            id: "com.justspeaktoit.tip.large", emoji: "💪", displayName: "Generous support",
            summary: "Super supporter!"
        )
    ]

    public static var productIDs: [String] { products.map(\.id) }

    /// The emoji for a store product, or a generic heart for one this catalogue doesn't list.
    public static func emoji(for productID: String) -> String {
        products.first { $0.id == productID }?.emoji ?? "💝"
    }
}

/// The tip catalogue as JSON for the Android app. `TipCatalogAndroidExportTests` fails when the
/// committed asset is stale; regenerate it with `scripts/update-android-assets`.
public enum TipCatalogAndroidExport {
    public static func json() throws -> Data {
        struct Product: Encodable {
            let id, emoji, displayName, summary: String
        }
        struct Document: Encodable {
            let version: Int
            let products: [Product]
        }
        let document = Document(
            version: 1,
            products: TipCatalog.products.map {
                Product(id: $0.id, emoji: $0.emoji, displayName: $0.displayName, summary: $0.summary)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(document)
        data.append(0x0A)
        return data
    }
}
