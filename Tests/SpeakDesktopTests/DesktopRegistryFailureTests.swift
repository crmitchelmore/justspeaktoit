import Foundation
import XCTest
@testable import SpeakDesktop
#if os(Linux)
import Glibc
#endif

final class DesktopRegistryFailureTests: XCTestCase {
    func testForeignRegistrationEnvelopeAndMissingHeaderRemainUnapplied() throws {
        #if !os(Linux)
        throw XCTSkip("Requires Linux native registration storage.")
        #else
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        let original = try DesktopLocalRecordingPersistence.initialize(historyDirectory: fixture.history)
        var local = try DesktopRecordingLocations(historyDirectory: fixture.history, persistence: original)
        let id = try local.authorizeLocallySelectedRoot(fixture.first)
        try original.close()
        let foreign = try DesktopLocalRecordingPersistence.initialize(historyDirectory: fixture.second)
        var other = try DesktopRecordingLocations(historyDirectory: fixture.second, persistence: foreign)
        _ = try other.authorizeLocallySelectedRoot(fixture.first, id: id)
        try foreign.close()
        let filename = "registration-\(id.uuidString).jloc"
        let target = fixture.history.appendingPathComponent(".recording-locations/" + filename)
        let source = fixture.second.appendingPathComponent(".recording-locations/" + filename)
        try FileManager.default.removeItem(at: target)
        try Data(contentsOf: source).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: target.path)
        let reopened = try DesktopLocalRecordingPersistence.open(historyDirectory: fixture.history)
        XCTAssertThrowsError(try DesktopRecordingLocations(historyDirectory: fixture.history, persistence: reopened))
        try reopened.close()
        let header = fixture.history.appendingPathComponent(".recording-locations/registry.jloc")
        try FileManager.default.removeItem(at: header)
        XCTAssertThrowsError(try DesktopLocalRecordingPersistence.open(historyDirectory: fixture.history))
        #endif
    }

    func testMutableUnreadableHardlinkedFIFOAndIncompleteLeavesFailExplicitly() throws {
        #if !os(Linux)
        throw XCTSkip("Requires native Linux file qualification.")
        #else
        for variant in ["mutable", "unreadable", "hardlink", "fifo", "pending"] {
            let fixture = try RecordingLocationFixture()
            defer { try? fixture.clean() }
            let persistence = try DesktopLocalRecordingPersistence.initialize(historyDirectory: fixture.history)
            let root = fixture.history.appendingPathComponent(".recording-locations")
            let header = root.appendingPathComponent("registry.jloc")
            switch variant {
            case "mutable":
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: header.path)
            case "unreadable":
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: header.path)
            case "hardlink":
                XCTAssertEqual(link(header.path, fixture.first.appendingPathComponent("unrelated.jloc").path), 0)
            case "fifo":
                let name = root.appendingPathComponent("registration-\(UUID().uuidString).jloc")
                XCTAssertEqual(mkfifo(name.path, 0o600), 0)
            default:
                try Data([92]).write(to: root.appendingPathComponent(".pending-" + UUID().uuidString))
            }
            XCTAssertThrowsError(try persistence.loadVerified())
            try persistence.close()
        }
        #endif
    }

    func testIdentityMismatchClosesBeforePublishingAnyHeader() throws {
        #if !os(Linux)
        throw XCTSkip("Uses qualified native Linux namespace behind injected identity failure.")
        #else
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        let probe = RegistryIdentityFailureProbe()
        let factory = DesktopRecordingRegistryFactory { history, initialize in
            let native = try DesktopPOSIXRecordingRegistry(history: history, initialize: initialize)
            probe.native = native
            return probe
        }
        XCTAssertThrowsError(try DesktopLocalRecordingPersistence.initialize(
            historyDirectory: fixture.history, using: factory
        )) { error in
            guard case DesktopRecordingRegistryError.identityUnavailable = error else {
                return XCTFail("Expected insufficient identity, not a persistence fallback.")
            }
        }
        XCTAssertEqual(probe.closes, 1)
        XCTAssertEqual(probe.appends, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            atPath: fixture.history.appendingPathComponent(".recording-locations").path
        ).isEmpty)
        #endif
    }

    func testInitializationCancellationEffectsAndPrivateNamespaceAdmission() async throws {
        #if !os(Linux)
        throw XCTSkip("Requires qualified native Linux append effects.")
        #else
        for cancellationCheck in [3, 4] {
            let fixture = try RecordingLocationFixture()
            defer { try? fixture.clean() }
            let cancellation = RegistryCancellationProbe(target: cancellationCheck)
            XCTAssertThrowsError(try DesktopLocalRecordingPersistence.initialize(
                historyDirectory: fixture.history, checkCancellation: { try cancellation.check() }
            )) { error in
                guard let failure = error as? DesktopRecordingRegistryWriteFailure else {
                    return XCTFail("Expected a known publication effect.")
                }
                XCTAssertTrue(failure.primaryError is CancellationError)
                switch failure.effect {
                case .published: XCTAssertEqual(cancellationCheck, 4)
                case .unpublished: XCTAssertEqual(cancellationCheck, 3)
                }
            }
            if cancellationCheck == 3 {
                XCTAssertThrowsError(try DesktopLocalRecordingPersistence.open(historyDirectory: fixture.history))
            } else {
                let reopened = try DesktopLocalRecordingPersistence.open(historyDirectory: fixture.history)
                defer { try? reopened.close() }
                var locations = try DesktopRecordingLocations(historyDirectory: fixture.history, persistence: reopened)
                let root = fixture.history.appendingPathComponent(".recording-locations")
                XCTAssertThrowsError(try locations.authorizeLocallySelectedRoot(root))
                XCTAssertTrue(try reopened.loadVerified().registrations.isEmpty)
                let store = try DesktopRecordingStore(directory: fixture.history, audioLocations: locations)
                let header = root.appendingPathComponent("registry.jloc")
                let bytes = try Data(contentsOf: header)
                do {
                    try await store.exportTranscriptSnapshot("must not replace registry", to: header)
                    XCTFail("History's existing protected export boundary must cover private registration.")
                } catch {
                    XCTAssertEqual(try Data(contentsOf: header), bytes)
                }
            }
        }
        #endif
    }

    func testInjectedTypedAppendAndCloseFailuresPreserveEffectAndCloseOnce() throws {
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        for effect in [DesktopRecordingRegistryWriteFailure.Effect.unpublished, .published] {
            let probe = try RegistryWriteFailureProbe(history: fixture.history, effect: effect)
            XCTAssertThrowsError(try DesktopLocalRecordingPersistence.initialize(
                historyDirectory: fixture.history, using: .init { _, _ in probe }
            )) { error in
                guard let cleanup = error as? DesktopRecordingLocationCleanupFailure,
                      let publication = cleanup.primaryError as? DesktopRecordingRegistryWriteFailure else {
                    return XCTFail("Typed publication and teardown causes must survive initialization failure.")
                }
                XCTAssertTrue(publication.primaryError is RegistryInjectedFailure)
                XCTAssertTrue(publication.cleanupError is RegistryInjectedFailure)
                XCTAssertTrue(cleanup.cleanupError is RegistryInjectedFailure)
                switch (effect, publication.effect) {
                case (.unpublished, .unpublished), (.published, .published): break
                default: XCTFail("The immutable publication effect was lost.")
                }
            }
            XCTAssertEqual(probe.appends, 1)
            XCTAssertEqual(probe.closes, 1)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: fixture.history.appendingPathComponent(".recording-locations").path
            ))
        }
        let postcommit = try RegistryWriteFailureProbe(history: fixture.history, effect: .published)
        postcommit.appendSucceeds = true
        XCTAssertThrowsError(try DesktopLocalRecordingPersistence.initialize(
            historyDirectory: fixture.history, using: .init { _, _ in postcommit }
        )) { error in
            guard let cleanup = error as? DesktopRecordingLocationCleanupFailure,
                  let publication = cleanup.primaryError as? DesktopRecordingRegistryWriteFailure,
                  case .published = publication.effect else {
                return XCTFail("Postcommit validation failure must retain the published effect.")
            }
            guard case RegistryInjectedFailure.validation = publication.primaryError else {
                return XCTFail("Postcommit validation must retain its original typed cause.")
            }
        }
        XCTAssertEqual(postcommit.appends, 1)
        XCTAssertEqual(postcommit.closes, 1)
    }

    func testAnonymousAbortLeavesDecoyUntouchedAndClosesOnlyOwnedDescriptor() throws {
        #if !os(Linux)
        throw XCTSkip("Requires qualified held Linux append and owned cleanup.")
        #else
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        let native = try DesktopPOSIXRecordingRegistry(history: fixture.history, initialize: true)
        defer { try? native.close() }
        let root = fixture.history.appendingPathComponent(".recording-locations")
        var checks = 0
        let replacement = root.appendingPathComponent(".pending-decoy")
        var descriptor: Int32 = -1
        XCTAssertThrowsError(try native.append("registry.jloc", data: Data([1, 2, 3]), checkCancellation: {
            checks += 1
            if checks == 2 {
                let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
                XCTAssertTrue(names.isEmpty)
                descriptor = try RegistryAnonymousFixture.descriptor(in: root)
                try Data([92]).write(to: replacement)
                throw RegistryInjectedFailure.append
            }
        })) { error in
            guard let failure = error as? DesktopRecordingRegistryWriteFailure else {
                return XCTFail("Expected separate typed primary and owned-cleanup failures.")
            }
            XCTAssertTrue(failure.primaryError is RegistryInjectedFailure)
            XCTAssertNil(failure.cleanupError)
            guard case .unpublished = failure.effect else { return XCTFail("Must not publish substituted data.") }
        }
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(try Data(contentsOf: replacement), Data([92]))
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
        XCTAssertThrowsError(try native.names())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("registry.jloc").path))
        #endif
    }

    func testLinkedNamespaceAndInsecureHistoryAncestryAreNotRepaired() throws {
        #if !os(Linux)
        throw XCTSkip("Requires native no-follow POSIX ancestry qualification.")
        #else
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        let persistence = try DesktopLocalRecordingPersistence.initialize(historyDirectory: fixture.history)
        try persistence.close()
        let root = fixture.history.appendingPathComponent(".recording-locations")
        let saved = fixture.history.appendingPathComponent(".saved-recording-locations")
        let original = try Data(contentsOf: root.appendingPathComponent("registry.jloc"))
        try FileManager.default.moveItem(at: root, to: saved)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: saved)
        XCTAssertThrowsError(try DesktopLocalRecordingPersistence.open(historyDirectory: fixture.history))
        try FileManager.default.removeItem(at: root)
        try FileManager.default.moveItem(at: saved, to: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: fixture.root.path)
        XCTAssertThrowsError(try DesktopLocalRecordingPersistence.open(historyDirectory: fixture.history))
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.root.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o777)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("registry.jloc")), original)
        #endif
    }
}

