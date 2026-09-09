import Foundation

/// Use the same name and bundle as Finder and the permission guide's drag card.
/// Alpha, App Store and development builds must never direct users to another copy.
struct RunningAppIdentity {
    let bundleURL: URL
    let name: String

    static var current: Self {
        Self(bundleURL: Bundle.main.bundleURL)
    }

    init(bundleURL: URL) {
        self.bundleURL = bundleURL
        name = FileManager.default.displayName(atPath: bundleURL.path)
    }

    var recoveryInstructions: String {
        "Check that you enabled \(name), using the app shown by Show App. "
            + "Other builds and copies can have separate permissions. "
            + "If this exact app is already enabled but access is still not detected, "
            + "turn its switch off and on, then quit and reopen \(name)."
    }
}
