import Foundation
import SpeakCore
import SpeakDesktop

/// The catalogues behind each host's **Browse OpenRouter models…** dialog (#1618).
/// Hosts publish the cleanup browser with every post-processing list and the
/// transcription browser with every model-slot update; the native dialog queries
/// it synchronously on its UI thread through `DesktopNativeBindings`.
package enum DesktopHostOpenRouterBrowser {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var browsers: [OpenRouterModelBrowserCatalog.Purpose: DesktopOpenRouterBrowser] = [:]
    }
    private static let storage = Storage()

    package static func publish(_ browser: DesktopOpenRouterBrowser) {
        storage.lock.withLock { storage.browsers[browser.purpose] = browser }
    }

    package static func browser(for purpose: OpenRouterModelBrowserCatalog.Purpose) -> DesktopOpenRouterBrowser? {
        storage.lock.withLock { storage.browsers[purpose] }
    }

    /// The native purpose number (`JSTI_OPENROUTER_BROWSER_*`).
    package static func purpose(_ value: Int32) -> OpenRouterModelBrowserCatalog.Purpose? {
        switch value {
        case 0: return .cleanup
        case 1: return .transcription
        default: return nil
        }
    }

    /// One filtered page, or nil when the purpose is unknown or not yet published.
    package static func page(
        purpose value: Int32, query: String, provider: String, zeroPricesOnly: Bool, selectedSlot: Int32
    ) -> DesktopOpenRouterBrowser.Page? {
        guard let purpose = purpose(value), let browser = browser(for: purpose) else { return nil }
        return browser.page(
            matching: OpenRouterBrowserFilter(
                query: String(query.prefix(256)), provider: provider, freeOnly: zeroPricesOnly
            ),
            selectedSlot: selectedSlot
        )
    }

    /// Provider metadata is untrusted: bound each line and replace embedded
    /// controls, keeping the details pane's line breaks.
    package static func nativeText(_ value: String) -> String {
        value.split(separator: "\n", omittingEmptySubsequences: false)
            .map { DesktopHostModels.uiText(String($0)) }.joined(separator: "\n")
    }
}