private enum RegistryInjectedFailure: Error { case append, cleanup, close, validation }

private final class RegistryWriteFailureProbe: DesktopRecordingRegistryNamespace, @unchecked Sendable {
    let historyDevice: UInt64
    let historyFile: UInt64
    let namespaceDevice: UInt64 = 1
    let namespaceFile: UInt64 = 1
    let effect: DesktopRecordingRegistryWriteFailure.Effect
    var appends = 0
    var closes = 0
    var appendSucceeds = false

    init(history: URL, effect: DesktopRecordingRegistryWriteFailure.Effect) throws {
        let identity = try DesktopRecordingLocationIdentity.directory(history)
        self.historyDevice = identity.device
        self.historyFile = identity.file
        self.effect = effect
    }

    func names() throws -> [String] { [] }
    func read(_: String) throws -> Data { throw DesktopRecordingRegistryError.missing }
    func append(_: String, data _: Data, checkCancellation _: () throws -> Void) throws {
        appends += 1
        if appendSucceeds { return }
        throw DesktopRecordingRegistryWriteFailure(
            primaryError: RegistryInjectedFailure.append, cleanupError: RegistryInjectedFailure.cleanup, effect: effect
        )
    }
    func validate() throws { throw RegistryInjectedFailure.validation }
    func close() throws { closes += 1; throw RegistryInjectedFailure.close }
}

