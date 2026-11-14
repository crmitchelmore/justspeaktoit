import Foundation
import SpeakCore
@testable import SpeakDesktop
import XCTest

private actor RecordingTelemetryHTTP: DesktopTelemetryHTTP {
    struct Post: Sendable {
        let url: URL
        let headers: [String: String]
        let body: Data
    }

    private(set) var posts: [Post] = []

    func post(_ url: URL, headers: [String: String], body: Data) async throws -> Int {
        posts.append(Post(url: url, headers: headers, body: body))
        return 200
    }

    func analytics() -> [[String: Any]] {
        posts.filter { $0.url == DesktopPostHogSink.endpoint }.compactMap {
            try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any]
        }
    }

    func crashReports() -> [Post] { posts.filter { $0.url == DesktopSentryEnvelope.endpoint } }
}

/// Holds every request until `release()`, so a test can fill the queue while one send is in flight.
private actor GatedTelemetryHTTP: DesktopTelemetryHTTP {
    private(set) var count = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func post(_ url: URL, headers: [String: String], body: Data) async throws -> Int {
        count += 1
        if !released { await withCheckedContinuation { waiters.append($0) } }
        throw URLError(.timedOut)
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private struct SampleError: LocalizedError {
    var errorDescription: String? {
        "Could not insert \"hello my secret transcript\" with sk-abcdefghijklmnopqrstuvwx into /home/alice/notes.txt"
    }
}

final class DesktopTelemetryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("telemetry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func configuration(reportsCrashes: Bool = true, key: String = "phc_test") -> DesktopTelemetryConfiguration {
        DesktopTelemetryConfiguration(
            context: ProductAnalyticsContext(
                platform: .linux, appVersion: "1.2.3", build: "45", osMajorMinor: "24.4",
                distributionChannel: .direct, localeLanguageCode: "en-GB", architecture: "x86_64"
            ),
            release: "just-speak-to-it-linux@1.2.3", environment: "production", reportsCrashes: reportsCrashes,
            postHogProjectKey: key
        )
    }

    private var sentinel: URL { directory.appendingPathComponent(DesktopTelemetry.sentinelName) }

    func testConsentOff_SendsNothingEvenAfterAnAbnormalExit() async throws {
        let http = RecordingTelemetryHTTP()
        FileManager.default.createFile(atPath: sentinel.path, contents: Data("{}".utf8))
        let telemetry = DesktopTelemetry(directory: directory)
        await telemetry.activate(configuration(), http: http)
        await telemetry.transcriptionSucceeded(provider: .openAI, engine: .cloud)
        await telemetry.reportFatal(SampleError())
        await telemetry.flushAnalytics()

        let posts = await http.posts
        XCTAssertTrue(posts.isEmpty)
        let state = telemetry.store.snapshot()
        XCTAssertEqual(state.analyticsConsent, .unknown)
        XCTAssertEqual(state.diagnosticsConsent, .undecided)
        XCTAssertNil(state.installationID)
        XCTAssertFalse(state.firstTranscriptionReported)
    }

    func testOptIn_SendsPostHogEnvelopeWithAnonymousInstallID() async throws {
        let http = RecordingTelemetryHTTP()
        let telemetry = DesktopTelemetry(directory: directory)
        await telemetry.activate(configuration(), http: http)
        await telemetry.updateConsent(analytics: true, diagnostics: nil)
        await telemetry.transcriptionSucceeded(provider: .openAI, engine: .cloud)
        await telemetry.transcriptionSucceeded(provider: .openAI, engine: .cloud)
        await telemetry.flushAnalytics()

        let events = await http.analytics()
        XCTAssertEqual(
            events.compactMap { $0["event"] as? String },
            ["analytics_opt_in", "app_active_daily", "first_transcription_succeeded"]
        )
        let installID = try XCTUnwrap(telemetry.store.snapshot().installationID).uuidString
        for event in events {
            XCTAssertEqual(event["api_key"] as? String, "phc_test")
            let properties = try XCTUnwrap(event["properties"] as? [String: Any])
            XCTAssertEqual(properties["$geoip_disable"] as? Bool, true)
            XCTAssertEqual(properties["platform"] as? String, "linux")
            XCTAssertEqual(properties["app_version"] as? String, "1.2.3")
            XCTAssertNotNil(properties["timestamp"] as? String)
            let distinct = try XCTUnwrap(properties["distinct_id"] as? String)
            XCTAssertTrue([installID, "anonymous-counter"].contains(distinct))
        }
        let first = try XCTUnwrap(events.last?["properties"] as? [String: Any])
        XCTAssertEqual(first["provider_type"] as? String, "openai")
        XCTAssertEqual(first["engine_type"] as? String, "cloud")
        let posts = await http.posts
        XCTAssertTrue(posts.allSatisfy { $0.headers["Content-Type"] == "application/json" })
        XCTAssertTrue(posts.allSatisfy { $0.url.host == "eu.i.posthog.com" })
    }

    func testOptIn_WithoutProjectKey_SendsNothing() async throws {
        let http = RecordingTelemetryHTTP()
        let telemetry = DesktopTelemetry(directory: directory)
        await telemetry.activate(configuration(key: " "), http: http)
        await telemetry.updateConsent(analytics: true, diagnostics: nil)
        await telemetry.flushAnalytics()
        let posts = await http.posts
        XCTAssertTrue(posts.isEmpty)
    }

    func testOptOut_DeletesInstallIDAndStopsSending() async throws {
        let http = RecordingTelemetryHTTP()
        let telemetry = DesktopTelemetry(directory: directory)
        await telemetry.activate(configuration(), http: http)
        await telemetry.updateConsent(analytics: true, diagnostics: nil)
        await telemetry.flushAnalytics()
        let sent = await http.posts.count
        await telemetry.updateConsent(analytics: false, diagnostics: nil)
        await telemetry.transcriptionSucceeded(provider: .openAI, engine: .cloud)
        await telemetry.flushAnalytics()

        let after = await http.posts.count
        XCTAssertEqual(after, sent)
        XCTAssertEqual(telemetry.store.snapshot().analyticsConsent, .optedOut)
        XCTAssertNil(telemetry.store.snapshot().installationID)
    }

    func testDiagnosticsGranted_SendsScrubbedSentryEnvelope() async throws {
        let http = RecordingTelemetryHTTP()
        let telemetry = DesktopTelemetry(directory: directory)
        await telemetry.activate(configuration(), http: http)
        await telemetry.updateConsent(analytics: nil, diagnostics: true)
        await telemetry.reportFatal(SampleError())

        let reports = await http.crashReports()
        XCTAssertEqual(reports.count, 1)
        let post = try XCTUnwrap(reports.first)
        XCTAssertEqual(post.headers["Content-Type"], "application/x-sentry-envelope")
        XCTAssertTrue(post.headers["X-Sentry-Auth"]?.contains("sentry_key=") == true)
        let lines = post.body.split(separator: 0x0A, omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[3].isEmpty)
        let item = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[1])) as? [String: Any])
        XCTAssertEqual(item["type"] as? String, "event")
        XCTAssertEqual(item["length"] as? Int, lines[2].count)
        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[2])) as? [String: Any])
        XCTAssertEqual(event["level"] as? String, "fatal")
        XCTAssertEqual(event["release"] as? String, "just-speak-to-it-linux@1.2.3")
        XCTAssertNil(event["user"])
        XCTAssertNil(event["server_name"])
        XCTAssertNil(event["request"])
        let text = try XCTUnwrap(String(bytes: post.body, encoding: .utf8))
        XCTAssertFalse(text.contains("hello my secret transcript"))
        XCTAssertFalse(text.contains("sk-abcdefghijklmnopqrstuvwx"))
        XCTAssertFalse(text.contains("alice"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testCrashReports_NeverLeaveDevelopmentBuilds() async throws {
        let http = RecordingTelemetryHTTP()
        let telemetry = DesktopTelemetry(directory: directory)
        await telemetry.activate(configuration(reportsCrashes: false), http: http)
        await telemetry.updateConsent(analytics: nil, diagnostics: true)
        await telemetry.reportFatal(SampleError())
        let reports = await http.crashReports()
        XCTAssertTrue(reports.isEmpty)
    }

    func testAbnormalExit_IsReportedOnceOnTheNextLaunch() async throws {
        let http = RecordingTelemetryHTTP()
        try DesktopTelemetryStore(directory: directory).update { $0.diagnosticsConsent = .granted }

        let first = DesktopTelemetry(directory: directory)
        await first.activate(configuration(), http: http)
        let afterFirst = await http.crashReports().count
        XCTAssertEqual(afterFirst, 0, "a first launch has no previous session")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))

        // The first session never finished: the next launch reports it once.
        let second = DesktopTelemetry(directory: directory)
        await second.activate(configuration(), http: http)
        let reports = await http.crashReports()
        XCTAssertEqual(reports.count, 1)
        let text = try XCTUnwrap(String(bytes: try XCTUnwrap(reports.first).body, encoding: .utf8))
        XCTAssertTrue(text.contains("abnormal_exit"))
        await second.finishCleanly()
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))

        let third = DesktopTelemetry(directory: directory)
        await third.activate(configuration(), http: http)
        let afterThird = await http.crashReports().count
        XCTAssertEqual(afterThird, 1)
    }

    func testConsentKeys_AreNeverInTheAutomationSchema() {
        for key in DesktopTelemetryConsent.projectionKeys.union([ShellPreference.analyticsKey]) {
            XCTAssertNil(SettingsSchema.field(forKey: key, platform: .linux), key)
            XCTAssertNil(SettingsSchema.field(forKey: key, platform: .windows), key)
        }
    }

    func testCorruptState_FailsClosed() throws {
        let url = directory.appendingPathComponent(DesktopTelemetryStore.fileName)
        try Data(#"{"desktopAnalyticsConsent":"yes please","desktopDiagnosticsConsent":true}"#.utf8).write(to: url)
        let state = DesktopTelemetryStore(directory: directory).snapshot()
        XCTAssertEqual(state.analyticsConsent, .unknown)
        XCTAssertEqual(state.diagnosticsConsent, .undecided)

        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(DesktopTelemetryStore(directory: directory).snapshot(), DesktopTelemetryState())
    }

    func testPostHogQueue_IsBoundedAndDropsFailures() async throws {
        let http = GatedTelemetryHTTP()
        let sink = DesktopPostHogSink(projectKey: "phc_test", http: http)
        try await sink.reopen()
        let context = configuration().context
        for _ in 0..<(DesktopPostHogSink.queueLimit * 3) {
            try await sink.capture(ProductAnalyticsPayload(event: .appActiveDaily, context: context, distinctID: nil))
        }
        await http.release()
        await sink.flush()
        // One event may already be in flight when the queue fills; every failed post is dropped, never retried.
        let count = await http.count
        XCTAssertGreaterThanOrEqual(count, DesktopPostHogSink.queueLimit)
        XCTAssertLessThanOrEqual(count, DesktopPostHogSink.queueLimit + 1)

        await sink.close()
        try await sink.capture(ProductAnalyticsPayload(event: .appActiveDaily, context: context, distinctID: nil))
        await sink.flush()
        let afterClose = await http.count
        XCTAssertEqual(afterClose, count)
    }
}

