import Foundation

public extension DictationProfileMatcher {
    /// Linux executable identities are absolute, case-sensitive paths captured
    /// from the target process, never WM_CLASS, a window title or a basename.
    static func isFullLinuxExecutablePath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.hasSuffix("/")
            && !value.unicodeScalars.contains { $0.value < 32 }
            && value.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

public extension DictationProfile {
    var linuxExecutablePaths: [String] {
        matchers.filter { $0.kind == .linuxExecutablePath }.map(\.value)
    }

    func replacingLinuxExecutablePaths(_ paths: [String]) -> DictationProfile {
        var copy = self
        copy.matchers = matchers.filter { $0.kind != .linuxExecutablePath }
            + paths.map { DictationProfileMatcher(kind: .linuxExecutablePath, value: $0) }
        return copy
    }
}

public extension ProfileResolver {
    func profile(forLinuxExecutablePath path: String?) -> DictationProfile? {
        guard let path, DictationProfileMatcher.isFullLinuxExecutablePath(path) else { return nil }
        return profiles.first {
            $0.linuxExecutablePaths.contains(path)
        }
    }
}
