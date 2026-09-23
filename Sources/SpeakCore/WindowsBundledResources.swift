#if os(Windows) || os(Linux)
import Foundation

/// Exposes packaged data through SpeakCore's generated SwiftPM bundle accessor.
/// The Windows packaging probe validates contents without depending on Apple's
/// release-note rendering and platform catalogue types.
public enum WindowsBundledResources {
    public static var releaseNotesData: Data? {
        guard let url = Bundle.module.url(forResource: "ReleaseNotes", withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }
}
#endif
