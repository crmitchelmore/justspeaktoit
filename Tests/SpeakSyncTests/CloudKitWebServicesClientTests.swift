import Foundation
import XCTest

@testable import SpeakSync

final class CloudKitWebServicesClientTests: XCTestCase {
    private let zone = SyncSchema.zoneName

    func testRequestsAddressTheContainerEnvironmentAndDatabaseWithEncodedTokens() async throws {
        let store = HeldTokenStore(token: "synthetic+session/token==")
        let transport = ScriptedCloudKitTransport()
        let client = try makeTestClient(store: store, transport: transport)

        _ = try await client.lookupRecords(zoneName: zone, recordNames: ["record-a"])

        let first = await transport.requests.first
        let request = try XCTUnwrap(first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.host, "api.apple-cloudkit.com")
        XCTAssertEqual(request.url.path, "/database/1/iCloud.com.example.synthetic/development/private/records/lookup")
        XCTAssertEqual(
            request.url.query,
            "ckAPIToken=synthetic-api-token&ckWebAuthToken=synthetic%2Bsession%2Ftoken%3D%3D"
        )
        XCTAssertEqual(request.headers["Content-Type"], "text/plain")
        let zoneID = request.jsonBody["zoneID"] as? [String: Any]
        XCTAssertEqual(zoneID?["zoneName"] as? String, zone)
        let records = request.jsonBody["records"] as? [[String: Any]]
        XCTAssertEqual(records?.first?["recordName"] as? String, "record-a")
    }

