import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopSync
@testable import SpeakSync
import SpeakTestSupport
import XCTest

/// The user's latest choice about API keys decides: turning import off, or on
/// again, overtakes a turn-on still in progress, and a key typed by hand is
/// saved together with its mark, so a deletion synced from the Mac spares it.
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

    func testSavingByHandWritesTheKeyAndItsMarkTogether() throws {
        let vault = MemoryVault()
        var state = DesktopCloudSyncState()
        state.enabledFeatures = [.apiKeys]
        state.importedKeys["openai.apiKey"] = .init(lastRemoteUpdate: fixtureDate(1), isImportedValue: true)
        try vault.writeCredential("imported", name: "openai.apiKey")

        try DesktopKeyImport.saveByHand("typed", identifier: "openai.apiKey", in: &state, vault: vault)
        let tombstone = CloudKitWebSyncedSecret(identifier: "openai.apiKey", value: nil, updatedAt: fixtureDate(2))
        let removed = try DesktopKeyImport.apply(tombstone, to: &state, vault: vault)

        XCTAssertNil(removed)
        XCTAssertEqual(try vault.readCredential("openai.apiKey"), "typed")
        XCTAssertEqual(state.importedKeys["openai.apiKey"]?.isImportedValue, false)

        try DesktopKeyImport.saveByHand("", identifier: "openai.apiKey", in: &state, vault: vault)
        XCTAssertNil(try vault.readCredential("openai.apiKey"), "an empty key removes the saved one")
    }

    func testAKeyThatCannotBeSavedLeavesItsMarkAlone() {
        var state = DesktopCloudSyncState()
        state.importedKeys["openai.apiKey"] = .init(lastRemoteUpdate: fixtureDate(1), isImportedValue: true)

        XCTAssertThrowsError(
            try DesktopKeyImport.saveByHand("typed", identifier: "openai.apiKey", in: &state, vault: RefusingVault())
        ) { XCTAssertTrue($0 is RefusingVault.Refused) }
        XCTAssertEqual(state.importedKeys["openai.apiKey"]?.isImportedValue, true)
    }

    private func serviceClient(_ service: DesktopCloudSyncService) async throws -> CloudKitWebServicesClient {
        let client = await service.client
        return try XCTUnwrap(client)
    }
}

/// A credential store that refuses every change, as a locked-down one might.
private struct RefusingVault: DesktopCredentialVault {
    struct Refused: Error {}

    func readCredential(_ name: String) throws -> String? { nil }
    func writeCredential(_ value: String, name: String) throws { throw Refused() }
    func deleteCredential(_ name: String) throws { throw Refused() }
}
