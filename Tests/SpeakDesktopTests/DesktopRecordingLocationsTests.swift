import Foundation
import SpeakCore
import XCTest
@testable import SpeakDesktop

final class DesktopRecordingLocationsTests: XCTestCase {
    func testLegacyAndTwoChoicesResolveAcrossInjectedVerifiedRestart() async throws {
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        let store = try fixture.store()
        let legacy = DesktopRecordingStore.Record(id: UUID(), audioFilename: "legacy.wav", modelIdentifier: "legacy")
        let legacyURL = fixture.history.appendingPathComponent(legacy.audioFilename)
        try Data([7]).write(to: legacyURL)
        try await store.save(legacy)
        let firstID = try await store.authorizeLocallySelectedAudioRoot(fixture.first)
        let first = try await fixture.capture(store, location: firstID)
        let secondID = try await store.authorizeLocallySelectedAudioRoot(fixture.second)
        let second = try await fixture.capture(store, location: secondID)
        let thirdID = try await store.authorizeLocallySelectedAudioRoot(fixture.first)
        let third = try await fixture.capture(store, location: thirdID)
        let expected = PCMWaveWriter.wavData(pcm: Data([1, 2, 3, 4]), sampleRate: 16_000)
        for record in [first, second, third] {
            let data = try await store.readAudio(for: record, maximumBytes: 1_024)
            XCTAssertEqual(data, expected)
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: fixture.history.appendingPathComponent(record.id.uuidString + ".json").path
            ))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: fixture.history.appendingPathComponent(record.audioFilename).path
            ))
        }
        let restarted = try fixture.store()
        let legacyResolved = try await restarted.audioURL(for: legacy)
        XCTAssertEqual(legacyResolved, legacyURL)
        for record in [first, second, third] {
            let restored = try await restarted.record(id: record.id)
            XCTAssertEqual(restored.localAudio, record.localAudio)
            let data = try await restarted.readAudio(for: restored, maximumBytes: 1_024)
            XCTAssertEqual(data, expected)
        }
        let directory = await restarted.directory
        XCTAssertEqual(directory, fixture.history)
    }

    func testRegistrationFailureKeepsPreviousWorkingChoiceAndDoesNotCreateRoots() async throws {
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        let store = try fixture.store()
        let location = try await store.authorizeLocallySelectedAudioRoot(fixture.first)
        fixture.memory.failure = .registration
        do {
            _ = try await store.authorizeLocallySelectedAudioRoot(fixture.second)
            XCTFail("Failed persistence must not activate a location.")
        } catch { XCTAssertTrue(error is RecordingLocationMemoryPersistence.Failure) }
        fixture.memory.failure = nil
        _ = try await fixture.capture(store, location: location)
        let missing = fixture.root.appendingPathComponent("missing")
        do {
            _ = try await store.authorizeLocallySelectedAudioRoot(missing)
            XCTFail("Selection must not create an absent root.")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testForeignUnregisteredAndDuplicateRegistrationsAreRejected() async throws {
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        let store = try fixture.store()
        let id = try await store.authorizeLocallySelectedAudioRoot(fixture.first)
        do {
            _ = try await store.authorizeLocallySelectedAudioRoot(fixture.second, id: id)
            XCTFail("Immutable identities must not be overwritten.")
        } catch { XCTAssertTrue(error is DesktopRecordingLocationError) }
        XCTAssertThrowsError(try DesktopRecordingLocations(
            historyDirectory: fixture.second, persistence: fixture.memory
        ))
        do {
            _ = try await store.createLocallyAuthorizedCapture(at: UUID())
            XCTFail("Unknown location must not create audio.")
        } catch { XCTAssertTrue(error is DesktopRecordingLocationError) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.first.path).isEmpty)
    }

    func testImportedAbsoluteAndForgedCollidingReferencesNeverGrantAccess() async throws {
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        let store = try fixture.store()
        let location = try await store.authorizeLocallySelectedAudioRoot(fixture.first)
        let original = try await fixture.capture(store, location: location)
        let value = try DesktopMigrationHistory.value(original)
        let item = try DataMigrationCoding.decode(ApplicationHistoryItem.self, value)
        let desktop = try XCTUnwrap(item.desktopHistory)
        guard case .object(var fields) = desktop.storage else { return XCTFail("Expected desktop fields") }
        XCTAssertNil(fields["localAudio"])
        fields["localAudio"] = .object([
            "locationID": .string(location.uuidString), "relativePath": .string(fixture.first.path)
        ])
        guard case .object(var outer) = value.storage else { return XCTFail("Expected History") }
        outer["desktopHistory"] = .object(fields)
        let foreignValue = AnyCodable(.object(outer))
        let imported = try DesktopMigrationHistory.record(.init(
            id: original.id.uuidString, kind: "history", value: foreignValue, date: item.createdAt
        ), category: .history, audioFilename: original.audioFilename)
        XCTAssertNil(imported.localAudio)
        XCTAssertEqual(imported.migrationMetadata, foreignValue)
        // The raw forged value is retained verbatim in migrationMetadata (asserted above), but the
        // portable export never re-exposes a localAudio claim, forged or genuine: strip it here too.
        var sanitizedFields = fields
        sanitizedFields.removeValue(forKey: "localAudio")
        var sanitizedOuter = outer
        sanitizedOuter["desktopHistory"] = .object(sanitizedFields)
        XCTAssertEqual(try DesktopMigrationHistory.value(imported), AnyCodable(.object(sanitizedOuter)))
        do {
            _ = try await store.audioURL(for: imported)
            XCTFail("A colliding imported ID must resolve only in History, where audio is absent.")
        } catch {}
        var forged = original
        forged.localAudio = .init(locationID: location, relativePath: "../unrelated.wav")
        do {
            _ = try await store.audioURL(for: forged)
            XCTFail("Metadata cannot replace a sealed claim.")
        } catch {}
        let otherStore = try DesktopRecordingStore(directory: fixture.history)
        do {
            _ = try await otherStore.audioURL(for: original)
            XCTFail("Record metadata alone must not restore local authorization.")
        } catch {}
        let absolute = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: fixture.first.path, modelIdentifier: "foreign"
        )
        do {
            _ = try await store.audioURL(for: absolute)
            XCTFail("Absolute paths are never audio authority.")
        } catch {}
    }

    func testCaptureIDCollisionDoesNotCreateOrReplaceAudio() async throws {
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        let store = try fixture.store()
        let location = try await store.authorizeLocallySelectedAudioRoot(fixture.first)
        let original = try await fixture.capture(store, location: location)
        let before = try await store.readAudio(for: original, maximumBytes: 1_024)
        do {
            _ = try await store.createLocallyAuthorizedCapture(at: location, recordingID: original.id)
            XCTFail("Existing History IDs must be reserved before allocation.")
        } catch { XCTAssertTrue(error is DesktopRecordingLocationError) }
        let data = try await store.readAudio(for: original, maximumBytes: 1_024)
        XCTAssertEqual(data, before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.first.path).count, 1)
    }
}
