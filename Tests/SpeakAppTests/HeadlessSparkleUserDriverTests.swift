#if !APP_STORE
import Sparkle
import XCTest

@testable import SpeakApp

/// The decision table of the headless user driver used by the release smoke
/// test. Every prompt Sparkle can raise has exactly one answer, and the run
/// reports exactly one verdict.
@MainActor
final class HeadlessSparkleUserDriverTests: XCTestCase {

    private func makeDriver(
        buildVersion: String = "202609021530"
    ) -> (HeadlessSparkleUserDriver, () -> [SparkleSmokeOutcome]) {
        let box = OutcomeBox()
        let driver = HeadlessSparkleUserDriver(currentBuildVersion: buildVersion) { outcome in
            box.outcomes.append(outcome)
        }
        return (driver, { box.outcomes })
    }

    private final class OutcomeBox {
        var outcomes: [SparkleSmokeOutcome] = []
    }

    func testPermissionRequest_allowsAutomaticChecksAndSendsNoProfile() {
        let (driver, _) = makeDriver()
        var response: SUUpdatePermissionResponse?
        driver.show(SPUUpdatePermissionRequest(systemProfile: [])) { response = $0 }

        let unwrapped = try? XCTUnwrap(response)
        XCTAssertEqual(unwrapped?.automaticUpdateChecks, true)
        XCTAssertEqual(unwrapped?.sendSystemProfile, false, "A smoke run must not phone home")
    }

    func testUpdateFound_installs() {
        XCTAssertEqual(
            HeadlessSparkleUserDriver.choiceForUpdateFound(isInformationOnlyUpdate: false),
            .install
        )
    }

    func testUpdateFound_dismissesInformationOnlyItems() {
        // Sparkle forbids replying .install to an information-only item, and
        // there is nothing to install anyway.
        XCTAssertEqual(
            HeadlessSparkleUserDriver.choiceForUpdateFound(isInformationOnlyUpdate: true),
            .dismiss
        )
    }

    func testReadyToInstallAndRelaunch_installsAndReportsInstalling() {
        let (driver, outcomes) = makeDriver(buildVersion: "202609021530")
        var choice: SPUUserUpdateChoice?
        driver.showReady(toInstallAndRelaunch: { choice = $0 })

        XCTAssertEqual(choice, .install)
        XCTAssertEqual(outcomes(), [.installing(fromVersion: "202609021530")])
    }

    func testUpdateNotFound_reportsNotFound() async {
        let (driver, outcomes) = makeDriver()
        let error = NSError(
            domain: "SUSparkleErrorDomain",
            code: 1001,
            userInfo: [NSLocalizedDescriptionKey: "You're up to date!"]
        )
        await driver.showUpdateNotFoundWithError(error)

        XCTAssertEqual(outcomes(), [.notFound(message: "You're up to date!")])
    }

    func testUpdaterError_reportsDomainCodeAndMessage() async {
        let (driver, outcomes) = makeDriver()
        let error = NSError(
            domain: "SUSparkleErrorDomain",
            code: 2001,
            userInfo: [NSLocalizedDescriptionKey: "An error occurred while extracting the archive."]
        )
        await driver.showUpdaterError(error)

        XCTAssertEqual(
            outcomes(),
            [
                .error(
                    domain: "SUSparkleErrorDomain",
                    code: 2001,
                    message: "An error occurred while extracting the archive."
                )
            ]
        )
    }

    func testOnlyTheFirstVerdictIsReported() async {
        // Sparkle can reach an install through more than one path, and an error
        // may follow a verdict during teardown. The script reads one line.
        let (driver, outcomes) = makeDriver(buildVersion: "202609021530")
        driver.showReady(toInstallAndRelaunch: { _ in })
        await driver.showUpdateInstalledAndRelaunched(true)
        await driver.showUpdaterError(NSError(domain: "late", code: 9))

        XCTAssertEqual(outcomes(), [.installing(fromVersion: "202609021530")])
    }

    func testProgressCallbacksReportNothing() {
        let (driver, outcomes) = makeDriver()
        driver.showUserInitiatedUpdateCheck(cancellation: {})
        driver.showDownloadInitiated(cancellation: {})
        driver.showDownloadDidReceiveExpectedContentLength(1_000)
        driver.showDownloadDidReceiveData(ofLength: 500)
        driver.showDownloadDidStartExtractingUpdate()
        driver.showExtractionReceivedProgress(0.5)
        driver.showInstallingUpdate(withApplicationTerminated: false, retryTerminatingApplication: {})
        driver.dismissUpdateInstallation()

        XCTAssertTrue(outcomes().isEmpty)
    }
}
#endif
