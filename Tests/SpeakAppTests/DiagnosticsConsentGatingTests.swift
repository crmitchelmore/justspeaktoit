import XCTest

@testable import SpeakApp
import SpeakCore

#if canImport(Sentry)
@_spi(Private) import Sentry
#endif

/// Crash reporting is opt-in (App Review 5.1.1): nothing starts the SDK before
/// consent, and withdrawal stops it and deletes reports not yet sent.
final class DiagnosticsConsentGatingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var caches: URL!

    override func setUpWithError() throws {
        suiteName = "DiagnosticsConsentGatingTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        caches = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        SentryManager.stop()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: caches)
    }

    #if canImport(Sentry)
    func testStart_withoutADecision_leavesTheSDKStopped() {
        SentryManager.start(consent: DiagnosticsConsent(defaults: defaults))

        XCTAssertFalse(SentrySDK.isEnabled)
    }

    func testStart_afterDeclining_leavesTheSDKStopped() {
        let consent = DiagnosticsConsent(defaults: defaults, notificationCenter: NotificationCenter())
        consent.record(granted: false)

        SentryManager.start(consent: consent)

        XCTAssertFalse(SentrySDK.isEnabled)
    }

    func testApplyConsent_startsOnGrantAndClosesOnWithdrawal() {
        let consent = DiagnosticsConsent(defaults: defaults, notificationCenter: NotificationCenter())
        consent.record(granted: true)

        SentryManager.applyConsent(consent)
        XCTAssertTrue(SentrySDK.isEnabled)

        consent.record(granted: false)
        SentryManager.applyConsent(consent)
        XCTAssertFalse(SentrySDK.isEnabled)
    }

    func testConfigure_keepsReportsInTheAppOwnedDirectory() {
        let options = Sentry.Options()

        SentryManager.configure(options)

        XCTAssertEqual(options.cacheDirectoryPath, SentryManager.storage.directory.path)
    }

    func testDSNHash_matchesTheSDKQueueFolderName() throws {
        let dsn = try SentryDsn(string: SentryManager.destination.dsn)

        XCTAssertEqual(SentryManager.dsnHash, dsn.getHash())
    }
    #endif

    func testPurge_removesThisAppsReportsAndKeepsOtherAppsData() throws {
        let storage = DiagnosticsStorage(caches: caches, bundleIdentifier: "com.example.app", bundleName: "Example")
        let hash = try XCTUnwrap(SentryManager.dsnHash ?? "nohash")
        let own = [
            storage.directory.appendingPathComponent("envelopes/1.envelope"),
            caches.appendingPathComponent("io.sentry/\(hash)/envelopes/2.envelope"),
            caches.appendingPathComponent("SentryCrash/Example/Reports/report.json")
        ]
        let others = [
            caches.appendingPathComponent("io.sentry/someoneelse/envelopes/3.envelope"),
            caches.appendingPathComponent("SentryCrash/Other/Reports/report.json"),
            caches.appendingPathComponent("unrelated.txt")
        ]
        for file in own + others { try write(file) }

        SentryManager.purgeLocalData(storage)

        let survivors = (own + others).filter { FileManager.default.fileExists(atPath: $0.path) }
        #if os(iOS)
        XCTAssertEqual(survivors, [caches.appendingPathComponent("unrelated.txt")])
        #else
        if SentryManager.dsnHash == nil {
            XCTAssertEqual(survivors, [own[1]] + others)
        } else {
            XCTAssertEqual(survivors, others)
        }
        #endif
    }

    private func write(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }
}
