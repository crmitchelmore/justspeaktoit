#if !APP_STORE
import Foundation
import Sparkle

/// An `SPUUserDriver` that answers every Sparkle prompt in favour of installing,
/// with no UI at all.
///
/// Only `SparkleSmokeRunner` builds one, and only when
/// `--sparkle-smoke-update` was passed. The normal app keeps using
/// `SPUStandardUpdaterController`'s standard user driver.
///
/// It is a plain object with an injected `report` closure rather than something
/// that writes files and calls `exit(_:)` itself, so the decision table below
/// can be driven directly from unit tests.
@MainActor
final class HeadlessSparkleUserDriver: NSObject, SPUUserDriver {
    /// Build number of the bundle that started the run, echoed back in the
    /// `installing` verdict so the script can tell which copy updated itself.
    private let currentBuildVersion: String
    private let report: (SparkleSmokeOutcome) -> Void

    /// Sparkle can reach the install decision through more than one path
    /// (`showReadyToInstallAndRelaunch:` normally, `showUpdateInstalledAndRelaunched:`
    /// if we survive long enough). The verdict is reported once.
    private var hasReportedOutcome = false

    init(currentBuildVersion: String, report: @escaping (SparkleSmokeOutcome) -> Void) {
        self.currentBuildVersion = currentBuildVersion
        self.report = report
        super.init()
    }

    private func reportOnce(_ outcome: SparkleSmokeOutcome) {
        guard !hasReportedOutcome else { return }
        hasReportedOutcome = true
        report(outcome)
    }

    // MARK: - Decisions

    /// Never reached in practice (the shipping Info.plist sets
    /// `SUEnableAutomaticChecks`, so Sparkle does not ask), but answering "yes,
    /// automatic checks are fine" keeps the run from stalling on a build where
    /// the key is missing.
    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    /// `SUAppcastItem` and `SPUUserUpdateState` have no public initialisers, so
    /// the decision itself is factored out here where a test can reach it.
    ///
    /// An information-only item has nothing to install and Sparkle forbids
    /// replying `.install` to one, so it counts as "no update".
    static func choiceForUpdateFound(isInformationOnlyUpdate: Bool) -> SPUUserUpdateChoice {
        isInformationOnlyUpdate ? .dismiss : .install
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        if appcastItem.isInformationOnlyUpdate {
            reportOnce(.notFound(message: "feed offered an information-only update"))
        }
        reply(Self.choiceForUpdateFound(isInformationOnlyUpdate: appcastItem.isInformationOnlyUpdate))
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Last point at which this process is guaranteed to be alive: replying
        // .install lets Sparkle quit and replace the bundle underneath us.
        reportOnce(.installing(fromVersion: currentBuildVersion))
        reply(.install)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool) async {
        reportOnce(.installing(fromVersion: currentBuildVersion))
    }

    func showUpdateNotFoundWithError(_ error: any Error) async {
        reportOnce(.notFound(message: error.localizedDescription))
    }

    func showUpdaterError(_ error: any Error) async {
        let nsError = error as NSError
        reportOnce(
            .error(
                domain: nsError.domain,
                code: nsError.code,
                message: nsError.localizedDescription
            )
        )
    }

    // MARK: - Progress and teardown (nothing to show)

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}
    func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {}
    func dismissUpdateInstallation() {}
}
#endif