    func testCallerIdentityUsesThePublicDatabasePathWithoutABody() async throws {
        let transport = ScriptedCloudKitTransport()
        await transport.enqueue(CloudKitWebFixture.response(["users": [["userRecordName": "_synthetic-user"]]]))
        let client = try makeTestClient(store: HeldTokenStore(token: "synthetic-session"), transport: transport)

        let name = try await client.currentUserRecordName()

        XCTAssertEqual(name, "_synthetic-user")
        let request = await transport.requests.first
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.url.path, "/database/1/iCloud.com.example.synthetic/development/public/users/caller")
        XCTAssertNil(request?.body)
    }

    func testSignedOutRequestSurfacesTheSignInRedirectWithoutRetrying() async throws {
        let transport = ScriptedCloudKitTransport()
        let redirect = "https://sign-in.example.invalid/authorize"
        await transport.enqueue(CloudKitWebFixture.response(status: 421, [
            "serverErrorCode": "AUTHENTICATION_REQUIRED",
            "reason": "request needs authorization",
            "redirectURL": redirect
        ]))
        let client = try makeTestClient(store: HeldTokenStore(token: nil), transport: transport)

        do {
            _ = try await client.lookupRecords(zoneName: zone, recordNames: ["record-a"])
            XCTFail("Expected an interactive sign-in gate")
        } catch {
            let expected = CloudKitWebServicesError.authenticationRequired(redirectURL: URL(string: redirect))
            XCTAssertEqual(error as? CloudKitWebServicesError, expected)
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(requests.first?.webAuthToken)
    }

    func testRejectedSessionIsDiscardedAndNotRetried() async throws {
        let store = HeldTokenStore(token: "synthetic-rejected")
        let transport = ScriptedCloudKitTransport()
        await transport.enqueue(CloudKitWebFixture.serverError("AUTHENTICATION_FAILED", status: 401))
        let client = try makeTestClient(store: store, transport: transport)

        do {
            _ = try await client.lookupRecords(zoneName: zone, recordNames: ["record-a"])
            XCTFail("Expected an authentication failure")
        } catch {
            XCTAssertEqual(
                error as? CloudKitWebServicesError,
                .authenticationFailed(reason: "synthetic AUTHENTICATION_FAILED")
            )
        }
        let stored = await store.token
        XCTAssertNil(stored)
        let signedIn = try await client.hasWebAuthToken()
        XCTAssertFalse(signedIn)
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 1)
    }

    func testRotatedTokensArePersistedAndUsedByTheNextRequest() async throws {
        let store = HeldTokenStore(token: "synthetic-1")
        let transport = ScriptedCloudKitTransport()
        await transport.enqueue(CloudKitWebFixture.records([]).rotating(to: "synthetic-2"))
        await transport.enqueue(CloudKitWebFixture.response(
            ["records": []],
            rotatedToken: "synthetic-3",
            header: CloudKitWebServicesClient.sessionHeader
        ))
        let client = try makeTestClient(store: store, transport: transport)

        for name in ["one", "two", "three"] {
            _ = try await client.lookupRecords(zoneName: zone, recordNames: [name])
        }

        let tokens = await transport.requests.map(\.webAuthToken)
        XCTAssertEqual(tokens, ["synthetic-1", "synthetic-2", "synthetic-3"])
        let saved = await store.saved
        XCTAssertEqual(saved, ["synthetic-2", "synthetic-3"])
    }

    func testUnsavableRotationIsReportedButKeepsTheSessionForThisProcess() async throws {
        let store = HeldTokenStore(token: "synthetic-1")
        await store.failSaves()
        let transport = ScriptedCloudKitTransport()
        await transport.enqueue(CloudKitWebFixture.records([]).rotating(to: "synthetic-2"))
        let client = try makeTestClient(store: store, transport: transport)

        do {
            _ = try await client.lookupRecords(zoneName: zone, recordNames: ["one"])
            XCTFail("Expected the persistence failure")
        } catch {
            XCTAssertEqual(error as? CloudKitWebServicesError, .tokenPersistenceFailed)
        }
        _ = try await client.lookupRecords(zoneName: zone, recordNames: ["two"])
        let latest = await transport.requests.last?.webAuthToken
        XCTAssertEqual(latest, "synthetic-2")
    }

    func testCallbackSignInStoresTheDecodedTokenAndStartsANewSession() async throws {
        let store = HeldTokenStore(token: nil)
        let client = try makeTestClient(store: store, transport: ScriptedCloudKitTransport())
        let before = await client.session()

        let callback = try XCTUnwrap(URL(string: "https://callback.example.invalid/?ckWebAuthToken=abc%2Bdef%2F%3D"))
        try await client.completeSignIn(callbackURL: callback)

        let saved = await store.saved
        XCTAssertEqual(saved, ["abc+def/="])
        let after = await client.session()
        XCTAssertNotEqual(before, after)
        let bare = try XCTUnwrap(URL(string: "https://callback.example.invalid/?state=1"))
        do {
            try await client.completeSignIn(callbackURL: bare)
            XCTFail("A callback without a token is not a sign-in")
        } catch {
            XCTAssertEqual(error as? CloudKitWebServicesError, .authenticationRequired(redirectURL: nil))
        }
    }

    func testConfigurationRequiresADeveloperTokenAndAContainerIdentifier() throws {
        XCTAssertThrowsError(
            try CloudKitWebServicesConfiguration(
                containerIdentifier: CloudKitWebFixture.containerIdentifier,
                environment: .production,
                apiToken: "  "
            )
        ) { XCTAssertEqual($0 as? CloudKitWebServicesConfigurationError, .missingAPIToken) }
        XCTAssertThrowsError(
            try CloudKitWebServicesConfiguration(
                containerIdentifier: "com.example",
                environment: .production,
                apiToken: "x"
            )
        ) { XCTAssertEqual($0 as? CloudKitWebServicesConfigurationError, .invalidContainerIdentifier("com.example")) }
        let insecure = try XCTUnwrap(URL(string: "http://api.example.invalid"))
        XCTAssertThrowsError(
            try CloudKitWebServicesConfiguration(
                containerIdentifier: CloudKitWebFixture.containerIdentifier,
                environment: .production,
                apiToken: "x",
                baseURL: insecure
            )
        ) { XCTAssertEqual($0 as? CloudKitWebServicesConfigurationError, .invalidBaseURL) }
    }
}
