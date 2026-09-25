import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopSync
@testable import SpeakSync
import SpeakTestSupport
import XCTest

/// The user's latest choice about API keys decides: turning import off, or on
/// again, overtakes a turn-on still in progress, and a key typed by hand is
/// saved only once its mark is, so a deletion synced from the Mac spares it.
final class DesktopCloudSyncKeyIntentTests: DesktopCloudSyncTestCase {
    private let passphrase = "correct horse battery staple"

    func testTurningImportOffWhileItIsBeingTurnedOnKeepsItOff() async throws {
        try seedMacKeys(passphrase: passphrase, keys: ["openai.apiKey": "first"])
        let recorder = RecordingServerTransport(server: server)
        let (service, _) = try await signedInService(transport: recorder)
        await recorder.hold("private/records/lookup")

        let enabling = Task { try await service.enableKeyImport(passphrase: passphrase) }
        try await eventually { await recorder.heldCount == 1 }
        try await service.disableKeyImport()
        await recorder.releaseHeld()

        do {
            _ = try await enabling.value
            XCTFail("A turn-on overtaken by turning import off must not report success")
        } catch {
            XCTAssertEqual(error as? DesktopCloudSyncError, .keyImportSuperseded)
        }
        XCTAssertNil(try vault.readCredential(DesktopCloudSyncCredential.apiKeySyncKey))
        XCTAssertNil(try vault.readCredential("openai.apiKey"))
        let status = await service.status()
        XCTAssertFalse(status.apiKeyImportEnabled)
        let later = await service.sync()
        XCTAssertNil(later.error)
        XCTAssertNil(try vault.readCredential("openai.apiKey"), "a pass imported keys after import was turned off")
    }

    func testTheLaterOfTwoOverlappingTurnOnsDecidesTheResult() async throws {
        try seedMacKeys(passphrase: passphrase, keys: ["openai.apiKey": "first"])
        let recorder = RecordingServerTransport(server: server)
        let (service, _) = try await signedInService(transport: recorder)
        let client = try await serviceClient(service)
        await recorder.hold("private/records/lookup")

        let earlier = Task { try await service.enableKeyImport(passphrase: passphrase) }
        try await eventually { await recorder.heldCount == 1 }
        let later = Task { try await service.enableKeyImport(passphrase: "wrong horse battery staple") }
        try await eventually { await client.waitingRequestCount == 1 }
        await recorder.releaseHeld()

        do {
            _ = try await earlier.value
            XCTFail("An earlier turn-on must not report success once a later one began")
        } catch {
            XCTAssertEqual(error as? DesktopCloudSyncError, .keyImportSuperseded)
        }
        do {
            _ = try await later.value
            XCTFail("The later turn-on used a wrong passphrase")
        } catch {
            XCTAssertEqual(error as? CloudKitKeySyncError, .incorrectPassphrase)
        }
        XCTAssertNil(try vault.readCredential(DesktopCloudSyncCredential.apiKeySyncKey))
        XCTAssertNil(try vault.readCredential("openai.apiKey"))
        let status = await service.status()
        XCTAssertFalse(status.apiKeyImportEnabled, "the later turn-on failed, so import stays off")
    }

    func testAKeySavedByHandWhileKeysAreReadSurvivesTheirDeletion() async throws {
        try seedMacKeys(passphrase: passphrase, keys: ["openai.apiKey": "imported"])
        let recorder = RecordingServerTransport(server: server)
        let (service, state) = try await signedInService(transport: recorder)
        try await service.setHistoryEnabled(false)
        _ = try await service.enableKeyImport(passphrase: passphrase)
        try seedSecrets([:], deleted: ["openai.apiKey"], at: fixtureDate(900))
        await recorder.hold("private/records/lookup")

        let pass = Task { await service.sync() }
        try await eventually { await recorder.heldCount == 1 }
        try await service.saveKeyByHand("typed on windows", identifier: "openai.apiKey")
        await recorder.releaseHeld()
        let report = await pass.value

        XCTAssertNil(report.error)
        XCTAssertEqual(try vault.readCredential("openai.apiKey"), "typed on windows")
        XCTAssertTrue(report.removedKeys.isEmpty)
        let known = await state.current.importedKeys["openai.apiKey"]
        XCTAssertEqual(known?.isImportedValue, false)
        XCTAssertEqual(known?.lastRemoteUpdate, fixtureDate(900), "the deletion was considered, not applied")
    }

    // MARK: - Saving by hand

    /// The sync state cannot be written when a key is typed. The mark is saved
    /// first, so the key is not saved either and the save fails: the vault
    /// never holds a typed key that the state takes for the imported one, and
    /// a deletion synced from the Mac removes only the imported value.
    func testAKeyTypedWhileTheStateCannotBeWrittenIsNotSaved() async throws {
        let (service, state) = try await serviceWithAnImportedKey()

        let unblock = try blockWrites(to: stateURL)
        do {
            try await service.saveKeyByHand("typed on windows", identifier: "openai.apiKey")
            XCTFail("A typed key must not be reported saved while its mark cannot be written")
        } catch {
            // The state file could not be written, and the caller is told.
        }
        try unblock()
        let kept = try vault.readCredential("openai.apiKey")
        XCTAssertEqual(kept, "imported", "the typed key was saved although its mark was not")
        let mark = await state.current.importedKeys["openai.apiKey"]?.isImportedValue
        XCTAssertEqual(mark, true, "the mark no longer describes the saved value")

        try seedSecrets([:], deleted: ["openai.apiKey"], at: fixtureDate(900))
        let report = await service.sync()
        XCTAssertNil(report.error)
        XCTAssertEqual(report.removedKeys, ["openai.apiKey"])
        XCTAssertNil(try vault.readCredential("openai.apiKey"))
    }

