#if !APP_STORE
@testable import SpeakApp
import CoreFoundation
import SpeakCore
import SpeakTestSupport
import XCTest

final class AnalyticsInspectionTests: XCTestCase {
    func testEnvelopeMatchesRequestMinusCredential_ForPseudonymousAndAnonymousEvents() async throws {
        let fixture = InspectionFixture()
        try await fixture.sink.reopen()
        let events: [ProductAnalyticsEvent] = [
            .keyboardEnabledState(enabled: true), .errorDisplayed(error: .connectivity, surface: .recording)
        ]
        for event in events {
            try await fixture.sink.capture(fixture.payload(event))
        }
        let snapshot = await fixture.sink.inspectionSnapshot()
        XCTAssertEqual(snapshot.records.count, 2)
        for (request, record) in zip(fixture.recorder.requests, snapshot.records) {
            let requestBody = try XCTUnwrap(request.httpBody)
            var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            XCTAssertEqual(wire.removeValue(forKey: "api_key") as? String, InspectionFixture.keySentinel)
            let inspected = try XCTUnwrap(JSONSerialization.jsonObject(with: record.envelope) as? [String: Any])
            XCTAssertEqual(wire as NSDictionary, inspected as NSDictionary)
            try assertGeoIPDisabled(in: requestBody)
            try assertGeoIPDisabled(in: record.envelope)
            XCTAssertEqual(record.status, .httpAcknowledged)
        }
        let exported = try XCTUnwrap(String(data: snapshot.exportData(), encoding: .utf8))
        XCTAssertFalse(exported.contains(InspectionFixture.keySentinel))
        XCTAssertFalse(exported.contains(InspectionFixture.responseSentinel))
        XCTAssertTrue(exported.contains("anonymous-counter"))
        XCTAssertEqual(fixture.recorder.requests.count, 2, "Inspection and export must not capture events")
        await fixture.sink.close()
    }

    func testRecentHistory_IsBoundedTo100AndClearedByPurge() async throws {
        let fixture = InspectionFixture()
        try await fixture.sink.reopen()
        for _ in 0..<105 { try await fixture.sink.capture(fixture.payload()) }
        let snapshot = await fixture.sink.inspectionSnapshot()
        XCTAssertEqual(snapshot.records.count, 100)
        XCTAssertEqual(Set(snapshot.records.map(\.id)).count, 100)
        try await fixture.sink.purge()
        let purged = await fixture.sink.inspectionSnapshot()
        XCTAssertTrue(purged.records.isEmpty)
        XCTAssertEqual(purged.queueDepth, 0)
    }

