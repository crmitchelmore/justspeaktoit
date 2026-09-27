import Foundation

// MARK: - Linux matchers

public extension DictationProfileMatcher {
    static func isLinuxKind(_ kind: Kind) -> Bool {
        kind == .linuxExecutablePath || kind == .linuxWindowClass
    }

    /// The editor's one-line form of a Linux application: a line starting with
    /// `/` is an executable path, anything else an X11 window class. Blank
    /// lines are dropped.
    static func linuxApplication(_ line: String) -> DictationProfileMatcher? {
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return DictationProfileMatcher(
            kind: value.hasPrefix("/") ? .linuxExecutablePath : .linuxWindowClass, value: value
        )
    }

    /// A path must be absolute with no empty, `.` or `..` component and no
    /// control characters; a window class must be one word of printable text.
    static func isValidLinuxMatcher(_ matcher: DictationProfileMatcher) -> Bool {
        let value = matcher.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            return false
        }
        switch matcher.kind {
        case .linuxExecutablePath:
            guard value.hasPrefix("/"), !value.hasSuffix("/") else { return false }
            return value.dropFirst().split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
        case .linuxWindowClass:
            return !value.contains(where: \.isWhitespace) && !value.contains("/")
        default:
            return false
        }
    }
}

public extension DictationProfile {
    /// The Linux applications this profile matches, one per editor line, in
    /// stored order.
    var linuxApplications: [String] {
        matchers.filter { DictationProfileMatcher.isLinuxKind($0.kind) }.map(\.value)
    }

    /// A copy whose Linux matchers are replaced by `lines`; every other matcher
    /// keeps its value and relative order.
    func replacingLinuxApplications(_ lines: [String]) -> DictationProfile {
        var copy = self
        copy.matchers = matchers.filter { !DictationProfileMatcher.isLinuxKind($0.kind) }
            + lines.compactMap(DictationProfileMatcher.linuxApplication)
        return copy
    }
}

public extension ProfileResolver {
    /// The first profile whose Linux matcher names the captured application:
    /// its exact executable path, or its X11 window class ignoring case.
    /// Wayland hides the focused application, so there both are nil and the
    /// app's normal settings apply.
    func profile(forLinuxExecutablePath path: String?, windowClass: String?) -> DictationProfile? {
        let executable = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let windowClass = windowClass?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !executable.isEmpty || !windowClass.isEmpty else { return nil }
        return profiles.first { profile in
            profile.matchers.contains { matcher in
                let value = matcher.value.trimmingCharacters(in: .whitespacesAndNewlines)
                switch matcher.kind {
                case .linuxExecutablePath:
                    return !executable.isEmpty && value.hasPrefix("/") && value == executable
                case .linuxWindowClass:
                    return !windowClass.isEmpty && !value.isEmpty && value.lowercased() == windowClass
                default:
                    return false
                }
            }
        }
    }
}
