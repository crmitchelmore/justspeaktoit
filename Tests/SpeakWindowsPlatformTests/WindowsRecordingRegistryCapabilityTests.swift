import CWindowsSupport
import Foundation
@testable import SpeakWindowsPlatform
import XCTest
#if os(Windows)
import WinSDK
#endif

final class WindowsRecordingRegistryCapabilityTests: XCTestCase {
    func testFullIdentityBytesRemainDistinct() throws {
        var first = JSTIRegistryIdentityV2()
        first.volume_serial = 42
        first.file_id.0 = 1
        var second = first
        second.file_id.15 = 1
        XCTAssertNotEqual(try WindowsRegistryIdentity(first), try WindowsRegistryIdentity(second))
        XCTAssertEqual(try WindowsRegistryIdentity(second).bytes.count, 16)
    }

    func testInvalidOutcomeCountIsNotRead() {
        var native = Self.empty()
        native.cause_count = JSTI_REGISTRY_MAX_CAUSES_V2 + 1
        XCTAssertThrowsError(try WindowsRegistryOutcome(native))
    }

    func testFullCauseBufferAndMalformedTypedFields() throws {
        var native = Self.empty()
        native.cause_count = JSTI_REGISTRY_MAX_CAUSES_V2
        native.primary_index = 0
        withUnsafeMutableBytes(of: &native.causes) { bytes in
            let causes = bytes.bindMemory(to: JSTIRegistryCauseV2.self)
            for index in 0..<Int(JSTI_REGISTRY_MAX_CAUSES_V2) {
                causes[index] = JSTIRegistryCauseV2(
                    kind: UInt32(index == 0 ? JSTI_REGISTRY_CAUSE_PRIMARY_V2 : JSTI_REGISTRY_CAUSE_SECONDARY_V2),
                    domain: UInt32(JSTI_REGISTRY_DOMAIN_CONTRACT_V2),
                    native_code: UInt32(JSTI_REGISTRY_CONTRACT_CHANGED_V2),
                    stage: UInt32(JSTI_REGISTRY_STAGE_POSTCOMMIT_V2), resource_id: 0
                )
            }
        }
        XCTAssertEqual(try WindowsRegistryOutcome(native).causes.count, 512)
        native.causes.0.domain = UInt32.max
        XCTAssertThrowsError(try WindowsRegistryOutcome(native))
        native = Self.empty()
        native.capability_poisoned = 2
        XCTAssertThrowsError(try WindowsRegistryOutcome(native))
    }

    func testCancellationRetainsOriginalAndPublishedCleanup() throws {
        let backend = RegistryFixtureBackend()
        backend.appendFailure = try Self.failure(published: true, cancellation: true, unconfirmed: true)
        let capability = WindowsRecordingRegistryCapability(backend: backend)
        XCTAssertThrowsError(try capability.append("registry.jloc", data: Data([1])) {
            throw RegistryFixtureError.cancelled
        }) { error in
            guard let failure = error as? WindowsRegistryFailure else { return XCTFail("Missing typed failure") }
            XCTAssertTrue(failure.published)
            XCTAssertEqual(failure.originalCancellation as? RegistryFixtureError, .cancelled)
            XCTAssertEqual(failure.outcomes[0].cleanupCount, 1)
            XCTAssertEqual(failure.outcomes[0].unconfirmedReleases, 1)
        }
        XCTAssertThrowsError(try capability.read("registry.jloc"))
        XCTAssertEqual(backend.readCalls, 0)
        XCTAssertThrowsError(try capability.close())
    }

    func testCloseFailureRemainsFailedWithoutRepeatedCloseOrDestroy() throws {
        let backend = RegistryFixtureBackend()
        backend.closeFailure = try Self.failure(published: false, cancellation: false, unconfirmed: true)
        backend.destroyFailure = backend.closeFailure
        let capability = WindowsRecordingRegistryCapability(backend: backend)
        XCTAssertThrowsError(try capability.close())
        XCTAssertThrowsError(try capability.close())
        XCTAssertEqual(backend.closeCalls, 1)
        XCTAssertEqual(backend.destroyCalls, 1)
        XCTAssertThrowsError(try capability.validate())
    }

