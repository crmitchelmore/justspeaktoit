import AppKit
import Foundation
#if !APP_STORE
import Sparkle
#endif

/// The process-wide answer to "was this launch a Sparkle smoke run?".
///
/// Parsed once, from the real command line, so every guard in the app agrees
/// and a normal launch pays for one `contains` check.
enum SparkleSmokeSession {
    static let parseResult = SparkleSmokeArguments.parse(CommandLine.arguments)

    /// True when `--sparkle-smoke-update` was passed, including when the rest of
    /// the flags were wrong — a malformed smoke invocation must fail loudly, not
    /// silently launch the real app in front of a script that is waiting on it.
    static var isActive: Bool {
        if case .notRequested = parseResult { return false }
        return true
    }

    /// Takes the process over: starts the headless update and never returns to
    /// normal startup. Call only when `isActive`.
    @MainActor
    static func begin() {
        switch parseResult {
        case .notRequested:
            return
        case .invalid(let reason):
            FileHandle.standardError.write(Data("sparkle smoke: \(reason)\n".utf8))
            exit(SparkleSmokeMode.usageExitCode)
        case .requested(let arguments):
            start(arguments)
        }
    }

#if !APP_STORE
    /// Retained for the lifetime of the process: Sparkle holds its updater
    /// weakly enough that dropping this would end the run.
    private static var runner: SparkleSmokeRunner?

    @MainActor
    private static func start(_ arguments: SparkleSmokeArguments) {
        let runner = SparkleSmokeRunner(arguments: arguments)
        self.runner = runner
        runner.start()
    }
#else
    @MainActor
    private static func start(_ arguments: SparkleSmokeArguments) {
        // Mac App Store builds do not embed Sparkle and never self-update.
        FileHandle.standardError.write(Data("sparkle smoke: unsupported in App Store builds\n".utf8))
        exit(SparkleSmokeMode.usageExitCode)
    }
#endif
}

#if !APP_STORE
/// Drives one headless Sparkle update against a local feed.
///
/// Deliberately separate from `UpdaterManager`: the shipping path keeps its
/// `SPUStandardUpdaterController` and its standard user driver untouched, and
/// this builds its own `SPUUpdater` with `HeadlessSparkleUserDriver`.
@MainActor
final class SparkleSmokeRunner {
    private let arguments: SparkleSmokeArguments
    private let writer: SparkleSmokeResultWriter
    private let feedDelegate: SparkleSmokeUpdaterDelegate
    private var updater: SPUUpdater?
    private var driver: HeadlessSparkleUserDriver?

    init(arguments: SparkleSmokeArguments) {
        self.arguments = arguments
        writer = SparkleSmokeResultWriter(path: arguments.resultFilePath)
        feedDelegate = SparkleSmokeUpdaterDelegate(feedURLString: arguments.feedURLString)
    }

    func start() {
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let writer = self.writer
        let driver = HeadlessSparkleUserDriver(currentBuildVersion: buildVersion) { outcome in
            writer.write(outcome)
            if let exitCode = outcome.exitCode {
                exit(exitCode)
            }
            // `.installing` intentionally does not exit: Sparkle terminates and
            // relaunches this process itself, and that relaunch is what the
            // smoke script asserts on.
        }
        self.driver = driver

        // The host and application bundle are both the launched copy — a
        // throw-away app in a temp directory. Sparkle therefore reads and writes
        // that bundle's own preference domain, and the feed override travels
        // through the delegate rather than the deprecated
        // `-[SPUUpdater setFeedURL:]`, which would persist the test feed into
        // user defaults and follow the machine after the run.
        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: driver,
            delegate: feedDelegate
        )
        self.updater = updater

        do {
            try updater.start()
        } catch {
            let nsError = error as NSError
            writer.write(
                .error(domain: nsError.domain, code: nsError.code, message: nsError.localizedDescription)
            )
            exit(SparkleSmokeMode.errorExitCode)
        }
        updater.checkForUpdates()
    }
}

/// Points one smoke run at its local feed and nothing else.
///
/// `UpdaterManager`'s delegate is untouched: the shipping build still resolves
/// its feed through `UpdateFeedSelection`, and no code path can reach this
/// override without `--sparkle-smoke-update` on the command line.
final class SparkleSmokeUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    private let feedURLString: String

    init(feedURLString: String) {
        self.feedURLString = feedURLString
        super.init()
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        feedURLString
    }
}
#endif
