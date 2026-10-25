#if os(iOS)
import Darwin
import SpeakCore
import XCTest
@testable import SpeakiOSLib

@MainActor
final class FocusCaptureOverrideStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testWriteInvalidChoiceReplacesValidAndDefaultResetRemovesEnvelopeButAdvancesGeneration() throws {
        let directory = try directory()
        let store = FocusCaptureOverrideStore(directory: directory)
        XCTAssertEqual(try store.snapshot(), .none)
        let valid = try store.write(FocusCaptureOverride(destinationID: "historyOnly"))
        let invalid = try store.write(FocusCaptureOverride(modelID: "deleted-model"))
        XCTAssertNotEqual(valid.generation, invalid.generation)
        XCTAssertEqual(invalid.invalidReason, .unknownModel)
        XCTAssertEqual(try FocusCaptureOverrideStore(directory: directory).snapshot(), invalid)
        let reset = try store.write(.none)
        XCTAssertNotEqual(reset.generation, invalid.generation)
        XCTAssertTrue(reset.hasBeenConfigured)
        XCTAssertTrue(reset.override.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("override.json").path))
    }

    func testDelayedNativeReadCannotOverwritePerformOrReset() throws {
        let store = FocusCaptureOverrideStore(directory: try directory())
        let old = try store.write(FocusCaptureOverride(destinationID: "clipboard"))
        let updated = try store.write(FocusCaptureOverride(destinationID: "historyOnly"))
        XCTAssertEqual(try store.write(.none, ifGeneration: old.generation, compare: true), updated)
        let reset = try store.write(.none)
        XCTAssertEqual(try store.write(updated.override, ifGeneration: updated.generation, compare: true), reset)
    }

    func testCorruptOrIncompleteStoreFailsClosedAndResetCanRepairIt() throws {
        let directory = try directory()
        let store = FocusCaptureOverrideStore(directory: directory)
        try store.write(FocusCaptureOverride(destinationID: "historyOnly"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("override.json"))
        XCTAssertThrowsError(try store.snapshot())
        XCTAssertTrue(try store.write(.none).override.isEmpty)
        try Data("bad json".utf8).write(to: directory.appendingPathComponent("generation.json"))
        XCTAssertThrowsError(try store.snapshot())
        XCTAssertTrue(try store.write(.none).override.isEmpty)
    }

    func testUnavailableAndContendedStoresFailWithoutGlobalFallbackOrWaiting() throws {
        XCTAssertThrowsError(try FocusCaptureOverrideStore(directory: nil).snapshot())
        let directory = try directory()
        let store = FocusCaptureOverrideStore(directory: directory)
        _ = try store.snapshot()
        let descriptor = open(directory.appendingPathComponent("store.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try store.write(.none))
    }

    func testVerifiedNeverConfiguredStoreDoesNotConsultNativeFocus() async throws {
        let store = FocusCaptureOverrideStore(directory: try directory())
        let result = try await FocusCaptureReconciliation.reconcile(store: store, explicit: .none) {
            XCTFail("Ordinary never-configured capture has no native lookup dependency")
            throw CancellationError()
        }
        XCTAssertEqual(result, .none)
    }

    func testNativeFailurePreservesPrivacyChoiceUnlessExplicitFieldSupersedesIt() async throws {
        let store = FocusCaptureOverrideStore(directory: try directory())
        try store.write(FocusCaptureOverride(destinationID: "historyOnly"))
        do {
            _ = try await FocusCaptureReconciliation.reconcile(store: store, explicit: .none) {
                throw FocusCaptureOverrideStore.Failure.nativeLookup
            }
            XCTFail("An unverifiable active privacy choice must refuse startup")
        } catch { XCTAssertEqual(CaptureStartFailurePresentation.make(for: error).code, "start_focus_unavailable") }
        XCTAssertEqual(try store.snapshot().override.destinationID, "historyOnly")
        let explicit = CaptureRunParameters(destinationID: "clipboard")
        let result = try await FocusCaptureReconciliation.reconcile(store: store, explicit: explicit) {
            throw FocusCaptureOverrideStore.Failure.nativeLookup
        }
        XCTAssertEqual(result.destinationID, "historyOnly",
                       "The resolver, not store mutation, applies explicit precedence")
    }

    func testNativeReconciliationCASConsumesNewPerformAndNativeDefaultClearsState() async throws {
        let store = FocusCaptureOverrideStore(directory: try directory())
        try store.write(FocusCaptureOverride(destinationID: "clipboard"))
        let result = try await FocusCaptureReconciliation.reconcile(store: store, explicit: .none) {
            try store.write(FocusCaptureOverride(destinationID: "historyOnly"))
            return .none
        }
        XCTAssertEqual(result.destinationID, "historyOnly")
        let reset = try await FocusCaptureReconciliation.reconcile(store: store, explicit: .none) { .none }
        XCTAssertTrue(reset.isEmpty)
        XCTAssertTrue(try store.snapshot().hasBeenConfigured)
    }
    func testNonregularMarkerAndCancelledNativeLookupFailSafelyWithoutClearingChoices() async throws {
        let directory = try directory()
        let store = FocusCaptureOverrideStore(directory: directory)
        let active = try store.write(FocusCaptureOverride(destinationID: "historyOnly"))
        do {
            _ = try await FocusCaptureReconciliation.reconcile(store: store, explicit: .none) {
                throw CancellationError()
            }
            XCTFail("Cancelled native lookup must not admit a capture")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try store.snapshot(), active)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("generation.json"))
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("generation.json"),
            withDestinationURL: directory.appendingPathComponent("missing.json")
        )
        XCTAssertThrowsError(try store.snapshot(), "A broken symlink is not proven absent state")
        XCTAssertTrue(try store.write(.none).override.isEmpty)
    }

    func testUnreadableExistingMarkerIsUnavailableRatherThanNeverConfigured() throws {
        let directory = try directory()
        let original = FocusCaptureOverrideStore(directory: directory)
        let active = try original.write(FocusCaptureOverride(destinationID: "historyOnly"))
        let unreadable = FocusCaptureOverrideStore(directory: directory, readData: { _ in
            throw CocoaError(.fileReadNoPermission)
        })
        XCTAssertThrowsError(try unreadable.snapshot()) { error in
            guard case .unavailable = error as? FocusCaptureOverrideStore.Failure else {
                return XCTFail("Unreadable storage must be a typed safe-start failure")
            }
        }
        XCTAssertEqual(try original.snapshot(), active, "A failed read must not clear the privacy choice")
        XCTAssertEqual(try FocusCaptureOverrideStore(directory: self.directory()).snapshot(), .none)
    }

    func testBlankNativeParametersUseTheDefaultResetPath() throws {
        let directory = try directory()
        let store = FocusCaptureOverrideStore(directory: directory)
        try store.write(FocusCaptureOverride(destinationID: "historyOnly"))
        var filter = DictationFocusFilter()
        filter.model = " \t"
        filter.language = "\n"
        XCTAssertTrue(filter.captureOverride.isEmpty)
        let reset = try store.write(filter.captureOverride)
        XCTAssertTrue(reset.override.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("override.json").path))
    }

}
#endif
