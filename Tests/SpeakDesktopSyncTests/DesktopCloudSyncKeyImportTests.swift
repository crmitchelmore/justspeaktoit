import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopSync
@testable import SpeakSync
import SpeakTestSupport
import XCTest

/// API-key import interrupted where the Windows host can interrupt it: import
/// turned off, a sign-out or a newer sign-in while keys are being read or the
/// passphrase checked. A key read earlier must never be written, removed or
/// forgotten afterwards.
final class DesktopCloudSyncKeyImportTests: DesktopCloudSyncTestCase {
    private let passphrase = "correct horse battery staple"

    func testTurningImportOffWhileKeysAreReadChangesNoKey() async throws {
        let importing = try await importingService()
        let service = importing.service
        let recorder = importing.recorder
        await recorder.hold("private/records/lookup")

        let pass = Task { await service.sync() }
        try await eventually { await recorder.heldCount == 1 }
        try await service.disableKeyImport()
        await recorder.releaseHeld()
        let report = await pass.value

        XCTAssertEqual(try vault.readCredential("openai.apiKey"), "first", "a key was written after import was off")
        XCTAssertTrue(report.importedKeys.isEmpty)
        XCTAssertNil(report.error, "stopping as asked is not an error")
        let status = await service.status()
        XCTAssertFalse(status.apiKeyImportEnabled)
    }

    func testASignOutWhileKeysAreReadChangesNoKeyAndRecordsNoSuccess() async throws {
        let importing = try await importingService()
        let service = importing.service
        let state = importing.state
        let recorder = importing.recorder
        let client = try await serviceClient(service)
        let succeeded = await state.current.lastSuccessfulSync
        await recorder.hold("private/records/lookup")

        let pass = Task { await service.sync() }
        try await eventually { await recorder.heldCount == 1 }
        let signOut = Task { try await service.signOut() }
        try await eventually { await client.waitingRequestCount == 1 }
        await recorder.releaseHeld()
        try await signOut.value
        let report = await pass.value

        XCTAssertEqual(try vault.readCredential("openai.apiKey"), "first", "a key read before sign-out was written")
        let known = await state.current.importedKeys["openai.apiKey"]
        XCTAssertEqual(known?.lastRemoteUpdate, fixtureDate(100))
        let recorded = await state.current.lastSuccessfulSync
        XCTAssertEqual(recorded, succeeded, "a pass whose session ended was recorded as a success")
        XCTAssertEqual(report.error, CloudKitWebServicesError.sessionChanged.localizedDescription)
    }

    func testEnablingImportStoresNothingWhenTheSessionEndsBeforeTheKeyIsSaved() async throws {
        try seedMacKeys(passphrase: passphrase, keys: ["openai.apiKey": "first"])
        let recorder = RecordingServerTransport(server: server)
        let (service, _) = try await signedInService(transport: recorder)
        try await service.setHistoryEnabled(false)
        let client = try await serviceClient(service)
        await recorder.hold("private/records/lookup")

        let enabling = Task { try await service.enableKeyImport(passphrase: passphrase) }
        try await eventually { await recorder.heldCount == 1 }
        let signOut = Task { try await service.signOut() }
        try await eventually { await client.waitingRequestCount == 1 }
        await recorder.releaseHeld()
        try await signOut.value

        do {
            _ = try await enabling.value
            XCTFail("A passphrase checked in an ended session must not be kept")
        } catch {
            XCTAssertEqual(error as? CloudKitWebServicesError, .sessionChanged)
        }
        XCTAssertNil(try vault.readCredential(DesktopCloudSyncCredential.apiKeySyncKey))
        XCTAssertNil(try vault.readCredential("openai.apiKey"))
        let status = await service.status()
        XCTAssertFalse(status.apiKeyImportEnabled)
    }

    func testAnAuthenticationFailureOvertakenByANewSignInLeavesItSignedIn() async throws {
        let recorder = RecordingServerTransport(server: server)
        let (service, _) = try await signedInService(transport: recorder)
        let client = try await serviceClient(service)
        await recorder.hold("public/users/caller")

        let pass = Task { await service.sync() }
        try await eventually { await recorder.heldCount == 1 }
        server.expireSessions()
        let token = server.completeSignIn()
        let signIn = Task { try await service.completeSignIn(webAuthToken: token) }
        try await eventually { await client.waitingRequestCount == 1 }
        await recorder.releaseHeld()
        try await signIn.value
        let report = await pass.value

        XCTAssertNotNil(report.error)
        let status = await service.status()
        XCTAssertTrue(status.isSignedIn, "the pass's failure predates the sign-in that followed it")
        XCTAssertEqual(try vault.readCredential(DesktopCloudSyncCredential.webAuthToken), token)
    }

