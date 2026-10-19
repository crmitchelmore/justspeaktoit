import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

final class DesktopConnectionPreWarmingTests: XCTestCase {
    func testDefaults_PreserveMacIntentWithoutLocalApproval() throws {
        let configuration = try DesktopConfiguration()
        XCTAssertTrue(SpeechDefaults.connectionPreWarmingEnabled)
        XCTAssertTrue(configuration.enabled(DesktopConnectionPreWarming.preferenceKey))
        XCTAssertFalse(configuration.enabled(DesktopConnectionPreWarming.approvalProjectionKey))
        XCTAssertEqual(DesktopConnectionPreWarming.preferenceKey, "connectionPreWarmingEnabled")
        XCTAssertTrue(DesktopConfiguration.supportedKeys.contains(DesktopConnectionPreWarming.preferenceKey))
        XCTAssertFalse(DesktopConfiguration.supportedKeys.contains(DesktopConnectionPreWarming.approvalProjectionKey))
    }

    func testNativeFields_AreBooleanAndApprovalDependsOnIntent() throws {
        let intent = try XCTUnwrap(DesktopConfiguration.fields.first {
            $0.key == DesktopConnectionPreWarming.preferenceKey
        })
        let approval = try XCTUnwrap(DesktopConfiguration.fields.first {
            $0.key == DesktopConnectionPreWarming.approvalProjectionKey
        })
        guard case .boolean = intent.kind, case .boolean = approval.kind else {
            return XCTFail("Both native controls must use actual boolean editor semantics.")
        }
        XCTAssertEqual(intent.group, "Post-processing")
        XCTAssertEqual(approval.group, intent.group)
        XCTAssertEqual(approval.enabledBy, intent.key)
        XCTAssertTrue(intent.title.contains("not live/streaming"))
        XCTAssertTrue(approval.title.contains("this session"))
        XCTAssertTrue(approval.title.contains("successful capture"))
        XCTAssertLessThanOrEqual(DesktopConfiguration.fields.count, 64)
    }

    func testStrictBooleanValidation_RejectsCoercionForBothKeys() {
        for key in [DesktopConnectionPreWarming.preferenceKey, DesktopConnectionPreWarming.approvalProjectionKey] {
            for value in [AnyCodable.JSONValue.string("true"), .int(1), .null, .array([]), .object([:])] {
                XCTAssertThrowsError(try DesktopConfiguration(values: [key: AnyCodable(value)]), key)
            }
        }
    }

    func testRemovingEditorApproval_PreservesIntentAndUnknownBytes() throws {
        for enabled in [false, true] {
            let configuration = try DesktopConfiguration(values: [
                DesktopConnectionPreWarming.preferenceKey: AnyCodable(.bool(enabled)),
                DesktopConnectionPreWarming.approvalProjectionKey: AnyCodable(.bool(true)),
                "future": AnyCodable(.string(" retained \nvalue "))
            ])
            let cleaned = try DesktopConnectionPreWarming.removingApproval(from: configuration)
            XCTAssertEqual(cleaned.values[DesktopConnectionPreWarming.preferenceKey], AnyCodable(.bool(enabled)))
            XCTAssertEqual(cleaned.values["future"], configuration.values["future"])
            XCTAssertNil(cleaned.values[DesktopConnectionPreWarming.approvalProjectionKey])
        }
    }

    func testSharedTracker_ExactNinetySecondBoundaryAndFailureAdmission() throws {
        var tracker = LiveStreamWarmTracker()
        let host = try XCTUnwrap(OpenRouterConnectionWarmer.origin.host)
        let policy = LiveStreamWarmUp.endpointProbe(host: host)
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(tracker.hostNeedingWarmUp(using: policy, now: now), host)
        XCTAssertNil(tracker.hostNeedingWarmUp(using: policy, now: now))
        XCTAssertTrue(tracker.markWarmed(host: host, at: now))
        XCTAssertNil(tracker.hostNeedingWarmUp(using: policy, now: now.addingTimeInterval(89.999)))
        XCTAssertEqual(tracker.hostNeedingWarmUp(using: policy, now: now.addingTimeInterval(90)), host)
        tracker.markFailed(host: host)
        XCTAssertEqual(tracker.hostNeedingWarmUp(using: policy, now: now.addingTimeInterval(90)), host)
        XCTAssertNil(tracker.hostNeedingWarmUp(using: policy, now: now, enabled: false))
        XCTAssertFalse(tracker.markWarmed(host: host, at: now))
    }

    func testProbeWire_IsBareCredentialFreeHeadWithFiveSecondBudget() {
        let request = OpenRouterConnectionWarmer.request()
        XCTAssertEqual(request.httpMethod, "HEAD")
        XCTAssertEqual(request.url, OpenRouterConnectionWarmer.origin)
        XCTAssertEqual(request.url?.host, OpenRouterService.baseURL.host)
        XCTAssertEqual(request.url?.path, "/")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertNil(request.url?.user)
        XCTAssertNil(request.url?.password)
        XCTAssertNil(request.url?.query)
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.httpBodyStream)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertTrue(request.allHTTPHeaderFields?.isEmpty != false)
        XCTAssertEqual(request.timeoutInterval, 5)
        XCTAssertEqual(OpenRouterConnectionWarmer.timeout, 5)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testProbeDelegate_RefusesEvenSameOriginRedirects() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: OpenRouterConnectionWarmer.request())
        defer { task.cancel() }
        let response = try XCTUnwrap(HTTPURLResponse(
            url: OpenRouterConnectionWarmer.origin, statusCode: 302, httpVersion: nil, headerFields: nil
        ))
        for url in [OpenRouterService.baseURL, URL(string: "https://unrelated.example/")!] {
            var called = false
            OpenRouterConnectionWarmer.ProbeDelegate().urlSession(
                session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: url)
            ) { redirected in
                called = true
                XCTAssertNil(redirected)
            }
            XCTAssertTrue(called)
        }
    }

    func testProbe_RefusesCustomSessionHeadersBeforeAnyRequest() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["Authorization": "fixture-not-to-send"]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            try await OpenRouterConnectionWarmer.warmUp(session: session)
            XCTFail("Inherited credentials must refuse a probe.")
        } catch {
            guard case OpenRouterConnectionWarmer.Failure.unsafeSession = error else {
                return XCTFail("The session should be refused before network admission: \(error)")
            }
        }
    }

    func testAuthenticationDelegate_RefusesCredentialsButRetainsSystemTrustEvaluation() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: OpenRouterConnectionWarmer.request())
        defer { task.cancel() }
        for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
                       "NSURLAuthenticationMethodServerTrust"] {
            let space = URLProtectionSpace(
                host: OpenRouterConnectionWarmer.origin.host!, port: 443, protocol: "https",
                realm: "fixture", authenticationMethod: method
            )
            let challenge = URLAuthenticationChallenge(
                protectionSpace: space, proposedCredential: URLCredential(
                    user: "fixture", password: "must-not-send", persistence: .none
                ), previousFailureCount: 0, failureResponse: nil, error: nil, sender: WarmChallengeSender()
            )
            var called = false
            // swiftlint:disable:next line_length
            OpenRouterConnectionWarmer.ProbeDelegate().urlSession(session, task: task, didReceive: challenge) { disposition, credential in
                called = true
                XCTAssertNil(credential)
                XCTAssertEqual(
                    disposition,
                    method == "NSURLAuthenticationMethodServerTrust"
                        ? .performDefaultHandling : .cancelAuthenticationChallenge
                )
            }
            XCTAssertTrue(called)
        }
    }
}

private final class WarmChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}