    func testRestoredQueueAndRetry_AlwaysDisableGeoIPWithNativeBoolean() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queueURL = directory.appendingPathComponent("queue.json")
        let entries: [[String: Any]] = (0..<2).map { index in
            var properties: [String: Any] = ["analytics_schema_version": 2]
            if index == 1 { properties["$geoip_disable"] = false }
            return ["createdAt": Date().timeIntervalSinceReferenceDate, "event": "app_active_daily",
                    "distinctID": "legacy-\(index)", "properties": properties]
        }
        try JSONSerialization.data(withJSONObject: entries).write(to: queueURL)
        let delivered = expectation(description: "Restored events delivered after transient retry")
        let recorder = AnalyticsRequestRecorder(statusCodes: [503, 200, 200]) { count in
            if count == 3 { delivered.fulfill() }
        }
        let fixture = InspectionFixture(recorder: recorder, queueURL: queueURL, retryDelays: [.milliseconds(20)])
        let seeded = await fixture.sink.inspectionSnapshot()
        XCTAssertEqual(seeded.records.count, 2)
        for record in seeded.records { try assertGeoIPDisabled(in: record.envelope) }
        do {
            try await fixture.sink.reopen()
            XCTFail("The first restored delivery must encounter the transient failure")
        } catch {}
        await fulfillment(of: [delivered], timeout: 2)
        for _ in 0..<1_000 {
            if await fixture.sink.inspectionSnapshot().queueDepth == 0 { break }
            await Task.yield()
        }
        let completed = await fixture.sink.inspectionSnapshot()
        XCTAssertEqual(completed.queueDepth, 0)
        XCTAssertEqual(completed.records.map(\.id), seeded.records.map(\.id))
        XCTAssertTrue(completed.records.allSatisfy { $0.status == .httpAcknowledged })
        XCTAssertEqual(recorder.requests.count, 3)
        for request in recorder.requests { try assertGeoIPDisabled(in: XCTUnwrap(request.httpBody)) }
        for record in completed.records { try assertGeoIPDisabled(in: record.envelope) }
        await fixture.sink.close()
    }

    func testRetry_UpdatesTheSameInspectionRow() async throws {
        let delivered = expectation(description: "Retry request received")
        let recorder = AnalyticsRequestRecorder(statusCodes: [503, 200]) { count in
            if count == 2 { delivered.fulfill() }
        }
        let fixture = InspectionFixture(recorder: recorder, retryDelays: [.milliseconds(20)])
        try await fixture.sink.reopen()
        try? await fixture.sink.capture(fixture.payload())
        let pending = await fixture.sink.inspectionSnapshot()
        let identifier = try XCTUnwrap(pending.records.first?.id)
        await fulfillment(of: [delivered], timeout: 2)
        for _ in 0..<1_000 {
            if await fixture.sink.inspectionSnapshot().records.first?.status == .httpAcknowledged { break }
            await Task.yield()
        }
        let completed = await fixture.sink.inspectionSnapshot()
        XCTAssertEqual(completed.records.map(\.id), [identifier])
        XCTAssertEqual(completed.records.first?.status, .httpAcknowledged)
        await fixture.sink.close()
    }

    func testPersistedQueue_SeedsInspectionWithoutTrafficAndExpiresInMemory() async throws {
        let clock = AnalyticsTestClock(Date())
        let fixture = InspectionFixture(recorder: AnalyticsRequestRecorder(statusCode: 503), now: { clock.now })
        try await fixture.sink.reopen()
        try? await fixture.sink.capture(fixture.payload())
        await fixture.sink.close()
        let restored = InspectionFixture(queueURL: fixture.queueURL, now: { clock.now })
        let initial = await restored.sink.inspectionSnapshot()
        XCTAssertEqual(initial.records.count, 1)
        XCTAssertEqual(initial.queueDepth, 1)
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: initial.exportData()) as? [String: Any])
        XCTAssertEqual(exported["scope"] as? String, AnalyticsInspectionSnapshot.historyScope)
        XCTAssertTrue(AnalyticsInspectionSnapshot.historyScope.contains("earlier launches"))
        XCTAssertTrue(restored.recorder.requests.isEmpty)
        clock.advance(by: 8 * 24 * 60 * 60)
        let expired = await restored.sink.inspectionSnapshot()
        XCTAssertTrue(expired.records.isEmpty)
        XCTAssertEqual(expired.queueDepth, 0)
        XCTAssertTrue(restored.recorder.requests.isEmpty)
        try await restored.sink.purge()
    }

    func testPersistedQueueSeed_RespectsBothQueueCapAnd100RecordLimitWithoutSending() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queueURL = directory.appendingPathComponent("queue.json")
        let entries: [[String: Any]] = (0..<1_001).map { index in
            ["createdAt": Date().timeIntervalSinceReferenceDate, "event": "app_active_daily",
             "distinctID": "legacy-\(index)", "properties": ["analytics_schema_version": 2]]
        }
        try JSONSerialization.data(withJSONObject: entries).write(to: queueURL)
        let fixture = InspectionFixture(queueURL: queueURL)
        let snapshot = await fixture.sink.inspectionSnapshot()
        XCTAssertEqual(snapshot.records.count, 100)
        XCTAssertEqual(snapshot.queueDepth, 1_000)
        XCTAssertTrue(fixture.recorder.requests.isEmpty)
    }

    func testPersistenceFailure_DoesNotClaimDurableQueueOrSend() async throws {
        let blockedParent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: blockedParent)
        defer { try? FileManager.default.removeItem(at: blockedParent) }
        let fixture = InspectionFixture(queueURL: blockedParent.appendingPathComponent("queue.json"))
        try await fixture.sink.reopen()
        do {
            try await fixture.sink.capture(fixture.payload())
            XCTFail("Expected local persistence failure")
        } catch {}
        let snapshot = await fixture.sink.inspectionSnapshot()
        XCTAssertEqual(snapshot.records.first?.status, .persistenceFailed)
        XCTAssertTrue(fixture.recorder.requests.isEmpty)
        await fixture.sink.close()
    }

    func testExpiredInFlightResponse_CannotRestoreEvictedInspectionRecord() async throws {
        let clock = AnalyticsTestClock(Date())
        let started = expectation(description: "Old event is in flight")
        let recorder = AnalyticsRequestRecorder(statusCode: 503, holdResponses: true) { _ in started.fulfill() }
        let fixture = InspectionFixture(recorder: recorder, now: { clock.now })
        try await fixture.sink.reopen()
        let first = Task { try? await fixture.sink.capture(fixture.payload()) }
        await fulfillment(of: [started], timeout: 2)
        let sending = await fixture.sink.inspectionSnapshot()
        let oldID = try XCTUnwrap(sending.records.first?.id)
        clock.advance(by: 8 * 24 * 60 * 60)
        try await fixture.sink.capture(fixture.payload())
        recorder.releaseResponses()
        await first.value
        let snapshot = await fixture.sink.inspectionSnapshot()
        XCTAssertEqual(snapshot.records.count, 1)
        XCTAssertNotEqual(snapshot.records.first?.id, oldID)
        XCTAssertEqual(snapshot.queueDepth, 1)
        XCTAssertEqual(recorder.requests.count, 1)
        try await fixture.sink.purge()
    }

    func testEndpointInspectionAndExport_ExcludeCredentialsIncludingProxyPathWithoutChangingTransport() async throws {
        let url = URL(string: "https://user:SECRET@example.test/proxy/PATH_TOKEN/capture?token=SECRET#SECRET")!
        let fixture = InspectionFixture(endpoint: url)
        try await fixture.sink.reopen()
        try await fixture.sink.capture(fixture.payload())
        let snapshot = await fixture.sink.inspectionSnapshot()
        XCTAssertEqual(snapshot.endpoint, "https://example.test")
        let exported = try XCTUnwrap(String(data: snapshot.exportData(), encoding: .utf8))
        XCTAssertFalse(exported.contains("PATH_TOKEN"))
        XCTAssertFalse(exported.contains("SECRET"))
        XCTAssertEqual(
            fixture.recorder.requests.first?.url?.path, url.path, "Transport retains its configured proxy path"
        )
        await fixture.sink.close()
    }

    private func assertGeoIPDisabled(in data: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
        let properties = try XCTUnwrap(body["properties"] as? [String: Any], file: file, line: line)
        let control = try XCTUnwrap(properties["$geoip_disable"] as? NSNumber, file: file, line: line)
        XCTAssertEqual(CFGetTypeID(control), CFBooleanGetTypeID(), file: file, line: line)
        XCTAssertTrue(control.boolValue, file: file, line: line)
        XCTAssertEqual(
            Set(properties.keys.filter { $0.hasPrefix("$geoip_") }), ["$geoip_disable"], file: file, line: line
        )
    }
}