private final class RegistryCancellationProbe: @unchecked Sendable {
    let target: Int
    private var calls = 0
    init(target: Int) { self.target = target }
    func check() throws {
        calls += 1
        if calls == target { throw CancellationError() }
    }
}

#if os(Linux)
private final class RegistryIdentityFailureProbe: DesktopRecordingRegistryNamespace, @unchecked Sendable {
    var native: DesktopPOSIXRecordingRegistry?
    var closes = 0
    var appends = 0
    var historyDevice: UInt64 { native?.historyDevice ?? 0 }
    var historyFile: UInt64 { (native?.historyFile ?? 0) ^ 1 }
    var namespaceDevice: UInt64 { native?.namespaceDevice ?? 0 }
    var namespaceFile: UInt64 { native?.namespaceFile ?? 0 }
    func names() throws -> [String] { try requiredNative().names() }
    func read(_ name: String) throws -> Data { try requiredNative().read(name) }
    func append(_ name: String, data: Data, checkCancellation: () throws -> Void) throws {
        appends += 1
        try requiredNative().append(name, data: data, checkCancellation: checkCancellation)
    }
    func validate() throws { try requiredNative().validate() }
    func close() throws { closes += 1; try requiredNative().close() }
    private func requiredNative() throws -> DesktopPOSIXRecordingRegistry {
        guard let native else { throw DesktopRecordingRegistryError.closed }
        return native
    }
}
#endif
