import Foundation

/// Headless Sparkle self-update mode, used only by
/// `scripts/sparkle-update-smoke.sh` and the release workflow's
/// `sparkle-update-smoke` job.
///
/// Nothing in CI used to exercise a real Sparkle update: releases were verified
/// by inspecting the artefacts, never by installing one. This mode lets a
/// throw-away copy of the shipped app update *itself* from a local appcast with
/// no windows, no prompts and no human, so a broken feed, signature or
/// installer fails the release run instead of a user's Mac.
///
/// The mode is inert unless `--sparkle-smoke-update` is on the command line, so
/// a normal launch never reaches any of this.
enum SparkleSmokeMode {
    /// Info.plist marker (`SpeakSparkleSmokeSupported`) the smoke script reads to
    /// decide whether the app it was handed understands the flags at all. Older
    /// releases predate this mode; the script skips rather than fails on them.
    static let supportedInfoPlistKey = "SpeakSparkleSmokeSupported"

    /// Exit status when the feed offered no update (the appcast bump failed, or
    /// Sparkle rejected the item).
    static let notFoundExitCode: Int32 = 3

    /// Exit status when Sparkle reported an error.
    static let errorExitCode: Int32 = 2

    /// Exit status when the flags themselves were unusable.
    static let usageExitCode: Int32 = 64

    static let flag = "--sparkle-smoke-update"
    static let feedURLFlag = "--sparkle-feed-url"
    static let resultFileFlag = "--sparkle-result-file"
}

/// The parsed `--sparkle-smoke-update` invocation.
struct SparkleSmokeArguments: Equatable {
    /// Feed the smoke run checks instead of the shipping appcast. Overridden
    /// through `SPUUpdaterDelegate.feedURLString(for:)`, never through
    /// `-[SPUUpdater setFeedURL:]`, which would persist into the host bundle's
    /// user defaults and outlive the run.
    let feedURLString: String

    /// File the run writes its single-line JSON verdict to.
    let resultFilePath: String

    enum ParseResult: Equatable {
        /// No `--sparkle-smoke-update` on the command line: a normal launch.
        case notRequested
        /// Smoke mode was asked for but the flags were unusable.
        case invalid(String)
        case requested(SparkleSmokeArguments)
    }

    /// Parses a full `CommandLine.arguments` array (argv[0] included is fine:
    /// the executable path never matches a flag).
    ///
    /// Accepts both `--flag value` and `--flag=value`.
    static func parse(_ arguments: [String]) -> ParseResult {
        guard arguments.contains(SparkleSmokeMode.flag) else { return .notRequested }

        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let (name, inlineValue) = splitFlag(arguments[index])
            index += 1
            guard name == SparkleSmokeMode.feedURLFlag || name == SparkleSmokeMode.resultFileFlag else {
                continue
            }
            guard let value = inlineValue ?? takeValue(from: arguments, at: &index), !value.isEmpty else {
                return .invalid("\(name) requires a value")
            }
            values[name] = value
        }
        return validate(values)
    }

    /// Splits `--flag=value` into its two halves; `--flag` yields no value.
    private static func splitFlag(_ argument: String) -> (name: String, value: String?) {
        guard let separator = argument.firstIndex(of: "=") else { return (argument, nil) }
        return (
            String(argument[argument.startIndex..<separator]),
            String(argument[argument.index(after: separator)...])
        )
    }

    /// Consumes the next argument as a value, unless it is itself a flag — so a
    /// missing value is reported rather than silently swallowing `--sparkle-…`.
    private static func takeValue(from arguments: [String], at index: inout Int) -> String? {
        guard index < arguments.count, !arguments[index].hasPrefix("--") else { return nil }
        defer { index += 1 }
        return arguments[index]
    }

    private static func validate(_ values: [String: String]) -> ParseResult {
        guard let feedURLString = values[SparkleSmokeMode.feedURLFlag] else {
            return .invalid("\(SparkleSmokeMode.flag) requires \(SparkleSmokeMode.feedURLFlag)")
        }
        guard let resultFilePath = values[SparkleSmokeMode.resultFileFlag] else {
            return .invalid("\(SparkleSmokeMode.flag) requires \(SparkleSmokeMode.resultFileFlag)")
        }
        guard let scheme = URL(string: feedURLString)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .invalid("\(SparkleSmokeMode.feedURLFlag) must be an http or https URL")
        }
        return .requested(
            SparkleSmokeArguments(feedURLString: feedURLString, resultFilePath: resultFilePath)
        )
    }
}

/// What the headless run decided, in the shape the smoke script asserts on.
enum SparkleSmokeOutcome: Equatable {
    /// Sparkle has accepted the update and is about to swap the bundle and
    /// relaunch. The process is killed by Sparkle moments later, so this is the
    /// last thing the run can say about itself.
    case installing(fromVersion: String)
    case notFound(message: String)
    case error(domain: String, code: Int, message: String)

    var jsonObject: [String: Any] {
        switch self {
        case .installing(let fromVersion):
            return ["result": "installing", "from": fromVersion]
        case .notFound(let message):
            return ["result": "not_found", "message": message]
        case .error(let domain, let code, let message):
            return ["result": "error", "domain": domain, "code": code, "message": message]
        }
    }

    /// `nil` for `.installing`: the process must stay alive so Sparkle can
    /// terminate and relaunch it.
    var exitCode: Int32? {
        switch self {
        case .installing: return nil
        case .notFound: return SparkleSmokeMode.notFoundExitCode
        case .error: return SparkleSmokeMode.errorExitCode
        }
    }
}

/// Writes the verdict where the script can read it.
///
/// Written atomically and flushed before any `exit(_:)`, because the interesting
/// outcome (`installing`) is followed by Sparkle killing this process.
struct SparkleSmokeResultWriter {
    let path: String

    func write(_ outcome: SparkleSmokeOutcome) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: outcome.jsonObject,
            options: [.sortedKeys]
        ) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
