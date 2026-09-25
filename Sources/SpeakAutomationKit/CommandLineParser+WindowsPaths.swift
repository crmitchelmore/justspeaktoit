import Foundation

extension CommandLineParser {
    /// The Windows form of `absolutePath(for:currentDirectory:)`, compiled on every
    /// platform so its rules are tested everywhere.
    ///
    /// Resolves the way the caller's own process would open the path: `/` becomes
    /// `\`, `.` and `..` collapse without climbing above the drive or share,
    /// root-relative (`\audio\clip.m4a`) and drive-relative (`D:clip.m4a`) forms
    /// take the current directory's drive or share, and `\\?\` / `\\.\` device
    /// paths pass through verbatim. A leading `~` expands to the user profile.
    /// Another drive's own current directory is not visible to a process, so
    /// `D:clip.m4a` from a `C:` directory resolves at the root of `D:`.
    static func windowsAbsolutePath(for path: String, currentDirectory: String, homeDirectory: String?) -> String {
        if Self.isWindowsDevicePath(path) { return path }
        var candidate = path.replacingOccurrences(of: "/", with: "\\")
        if let home = homeDirectory, !home.isEmpty, candidate == "~" || candidate.hasPrefix("~\\") {
            candidate = Self.windowsNativeDirectory(home) + candidate.dropFirst()
        }
        let directory = Self.windowsNativeDirectory(currentDirectory)
        let base = Self.windowsRoot(of: directory)

        if candidate.hasPrefix("\\\\") {
            let root = Self.windowsRoot(of: candidate)
            return Self.windowsJoin(root: root.root, components: [root.remainder])
        }
        if let drive = Self.windowsDrive(of: candidate) {
            let rest = String(candidate.dropFirst(2))
            if rest.hasPrefix("\\") {
                return Self.windowsJoin(root: drive, components: [rest])
            }
            // Drive-relative: the current directory when it is on that drive.
            if base.root.caseInsensitiveCompare(drive) == .orderedSame {
                return Self.windowsJoin(root: drive, components: [base.remainder, rest])
            }
            return Self.windowsJoin(root: drive, components: [rest])
        }
        if candidate.hasPrefix("\\") {
            return Self.windowsJoin(root: base.root, components: [candidate])
        }
        return Self.windowsJoin(root: base.root, components: [base.remainder, candidate])
    }

    /// `\\?\…` and `\\.\…` address the Win32 device namespace; Windows does not
    /// normalise them, so neither does the CLI.
    private static func isWindowsDevicePath(_ path: String) -> Bool {
        let prefix = path.prefix(4).replacingOccurrences(of: "/", with: "\\")
        return prefix == "\\\\?\\" || prefix == "\\\\.\\"
    }

    /// Foundation may report a directory as `/C:/Users/…`; the wire carries `C:\Users\…`.
    private static func windowsNativeDirectory(_ directory: String) -> String {
        var native = directory.replacingOccurrences(of: "/", with: "\\")
        if native.hasPrefix("\\"), Self.windowsDrive(of: String(native.dropFirst())) != nil {
            native.removeFirst()
        }
        return native
    }

    /// `X:` for a path starting with a drive letter and colon.
    private static func windowsDrive(of path: String) -> String? {
        let characters = Array(path.prefix(2))
        guard characters.count == 2, characters[1] == ":",
              let letter = characters[0].unicodeScalars.first,
              characters[0].unicodeScalars.count == 1,
              (65...90).contains(letter.value) || (97...122).contains(letter.value) else { return nil }
        return String(characters)
    }

    /// Splits an absolute path into its drive (`C:`) or share (`\\server\share`)
    /// and the rest.
    private static func windowsRoot(of path: String) -> (root: String, remainder: String) {
        if path.hasPrefix("\\\\") {
            let parts = path.dropFirst(2).split(separator: "\\", maxSplits: 2, omittingEmptySubsequences: false)
            let root = "\\\\" + parts.prefix(2).joined(separator: "\\")
            return (root, parts.count > 2 ? String(parts[2]) : "")
        }
        if let drive = Self.windowsDrive(of: path) {
            return (drive, String(path.dropFirst(2)))
        }
        return ("", path)
    }

    /// Joins components under `root`, collapsing `.` and `..` without leaving it.
    private static func windowsJoin(root: String, components: [String]) -> String {
        var resolved: [Substring] = []
        for component in components {
            for part in component.split(separator: "\\") {
                switch part {
                case ".":
                    continue
                case "..":
                    if !resolved.isEmpty { resolved.removeLast() }
                default:
                    resolved.append(part)
                }
            }
        }
        return root + "\\" + resolved.joined(separator: "\\")
    }
}