    // MARK: - One import step

    func testAKeyStepDecidesAgainstTheBookkeepingAsItIsNow() throws {
        let vault = MemoryVault()
        var state = DesktopCloudSyncState()
        state.enabledFeatures = [.apiKeys]
        try vault.writeCredential("typed by hand", name: "openai.apiKey")
        state.importedKeys["openai.apiKey"] = .init(lastRemoteUpdate: fixtureDate(1), isImportedValue: false)
        try vault.writeCredential("imported", name: "xai.apiKey")
        state.importedKeys["xai.apiKey"] = .init(lastRemoteUpdate: fixtureDate(1), isImportedValue: true)

        let kept = try DesktopKeyImport.apply(deletion("openai.apiKey", at: 2), to: &state, vault: vault)
        let removed = try DesktopKeyImport.apply(deletion("xai.apiKey", at: 2), to: &state, vault: vault)
        let stale = CloudKitWebSyncedSecret(identifier: "xai.apiKey", value: "older", updatedAt: fixtureDate(1))
        let skipped = try DesktopKeyImport.apply(stale, to: &state, vault: vault)

        XCTAssertNil(kept)
        XCTAssertEqual(try vault.readCredential("openai.apiKey"), "typed by hand")
        XCTAssertEqual(removed, .removed)
        XCTAssertNil(try vault.readCredential("xai.apiKey"))
        XCTAssertNil(skipped, "a change no newer than the one considered is ignored")
        XCTAssertNil(try vault.readCredential("xai.apiKey"))
    }

    func testAKeyStepChangesNothingOnceImportIsOff() throws {
        let vault = MemoryVault()
        var state = DesktopCloudSyncState()
        let secret = CloudKitWebSyncedSecret(identifier: "openai.apiKey", value: "remote", updatedAt: fixtureDate(2))

        XCTAssertThrowsError(try DesktopKeyImport.apply(secret, to: &state, vault: vault)) {
            XCTAssertEqual($0 as? CloudKitWebServicesError, .consentRequired(.apiKeys))
        }
        XCTAssertNil(try vault.readCredential("openai.apiKey"))
        XCTAssertTrue(state.importedKeys.isEmpty)
    }

    func testARejectedKeyIsForgottenUnlessANewerOneWasStored() throws {
        let vault = MemoryVault()
        var state = DesktopCloudSyncState()
        state.enabledFeatures = [.apiKeys]
        try vault.writeCredential("newer", name: DesktopCloudSyncCredential.apiKeySyncKey)

        XCTAssertFalse(try DesktopKeyImport.forget("rejected", in: &state, vault: vault))
        XCTAssertEqual(try vault.readCredential(DesktopCloudSyncCredential.apiKeySyncKey), "newer")
        XCTAssertTrue(state.enabledFeatures.contains(.apiKeys))

        XCTAssertTrue(try DesktopKeyImport.forget("newer", in: &state, vault: vault))
        XCTAssertNil(try vault.readCredential(DesktopCloudSyncCredential.apiKeySyncKey))
        XCTAssertFalse(state.enabledFeatures.contains(.apiKeys))
    }

    // MARK: - Fixtures

    private struct Importing {
        let service: DesktopCloudSyncService
        let state: DesktopCloudSyncStateStore
        let recorder: RecordingServerTransport
    }

    /// A keys-only service that imported "first" and whose Mac now has "second".
    private func importingService() async throws -> Importing {
        try seedMacKeys(passphrase: passphrase, keys: ["openai.apiKey": "first"])
        let recorder = RecordingServerTransport(server: server)
        let (service, state) = try await signedInService(transport: recorder)
        try await service.setHistoryEnabled(false)
        _ = try await service.enableKeyImport(passphrase: passphrase)
        let settled = await service.sync()
        XCTAssertNil(settled.error)
        try seedSecrets(["openai.apiKey": "second"], at: fixtureDate(900))
        return Importing(service: service, state: state, recorder: recorder)
    }

    private func serviceClient(_ service: DesktopCloudSyncService) async throws -> CloudKitWebServicesClient {
        let client = await service.client
        return try XCTUnwrap(client)
    }

    private func deletion(_ identifier: String, at seconds: Int) -> CloudKitWebSyncedSecret {
        CloudKitWebSyncedSecret(identifier: identifier, value: nil, updatedAt: fixtureDate(seconds))
    }
}