private struct InspectionFixture {
    static let keySentinel = "INGESTION_KEY_SENTINEL"
    static let responseSentinel = "PRIVATE_RESPONSE_SENTINEL"
    let queueURL: URL
    let recorder: AnalyticsRequestRecorder
    let sink: PostHogProductAnalyticsSink

    init(
        recorder: AnalyticsRequestRecorder = AnalyticsRequestRecorder(
            responseBody: Data(InspectionFixture.responseSentinel.utf8)
        ),
        queueURL: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        retryDelays: [Duration] = [],
        forceDisabled: @escaping @Sendable () -> Bool = { false },
        endpoint: URL = URL(string: "https://eu.i.posthog.com/capture")!
    ) {
        self.recorder = recorder
        self.queueURL = queueURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("queue.json")
        recorder.installAsStubHandler()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        self.sink = PostHogProductAnalyticsSink(
            queueURL: self.queueURL,
            session: URLSession(configuration: configuration),
            configuration: (projectKey: Self.keySentinel, endpoint: endpoint),
            now: now,
            retryDelays: retryDelays,
            forceDisabled: forceDisabled
        )
    }

    func payload(_ event: ProductAnalyticsEvent = .appActiveDaily) -> ProductAnalyticsPayload {
        ProductAnalyticsPayload(
            event: event,
            context: ProductAnalyticsContext(
                platform: .macOS, appVersion: "1.0", build: "1", osMajorMinor: "26.2",
                distributionChannel: .direct, localeLanguageCode: "en", architecture: "arm64"
            ),
            distinctID: UUID()
        )
    }
}
#endif