    /// Once the state can be written again, typing the key again saves its
    /// mark and then the key, so after a relaunch a deletion synced from the
    /// Mac spares it.
    func testAKeyTypedOnceTheStateCanBeWrittenAgainOutlivesARelaunchAndADeletion() async throws {
        let (service, _) = try await serviceWithAnImportedKey()
        let unblock = try blockWrites(to: stateURL)
        try? await service.saveKeyByHand("typed on windows", identifier: "openai.apiKey")
        try unblock()
        try await service.saveKeyByHand("typed on windows", identifier: "openai.apiKey")

        let (relaunched, relaunchedState) = try makeService()
        await relaunched.prepare()
        try seedSecrets([:], deleted: ["openai.apiKey"], at: fixtureDate(900))
        let report = await relaunched.sync()

        XCTAssertNil(report.error)
        XCTAssertTrue(report.removedKeys.isEmpty)
        XCTAssertEqual(try vault.readCredential("openai.apiKey"), "typed on windows")
        let known = await relaunchedState.current.importedKeys["openai.apiKey"]
        XCTAssertEqual(known?.isImportedValue, false)
        XCTAssertEqual(known?.lastRemoteUpdate, fixtureDate(900), "the deletion was considered, not applied")
    }

    func testSavingByHandSavesTheMarkAndThenTheKey() async throws {
        let vault = MemoryVault()
        let url = directory.appendingPathComponent("by-hand.json")
        let store = try await stateWithAnImportedKey(at: url)
        try vault.writeCredential("imported", name: "openai.apiKey")

        try await DesktopKeyImport.saveByHand("typed", identifier: "openai.apiKey", in: store, vault: vault)
        let saved = try await DesktopCloudSyncStateStore(url: url).current
        XCTAssertEqual(saved.importedKeys["openai.apiKey"]?.isImportedValue, false, "the mark was not saved")
        let tombstone = CloudKitWebSyncedSecret(identifier: "openai.apiKey", value: nil, updatedAt: fixtureDate(2))
        let removed = try await store.update { try DesktopKeyImport.apply(tombstone, to: &$0, vault: vault) }

        XCTAssertNil(removed)
        XCTAssertEqual(try vault.readCredential("openai.apiKey"), "typed")

        try await DesktopKeyImport.saveByHand("", identifier: "openai.apiKey", in: store, vault: vault)
        XCTAssertNil(try vault.readCredential("openai.apiKey"), "an empty key removes the saved one")
    }

    /// The mark is saved before the key, so when the vault then refuses the
    /// key, the value already saved counts as saved by hand: a remote deletion
    /// leaves it, erring toward keeping a key rather than removing one.
    func testAKeyTheVaultRefusesLeavesTheSavedValueMarkedAsSavedByHand() async throws {
        let vault = RefusingVault()
        let store = try await stateWithAnImportedKey(at: directory.appendingPathComponent("refused.json"))

        do {
            try await DesktopKeyImport.saveByHand("typed", identifier: "openai.apiKey", in: store, vault: vault)
            XCTFail("The vault refused the key")
        } catch {
            XCTAssertTrue(error is RefusingVault.Refused)
        }
        let tombstone = CloudKitWebSyncedSecret(identifier: "openai.apiKey", value: nil, updatedAt: fixtureDate(2))
        let removed = try await store.update { try DesktopKeyImport.apply(tombstone, to: &$0, vault: vault) }
        XCTAssertNil(removed, "a remote deletion reached the value already saved")
    }

    private func serviceClient(_ service: DesktopCloudSyncService) async throws -> CloudKitWebServicesClient {
        let client = await service.client
        return try XCTUnwrap(client)
    }

    /// A signed-in service that imported the Mac's `openai.apiKey` as
    /// "imported", with History off so its passes only import keys.
    private func serviceWithAnImportedKey() async throws -> (DesktopCloudSyncService, DesktopCloudSyncStateStore) {
        try seedMacKeys(passphrase: passphrase, keys: ["openai.apiKey": "imported"])
        let (service, state) = try await signedInService()
        try await service.setHistoryEnabled(false)
        _ = try await service.enableKeyImport(passphrase: passphrase)
        XCTAssertEqual(try vault.readCredential("openai.apiKey"), "imported")
        return (service, state)
    }

    /// Sync state at `url` in which `openai.apiKey` holds the imported value.
    private func stateWithAnImportedKey(at url: URL) async throws -> DesktopCloudSyncStateStore {
        let store = try DesktopCloudSyncStateStore(url: url)
        try await store.update {
            $0.enabledFeatures = [.apiKeys]
            $0.importedKeys["openai.apiKey"] = .init(lastRemoteUpdate: fixtureDate(1), isImportedValue: true)
        }
        return store
    }

    /// Stands a directory where the sync state file is, so every write of the
    /// state fails, whoever runs the test, as on a failing disk. The returned
    /// closure puts the file back as it was, as a failed write leaves it.
    private func blockWrites(to url: URL) throws -> () throws -> Void {
        let saved = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("occupied"), withIntermediateDirectories: true
        )
        return {
            try FileManager.default.removeItem(at: url)
            try saved.write(to: url)
        }
    }
}

/// A credential store that refuses every change, as a locked-down one might.
private struct RefusingVault: DesktopCredentialVault {
    struct Refused: Error {}

    func readCredential(_ name: String) throws -> String? { nil }
    func writeCredential(_ value: String, name: String) throws { throw Refused() }
    func deleteCredential(_ name: String) throws { throw Refused() }
}
