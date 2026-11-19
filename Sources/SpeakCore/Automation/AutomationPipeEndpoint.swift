import Foundation

/// Names the Windows named pipe the app listens on and the `speak` client
/// opens, so both ends derive it from one policy.
///
/// The Windows counterpart of `AutomationEndpoint.socketPath()`. Pipe names are
/// global to the machine rather than to a user or session, so the default is
/// scoped by release train and by the user's SID: two signed-in users, or an
/// Alpha app beside a Stable one, never contend for the same endpoint. The name
/// is not the access control — the pipe's owner-only DACL is.
public enum AutomationPipeEndpoint {
    /// Overrides the pipe name; used by tests and by anyone running a second app
    /// instance. Read by the app and the CLI alike so they cannot disagree.
    public static let environmentKey = "SPEAK_AUTOMATION_PIPE"
    /// The only namespace accepted: this machine's named-pipe file system.
    public static let localPrefix = #"\\.\pipe\"#
    /// `CreateNamedPipe`'s limit for the whole name, in UTF-16 code units.
    public static let maxNameLength = 256

    /// The pipe for `userSID` (a string SID such as `S-1-5-21-…`), unless the
    /// environment overrides it.
    public static func pipeName(
        userSID: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        train: ReleaseTrain = .current
    ) throws -> String {
        if let override = environment[self.environmentKey], !override.isEmpty {
            return try self.validated(override)
        }
        guard self.isStringSID(userSID) else {
            throw AutomationError(
                code: .internalError,
                message: "Could not identify the current Windows user for the automation endpoint."
            )
        }
        return try self.validated(
            self.localPrefix + "JustSpeakToIt-\(train.supportDirectory)-automation-\(userSID)"
        )
    }

    /// Accepts `\\.\pipe\<name>` (any case) or a bare `<name>`, returning the full
    /// local form.
    ///
    /// Anything addressing another machine or namespace is refused rather than
    /// normalised: opening `\\host\pipe\…` would send this user's network
    /// credentials to that host, and the app never listens there.
    public static func validated(_ candidate: String) throws -> String {
        let leaf: Substring
        if candidate.utf16.count >= self.localPrefix.utf16.count,
           candidate.prefix(self.localPrefix.count).lowercased() == self.localPrefix {
            leaf = candidate.dropFirst(self.localPrefix.count)
        } else if candidate.hasPrefix(#"\\"#) || candidate.hasPrefix("//") {
            throw self.invalidName
        } else {
            leaf = Substring(candidate)
        }
        guard !leaf.isEmpty,
              !leaf.contains("\\"),
              !leaf.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              self.localPrefix.utf16.count + leaf.utf16.count <= self.maxNameLength else {
            throw self.invalidName
        }
        return self.localPrefix + leaf
    }

    /// `S-1-<authority>-<subauthority>…`: digits only after the revision.
    static func isStringSID(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "S", parts[1] == "1" else { return false }
        return parts.dropFirst().allSatisfy { part in
            !part.isEmpty && part.count <= 20 && part.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    private static var invalidName: AutomationError {
        AutomationError(
            code: .invalidArgument,
            message: "\(self.environmentKey) must name a pipe on this computer, such as "
                + #"\\.\pipe\speak-automation, of at most \#(self.maxNameLength) characters."#
        )
    }
}