    func testReportedCloseErrorDoesNotRequireClaimingRetention() throws {
        let backend = RegistryFixtureBackend()
        backend.closeFailure = try Self.failure(published: false, cancellation: false, unconfirmed: false)
        let capability = WindowsRecordingRegistryCapability(backend: backend)
        XCTAssertThrowsError(try capability.close()) { error in
            guard let failure = error as? WindowsRegistryFailure else { return XCTFail("Missing typed failure") }
            XCTAssertEqual(failure.outcomes[0].unconfirmedReleases, 0)
        }
        XCTAssertThrowsError(try capability.close())
        XCTAssertEqual(backend.closeCalls, 1)
    }

    func testCallbackReentryFailsWithoutDeadlockOrBackendIO() throws {
        let backend = RegistryFixtureBackend()
        let capability = WindowsRecordingRegistryCapability(backend: backend)
        XCTAssertThrowsError(try capability.append("registry.jloc", data: Data([1])) {
            try capability.validate()
        }) { error in
            let failure = error as? WindowsRegistryFailure
            guard case .reentrant? = failure?.originalCancellation as? WindowsRegistryCapabilityError else {
                return XCTFail("Original reentry error was lost")
            }
        }
        XCTAssertEqual(backend.validateCalls, 0)
        try capability.close()
    }

    func testNativeV2SyntheticReload() throws {
        #if os(Windows)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var nativeError = [CChar](repeating: 0, count: 1_024)
        let created = nativeError.withUnsafeMutableBufferPointer {
            jsti_private_directory_create(root.path, $0.baseAddress, $0.count)
        }
        guard created == 0 else {
            throw NSError(domain: "JSTIWindowsRecordingRegistry", code: Int(created), userInfo: [
                NSLocalizedDescriptionKey: String(cString: nativeError)
            ])
        }
        defer {
            do { try FileManager.default.removeItem(at: root) } catch {
                XCTFail("Synthetic fixture cleanup failed: \(error)")
            }
        }
        let diagnostics = ProcessInfo.processInfo.environment["JSTI_REGISTRY_DIAGNOSTICS"] == "1"
        if diagnostics {
            print("REGISTRY DIAGNOSTIC nativeV2 historyURL=\(root.absoluteString) path=\(root.path)")
            print("REGISTRY DIAGNOSTIC nativeV2 standardized=\(root.standardizedFileURL.path)")
            print("REGISTRY DIAGNOSTIC nativeV2 verifyBegin")
        }
        do {
            try WindowsRecordingRegistry.verifyV2SyntheticReload(history: root)
            if diagnostics { print("REGISTRY DIAGNOSTIC nativeV2 verifyReturned") }
        } catch {
            if diagnostics { print("REGISTRY DIAGNOSTIC nativeV2 error=\(String(reflecting: error))") }
            throw error
        }
        #else
        throw XCTSkip("Native NTFS C/Swift runtime is not qualified by this stub build.")
        #endif
    }