final class DesktopTelemetryScrubberTests: XCTestCase {
    private func scrub(_ text: String) -> String {
        DesktopTelemetryScrubber.scrub(text, homeDirectory: "/home/alice")
    }

    func testScrub_RemovesTranscriptTextAndSecrets() {
        let scrubbed = scrub(
            #"Failed on "please email the board" with Bearer abc.def.ghi and api_key=sk-live-123 "#
                + "sk-proj-ABCDEFGHIJKLMNOP1234 for person@example.com"
        )
        for leaked in ["please email the board", "abc.def.ghi", "sk-live-123", "ABCDEFGHIJKLMNOP1234", "person@"] {
            XCTAssertFalse(scrubbed.contains(leaked), "\(leaked) leaked into \(scrubbed)")
        }
        XCTAssertTrue(scrubbed.contains("[text]"))
        XCTAssertTrue(scrubbed.contains("[email]"))
    }

    func testScrub_RemovesUserNamesFromPaths() {
        let scrubbed = scrub(
            #"Open /home/alice/audio.wav, C:\Users\Bob Smith\AppData\x.json, /Users/carol/a, \\server\share\d"#
        )
        for leaked in ["alice", "Bob Smith", "carol", "server", "share"] {
            XCTAssertFalse(scrubbed.contains(leaked), "\(leaked) leaked into \(scrubbed)")
        }
        XCTAssertTrue(scrubbed.contains("~"))
    }

    func testScrub_RemovesURLQueriesIdentifiersAndLongTokens() {
        let scrubbed = scrub(
            "GET https://api.example.com/v1/x?token=abc123 for 123E4567-E89B-12D3-A456-426614174000 "
                + "with QWERTYUIOPASDFGHJKLZXCVBNM123456"
        )
        XCTAssertTrue(scrubbed.contains("https://api.example.com"))
        XCTAssertFalse(scrubbed.contains("token=abc123"))
        XCTAssertFalse(scrubbed.contains("123E4567"))
        XCTAssertFalse(scrubbed.contains("QWERTYUIOPASDFGHJKLZXCVBNM123456"))
    }

    func testScrub_BoundsLengthAndControlCharacters() {
        let scrubbed = scrub(String(repeating: "word ", count: 1_000) + "\n\t\u{0}end")
        XCTAssertLessThanOrEqual(scrubbed.count, DesktopTelemetryScrubber.maximumLength + 1)
        XCTAssertFalse(scrubbed.contains("\n"))
        XCTAssertFalse(scrubbed.contains("\u{0}"))
    }
}
