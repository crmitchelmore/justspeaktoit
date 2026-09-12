import AppKit
import SpeakCore

/// Onboarding uses the same multi-resolution artwork as Finder and the Dock.
enum AppIconProvider {
    private static let cachedIcon: NSImage = {
        let iconName = ReleaseTrain.current == .alpha ? "AppIconAlpha" : "AppIcon"
        if let url = Bundle.main.url(forResource: iconName, withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: iconName, withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        #endif
        // A host preview may supply its own application icon.
        return NSImage(named: NSImage.applicationIconName) ?? NSImage(size: .zero)
    }()

    static func applicationIcon() -> NSImage { cachedIcon }
}
