import AppKit

/// Use the same name and bundle as Finder and the permission guide's drag card.
/// Alpha, App Store and development builds must never direct users to another copy.
struct RunningAppIdentity: Sendable {
    let bundleURL: URL
    let name: String

    static var current: Self {
        Self(bundleURL: Bundle.main.bundleURL)
    }

    init(bundleURL: URL) {
        self.bundleURL = bundleURL
        name = Self.displayName(for: bundleURL)
    }

    /// System Settings labels an app by its bundle display name (VS Code appears as
    /// "Code"), while Finder shows the file name ("JustSpeakToIt" for the Stable
    /// install). Prefer the name the privacy lists use; fall back to Finder's.
    static func displayName(for bundleURL: URL) -> String {
        let bundle = Bundle(url: bundleURL)
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = bundle?.localizedInfoDictionary?[key] as? String, !name.isEmpty {
                return name
            }
            if let name = bundle?.infoDictionary?[key] as? String, !name.isEmpty {
                return name
            }
        }
        return FileManager.default.displayName(atPath: bundleURL.path)
    }

    func revealInFinder(
        using reveal: @escaping @Sendable (URL) -> Bool = { url in
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
        }
    ) async -> Bool {
        let url = bundleURL
        // Finder may block while resolving a bundle on an external volume.
        // Never let its synchronous workspace API block our permission UI.
        return await Task.detached(priority: .userInitiated) { reveal(url) }.value
    }

    var recoveryInstructions: String {
        "Check that you enabled \(name), using the app shown by Show App. "
            + "Other builds and copies can have separate permissions. "
            + "If this exact app is already enabled but access is still not detected, "
            + "turn its switch off and on, then quit and reopen \(name)."
    }
}