    func testNativeV2PublicationPreservesBytesAndRefusesReplacement() throws {
        #if os(Windows)
        try self.withNativeHistory { history in
            let writer = try WindowsRecordingRegistryCapability(history: history, initialize: true)
            defer {
                do { try writer.close() } catch { XCTFail("Writer cleanup failed: \(error)") }
            }
            let identity = try writer.identity()
            let payload = Data("immutable native publication".utf8)
            let outcome = try writer.append("registry.jloc", data: payload, checkCancellation: {})
            XCTAssertTrue(outcome.published)
            XCTAssertTrue(outcome.causes.isEmpty)
            XCTAssertFalse(outcome.poisoned)
            XCTAssertEqual(outcome.unconfirmedReleases, 0)
            XCTAssertThrowsError(try writer.append("registry.jloc", data: Data([92]), checkCancellation: {})) {
                guard let failure = $0 as? WindowsRegistryFailure else {
                    return XCTFail("Expected native no-replacement failure")
                }
                XCTAssertFalse(failure.published)
            }
            XCTAssertEqual(try writer.names(), ["registry.jloc"])
            XCTAssertEqual(try writer.read("registry.jloc"), payload)
            try writer.close()
            let reader = try WindowsRecordingRegistryCapability(history: history, initialize: false)
            defer {
                do { try reader.close() } catch { XCTFail("Reader cleanup failed: \(error)") }
            }
            let reloadedIdentity = try reader.identity()
            XCTAssertEqual(reloadedIdentity.0, identity.0)
            XCTAssertEqual(reloadedIdentity.1, identity.1)
            XCTAssertEqual(try reader.read("registry.jloc"), payload)
        }
        #else
        throw XCTSkip("Requires native NTFS publication.")
        #endif
    }

    func testNativeV2WriterFenceAndAncestryFenceAreIndependentOfPublication() throws {
        #if os(Windows)
        try self.withNativeHistory { history in
            let writer = try WindowsRecordingRegistryCapability(history: history, initialize: true)
            defer {
                do { try writer.close() } catch { XCTFail("Writer cleanup failed: \(error)") }
            }
            XCTAssertThrowsError(try WindowsRecordingRegistryCapability(history: history, initialize: false)) {
                guard let failure = $0 as? WindowsRegistryFailure else {
                    return XCTFail("Expected native sharing fence")
                }
                XCTAssertTrue(failure.outcomes.flatMap(\.causes).contains {
                    $0.domain == JSTI_REGISTRY_DOMAIN_NTSTATUS_V2 &&
                        $0.code == 0xC000_0043 && $0.stage == JSTI_REGISTRY_STAGE_OPEN_V2
                })
            }
            for source in [history.appendingPathComponent(".recording-locations"), history] {
                let oldName = Array(source.path.utf16) + [UInt16(0)]
                let newName = Array((source.path + ".moved").utf16) + [UInt16(0)]
                oldName.withUnsafeBufferPointer { old in
                    newName.withUnsafeBufferPointer { new in
                        XCTAssertEqual(MoveFileW(old.baseAddress, new.baseAddress), 0)
                    }
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: source.path + ".moved"))
            }
            try writer.validate()
            XCTAssertTrue(try writer.names().isEmpty)
            try writer.close()
            let reopened = try WindowsRecordingRegistryCapability(history: history, initialize: false)
            try reopened.validate()
            try reopened.close()
        }
        #else
        throw XCTSkip("Requires native NTFS sharing and ancestry fences.")
        #endif
    }

    func testNativeExplicitOwnerSyntheticDirectoryAcceptsPrivatePreparationButNotRecreation() throws {
        #if os(Windows)
        try self.withNativeHistory { history in
            var error = [CChar](repeating: 0, count: 1_024)
            let prepared = error.withUnsafeMutableBufferPointer {
                jsti_private_directory_prepare(history.path, $0.baseAddress, $0.count)
            }
            XCTAssertEqual(prepared, 0, String(cString: error))
            let recreated = error.withUnsafeMutableBufferPointer {
                jsti_private_directory_create(history.path, $0.baseAddress, $0.count)
            }
            XCTAssertEqual(recreated, -1)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: history.path).isEmpty)
        }
        #else
        throw XCTSkip("Requires native token-owner and ACL verification.")
        #endif
    }

    #if os(Windows)
    private func withNativeHistory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var error = [CChar](repeating: 0, count: 1_024)
        let created = error.withUnsafeMutableBufferPointer {
            jsti_private_directory_create(root.path, $0.baseAddress, $0.count)
        }
        guard created == 0 else {
            throw NSError(domain: "JSTIWindowsRecordingRegistry", code: Int(created), userInfo: [
                NSLocalizedDescriptionKey: String(cString: error)
            ])
        }
        defer {
            do { try FileManager.default.removeItem(at: root) } catch {
                XCTFail("Synthetic fixture cleanup failed: \(error)")
            }
        }
        try body(root)
    }
    #endif

    private static func empty() -> JSTIRegistryOutcomeV2 {
        var native = JSTIRegistryOutcomeV2()
        native.abi_version = JSTI_REGISTRY_ABI_V2
        native.struct_size = UInt32(MemoryLayout<JSTIRegistryOutcomeV2>.size)
        native.primary_index = UInt32.max
        return native
    }

    fileprivate static func failure(
        published: Bool, cancellation: Bool, unconfirmed: Bool
    ) throws -> WindowsRegistryFailure {
        var native = Self.empty()
        native.effect = published ? UInt32(JSTI_REGISTRY_EFFECT_PUBLISHED_V2) : 0
        native.primary_index = 0
        native.cause_count = cancellation ? 2 : 1
        native.cleanup_count = 1
        native.close_attempt_count = 1
        native.release_unconfirmed_count = unconfirmed ? 1 : 0
        native.capability_poisoned = unconfirmed ? 1 : 0
        withUnsafeMutableBytes(of: &native.causes) { bytes in
            let causes = bytes.bindMemory(to: JSTIRegistryCauseV2.self)
            let cleanup = JSTIRegistryCauseV2(
                kind: UInt32(JSTI_REGISTRY_CAUSE_CLEANUP_V2), domain: UInt32(JSTI_REGISTRY_DOMAIN_WIN32_V2),
                native_code: 42, stage: UInt32(JSTI_REGISTRY_STAGE_CLOSE_V2), resource_id: 7
            )
            if cancellation {
                causes[0] = JSTIRegistryCauseV2(
                    kind: UInt32(JSTI_REGISTRY_CAUSE_PRIMARY_V2),
                    domain: UInt32(JSTI_REGISTRY_DOMAIN_CONTRACT_V2),
                    native_code: UInt32(JSTI_REGISTRY_CONTRACT_CANCELLED_V2),
                    stage: UInt32(JSTI_REGISTRY_STAGE_POSTCOMMIT_V2), resource_id: 0
                )
                causes[1] = cleanup
            } else {
                causes[0] = cleanup
            }
        }
        return try WindowsRegistryFailure(outcomes: [WindowsRegistryOutcome(native)], originalCancellation: nil)
    }
}

