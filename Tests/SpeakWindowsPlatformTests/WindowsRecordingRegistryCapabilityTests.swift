import CWindowsSupport
import Foundation
@testable import SpeakWindowsPlatform
import XCTest

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
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: root) } catch {
                XCTFail("Synthetic fixture cleanup failed: \(error)")
            }
        }
        try WindowsRecordingRegistry.verifyV2SyntheticReload(history: root)
        #else
        throw XCTSkip("Native NTFS C/Swift runtime is not qualified by this stub build.")
        #endif
    }

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
