import UIKit

/// Opens the containing app from the keyboard.
///
/// `extensionContext.open` does nothing in a keyboard extension, and
/// `UIApplication.shared` is unavailable to extensions, so this walks the
/// responder chain to the extension's application object and calls
/// `openURL:options:completionHandler:` on it. That three-argument selector is
/// the one that still works since iOS 18 removed the single-argument
/// `openURL:`.
enum ContainingAppOpener {
    private typealias OpenURLCompletion = @convention(block) (Bool) -> Void
    private typealias OpenURLFunction = @convention(c) (
        AnyObject, Selector, NSURL, NSDictionary, OpenURLCompletion
    ) -> Void

    @MainActor
    static func open(_ url: URL, from responder: UIResponder, completion: @escaping @MainActor (Bool) -> Void) {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var current: UIResponder? = responder
        while let candidate = current {
            if candidate is UIApplication,
               candidate.responds(to: selector),
               let implementation = candidate.method(for: selector) {
                let openURL = unsafeBitCast(implementation, to: OpenURLFunction.self)
                openURL(candidate, selector, url as NSURL, NSDictionary()) { opened in
                    Task { @MainActor in completion(opened) }
                }
                return
            }
            current = candidate.next
        }
        completion(false)
    }
}