private enum RegistryFixtureError: Error { case cancelled }

private final class RegistryFixtureBackend: WindowsRegistryBackend {
    var appendFailure: WindowsRegistryFailure?
    var closeFailure: WindowsRegistryFailure?
    var destroyFailure: WindowsRegistryFailure?
    var readCalls = 0
    var validateCalls = 0
    var closeCalls = 0
    var destroyCalls = 0

    func identity() throws -> (WindowsRegistryIdentity, WindowsRegistryIdentity) {
        var native = JSTIRegistryIdentityV2()
        native.file_id.0 = 1
        let identity = try WindowsRegistryIdentity(native)
        return (identity, identity)
    }

    func names() throws -> [String] { [] }
    func read(_ name: String) throws -> Data { self.readCalls += 1; return Data() }
    func validate() throws { self.validateCalls += 1 }

    func append(
        _ name: String, data: Data, cancelled: (UInt32) -> Int32
    ) throws -> WindowsRegistryOutcome {
        _ = cancelled(UInt32(JSTI_REGISTRY_CHECK_POSTCOMMIT_V2))
        if let failure = self.appendFailure { throw failure }
        throw try WindowsRecordingRegistryCapabilityTests.failure(
            published: true, cancellation: true, unconfirmed: false
        )
    }

    func close() throws {
        self.closeCalls += 1
        if let failure = self.closeFailure { throw failure }
    }

    func destroy() throws {
        self.destroyCalls += 1
        if let failure = self.destroyFailure { throw failure }
    }
}
