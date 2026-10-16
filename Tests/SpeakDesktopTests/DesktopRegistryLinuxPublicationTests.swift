import Foundation
import XCTest
@testable import SpeakDesktop
#if os(Linux)
import CRecordingFileSupport
import Glibc

final class DesktopRegistryLinuxPublicationTests: XCTestCase {
    func testRealAnonymousSourceCannotBeSubstitutedByNamedDecoys() throws {
        let fixture = try RegistryAnonymousFixture()
        defer { try? fixture.clean() }
        var file: Int32 = -1
        try fixture.native.append("registry.jloc", data: fixture.payload, checkCancellation: {
            if fixture.nextCheck() == 2 {
                file = try RegistryAnonymousFixture.descriptor(in: fixture.namespace)
                XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.namespace.path).isEmpty)
                try Data([92]).write(to: fixture.namespace.appendingPathComponent(".pending-decoy"))
            }
        })
        XCTAssertEqual(try fixture.native.read("registry.jloc"), fixture.payload)
        XCTAssertEqual(try fixture.bytes(".pending-decoy"), Data([92]))
        XCTAssertEqual(fcntl(file, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
        XCTAssertEqual(try fixture.leaves(), [".pending-decoy", "registry.jloc"])
    }

    func testPostThirdCallbackMutationsNeverReturnSuccessOrRemoveForeignData() throws {
        for mutation in ["replacement", "bytes", "permissions", "hardlink", "namespace", "history", "cancel"] {
            let fixture = try RegistryAnonymousFixture()
            defer { try? fixture.clean() }
            var file: Int32 = -1
            XCTAssertThrowsError(try fixture.native.append("registry.jloc", data: fixture.payload,
                                                          checkCancellation: {
                let check = fixture.nextCheck()
                if check == 2 { file = try RegistryAnonymousFixture.descriptor(in: fixture.namespace) }
                if check == 3 { try fixture.mutate(mutation, file: file) }
            })) { error in
                guard let failure = error as? DesktopRecordingRegistryWriteFailure,
                      case .published = failure.effect else {
                    return XCTFail("Postcommit mutation must retain its published effect.")
                }
                XCTAssertNil(failure.cleanupError)
                if mutation == "cancel" { XCTAssertTrue(failure.primaryError is CancellationError) }
            }
            XCTAssertEqual(fixture.checks, 3)
            XCTAssertEqual(fcntl(file, F_GETFD), -1)
            XCTAssertEqual(errno, EBADF)
            try fixture.checkRetained(mutation)
        }
    }

    func testPostCancellationStillChecksChangedPublishedBytes() throws {
        let fixture = try RegistryAnonymousFixture()
        defer { try? fixture.clean() }
        XCTAssertThrowsError(try fixture.native.append("registry.jloc", data: fixture.payload, checkCancellation: {
            if fixture.nextCheck() == 3 {
                let file = try RegistryAnonymousFixture.descriptor(in: fixture.namespace, links: 1)
                try fixture.mutate("bytes", file: file)
                throw CancellationError()
            }
        })) { error in
            guard let failure = error as? DesktopRecordingRegistryWriteFailure,
                  let combined = failure.primaryError as? DesktopRecordingLocationCleanupFailure,
                  case .published = failure.effect else {
                return XCTFail("Cancellation and the subsequent content fence must both remain inspectable.")
            }
            XCTAssertTrue(combined.primaryError is CancellationError)
            guard case DesktopRecordingRegistryError.corrupt = combined.cleanupError else {
                return XCTFail("The exact-content check must run even after cancellation.")
            }
        }
        XCTAssertEqual(try fixture.bytes("registry.jloc"), Data([7, 2, 3]))
    }

    func testSameInodePreLinkByteChangePublishesButCannotReturnSuccess() throws {
        let fixture = try RegistryAnonymousFixture()
        defer { try? fixture.clean() }
        XCTAssertThrowsError(try fixture.native.append("registry.jloc", data: fixture.payload, checkCancellation: {
            if fixture.nextCheck() == 2 {
                try fixture.mutate("bytes", file: RegistryAnonymousFixture.descriptor(in: fixture.namespace))
            }
        })) { error in
            guard let failure = error as? DesktopRecordingRegistryWriteFailure,
                  case .published = failure.effect,
                  case DesktopRecordingRegistryError.corrupt = failure.primaryError else {
                return XCTFail("Held descriptor identity alone must not attest unchanged bytes.")
            }
        }
        XCTAssertEqual(try fixture.bytes("registry.jloc"), Data([7, 2, 3]))
    }

    func testFirstCancellationMalformedNameAndBudgetNeverAllocateOrPublish() throws {
        let fixture = try RegistryAnonymousFixture()
        defer { try? fixture.clean() }
        XCTAssertThrowsError(try fixture.native.append("registry.jloc", data: fixture.payload,
                                                      checkCancellation: { throw CancellationError() }))
        for name in ["../registry.jloc", "other.jloc", "registration-00000000-0000-0000-0000-abcdefabcdef.jloc"] {
            XCTAssertThrowsError(try fixture.native.append(name, data: fixture.payload, checkCancellation: {}))
        }
        XCTAssertThrowsError(try fixture.native.append(
            "registry.jloc", data: Data(repeating: 1, count: 16_385), checkCancellation: {}
        ))
        XCTAssertTrue(try fixture.leaves().isEmpty)
        try fixture.native.close()
        XCTAssertThrowsError(try fixture.native.append("registry.jloc", data: fixture.payload, checkCancellation: {}))
    }

    func testProductionCRejectsMalformedNamesAndBorrowedForeignSources() throws {
        let fixture = try RegistryAnonymousFixture()
        defer { try? fixture.clean() }
        let directory = open(fixture.namespace.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(directory, 0)
        defer { XCTAssertEqual(Glibc.close(directory), 0) }
        let created = jsti_recording_anonymous_create(directory)
        XCTAssertEqual(created.primary_errno, 0)
        XCTAssertEqual(created.unsupported, 0)
        XCTAssertGreaterThanOrEqual(created.owned_fd, 0)
        defer { XCTAssertEqual(Glibc.close(created.owned_fd), 0) }
        XCTAssertEqual(write(created.owned_fd, [UInt8](fixture.payload), fixture.payload.count), fixture.payload.count)
        XCTAssertEqual(fchmod(created.owned_fd, 0o400), 0)
        for name in ["other.jloc", "../registry.jloc", "ownership-00000000-0000-0000-0000-00000000000g.jloc"] {
            let result = jsti_recording_anonymous_publish(created.owned_fd, directory, name)
            XCTAssertEqual(result.primary_errno, EINVAL)
            XCTAssertEqual(result.unsupported, 0)
            XCTAssertEqual(result.did_publish, 0)
            XCTAssertEqual(result.cleanup_errno, 0)
        }
        XCTAssertTrue(try fixture.leaves().isEmpty)
        let foreign = fixture.storage.first.appendingPathComponent("foreign")
        try fixture.payload.write(to: foreign)
        XCTAssertEqual(chmod(foreign.path, 0o400), 0)
        let named = open(foreign.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(named, 0)
        defer { XCTAssertEqual(Glibc.close(named), 0) }
        let result = jsti_recording_anonymous_publish(named, directory, "registry.jloc")
        XCTAssertEqual(result.primary_errno, EACCES)
        XCTAssertEqual(result.unsupported, 0)
        XCTAssertEqual(result.did_publish, 0)
        XCTAssertEqual(try Data(contentsOf: foreign), fixture.payload)
    }

    func testActualProcfsDoesNotSupportAnonymousAllocation() throws {
        XCTAssertNotEqual(geteuid(), 0)
        let directory = open("/proc/\(getpid())/fd", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(directory, 0)
        defer { XCTAssertEqual(Glibc.close(directory), 0) }
        let result = jsti_recording_anonymous_create(directory)
        XCTAssertEqual(result.owned_fd, -1)
        XCTAssertEqual(result.unsupported, 1)
        XCTAssertEqual(result.primary_errno, EOPNOTSUPP)
        XCTAssertEqual(result.cleanup_errno, 0)
    }

    func testInstrumentedProductionSyscallBoundaries() throws {
        guard let mode = ProcessInfo.processInfo.environment["JSTI_REGISTRY_INSTRUMENT_MODE"] else {
            throw XCTSkip("Test-only LD_PRELOAD syscall boundaries run in separate explicitly instrumented processes.")
        }
        let fixture = try RegistryAnonymousFixture()
        defer { try? fixture.clean() }
        XCTAssertEqual(setenv("JSTI_REGISTRY_NAMESPACE", fixture.namespace.path, 1), 0)
        XCTAssertEqual(setenv("JSTI_REGISTRY_TRACE", fixture.storage.root.appendingPathComponent("trace").path, 1), 0)
        let shouldPublish = !["missing-proc", "wrong-proc", "linked-proc", "source-view", "write-pre",
                              "sync-pre", "helper-pre-close", "cancel-pre-close", "unexpected-open",
                              "create-permission-close"].contains(mode)
        var file: Int32 = -1
        do {
            try fixture.native.append("registry.jloc", data: fixture.payload, checkCancellation: {
                let check = fixture.nextCheck()
                if check == 2 { file = try RegistryAnonymousFixture.descriptor(in: fixture.namespace) }
                if (check == 2 && mode == "cancel-pre-close") || (check == 3 && mode == "cancel-post-close") {
                    throw CancellationError()
                }
            })
            XCTAssertTrue(["decoy", "cleanup-decoy"].contains(mode), "Other instrumented cases must fail explicitly.")
        } catch {
            try fixture.checkInstrumentedFailure(error, mode: mode, published: shouldPublish)
        }
        let root = mode == "namespace-link" ? fixture.namespace.path + ".retained" : fixture.namespace.path
        XCTAssertEqual(FileManager.default.fileExists(atPath: root + "/registry.jloc"), shouldPublish)
        if ["decoy", "cleanup-decoy", "source-view"].contains(mode) {
            XCTAssertEqual(try fixture.bytes(".pending-decoy"), Data([92]))
        }
        if mode == "replacement-link" {
            XCTAssertEqual(try fixture.bytes("registry.jloc"), Data([92]))
            XCTAssertEqual(try fixture.bytes("retained.jloc"), fixture.payload)
        }
        if mode == "namespace-link" { XCTAssertEqual(try fixture.bytes("unrelated"), Data([92])) }
        if file >= 0 {
            XCTAssertEqual(fcntl(file, F_GETFD), -1)
            XCTAssertEqual(errno, EBADF)
        }
        let trace = try String(contentsOf: fixture.storage.root.appendingPathComponent("trace"), encoding: .utf8)
        XCTAssertEqual(trace.components(separatedBy: "owned-close").count - 1, 1, trace)
        XCTAssertEqual(trace.components(separatedBy: "link-attempt").count - 1, shouldPublish ? 1 : 0, trace)
        let summary = trace.replacingOccurrences(of: "\n", with: " ")
        print("JSTI_PRODUCTION_INSTRUMENT_VERIFIED \(mode) published=\(shouldPublish) " + summary)
    }
}

func jstiRegistryTestLink(file: Int32, to url: URL) -> Int32 {
    linkat(AT_FDCWD, "/proc/\(getpid())/fd/\(file)", AT_FDCWD, url.path, AT_SYMLINK_FOLLOW)
}

final class RegistryAnonymousFixture {
    let storage: RecordingLocationFixture
    let native: DesktopPOSIXRecordingRegistry
    let payload = Data([1, 2, 3])
    var checks = 0
    var namespace: URL { storage.history.appendingPathComponent(".recording-locations") }

    init() throws {
        let storage = try RecordingLocationFixture()
        self.storage = storage
        self.native = try DesktopPOSIXRecordingRegistry(history: storage.history, initialize: true)
    }

    func nextCheck() -> Int { checks += 1; return checks }
    func clean() throws { try native.close(); try storage.clean() }
    func leaves() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: namespace.path).sorted() }
    func bytes(_ name: String) throws -> Data { try Data(contentsOf: namespace.appendingPathComponent(name)) }

    static func descriptor(in namespace: URL, links: nlink_t = 0) throws -> Int32 {
        for name in try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd") {
            guard let file = Int32(name), file >= 0 else { continue }
            var info = stat()
            guard fstat(file, &info) == 0, info.st_nlink == links, info.st_mode & S_IFMT == S_IFREG,
                  fcntl(file, F_GETFL) & O_ACCMODE == O_RDWR else { continue }
            let path = try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/" + name)
            if path.hasPrefix(namespace.path + "/") { return file }
        }
        throw DesktopRecordingRegistryError.missing
    }

    func mutate(_ kind: String, file: Int32) throws {
        switch kind {
        case "replacement":
            try FileManager.default.moveItem(
                at: namespace.appendingPathComponent("registry.jloc"),
                to: namespace.appendingPathComponent("retained.jloc")
            )
            try Data([92]).write(to: namespace.appendingPathComponent("registry.jloc"))
        case "bytes":
            var byte: UInt8 = 7
            XCTAssertEqual(pwrite(file, &byte, 1, 0), 1)
        case "permissions": XCTAssertEqual(fchmod(file, 0o600), 0)
        case "hardlink":
            XCTAssertEqual(jstiRegistryTestLink(file: file, to: storage.first.appendingPathComponent("alias")), 0)
        case "namespace":
            try FileManager.default.moveItem(at: namespace, to: storage.history.appendingPathComponent("retained"))
            try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            try Data([92]).write(to: namespace.appendingPathComponent("unrelated"))
        case "history":
            try FileManager.default.moveItem(at: storage.history, to: storage.root.appendingPathComponent("retained"))
            try FileManager.default.createDirectory(at: storage.history, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            try Data([92]).write(to: storage.history.appendingPathComponent("unrelated"))
        case "cancel": throw CancellationError()
        default: XCTFail("Unexpected test mutation.")
        }
    }

    func checkRetained(_ kind: String) throws {
        switch kind {
        case "replacement":
            XCTAssertEqual(try bytes("registry.jloc"), Data([92]))
            XCTAssertEqual(try bytes("retained.jloc"), payload)
        case "namespace":
            XCTAssertEqual(try bytes("unrelated"), Data([92]))
            let retained = storage.history.appendingPathComponent("retained/registry.jloc")
            XCTAssertEqual(try Data(contentsOf: retained), payload)
        case "history":
            XCTAssertEqual(try Data(contentsOf: storage.history.appendingPathComponent("unrelated")), Data([92]))
            let retained = storage.root.appendingPathComponent("retained/.recording-locations/registry.jloc")
            XCTAssertEqual(try Data(contentsOf: retained), payload)
        case "bytes": XCTAssertEqual(try bytes("registry.jloc"), Data([7, 2, 3]))
        default: XCTAssertEqual(try bytes("registry.jloc"), payload)
        }
        if kind == "hardlink" {
            XCTAssertEqual(try Data(contentsOf: storage.first.appendingPathComponent("alias")), payload)
        }
    }

    func checkInstrumentedFailure(_ error: Error, mode: String, published: Bool) throws {
        guard let failure = error as? DesktopRecordingRegistryWriteFailure else {
            return XCTFail("Expected an explicit owned publication result.")
        }
        switch failure.effect {
        case .published: XCTAssertTrue(published)
        case .unpublished: XCTAssertFalse(published)
        }
        checkUnavailable(failure, mode: mode)
        if mode == "unexpected-open" {
            XCTAssertEqual((failure.primaryError as NSError).code, Int(EIO))
            XCTAssertNil(failure.cleanupError)
        }
        if mode.hasPrefix("cancel") {
            XCTAssertTrue(failure.primaryError is CancellationError)
            XCTAssertEqual((try XCTUnwrap(failure.cleanupError) as NSError).code, Int(EIO))
        }
        if ["write-pre", "create-permission-close"].contains(mode) {
            XCTAssertEqual((failure.primaryError as NSError).code, Int(mode == "write-pre" ? EIO : EACCES))
            XCTAssertEqual((try XCTUnwrap(failure.cleanupError) as NSError).code, Int(EIO))
        }
        if mode == "helper-and-writer-close" {
            guard let combined = failure.primaryError as? DesktopRecordingLocationCleanupFailure else {
                return XCTFail("Both helper and writer teardown failures must remain inspectable.")
            }
            XCTAssertEqual((combined.primaryError as NSError).code, Int(EIO))
            XCTAssertEqual((combined.cleanupError as NSError).code, Int(EIO))
        }
    }

    private func checkUnavailable(_ failure: DesktopRecordingRegistryWriteFailure, mode: String) {
        if ["missing-proc", "wrong-proc", "linked-proc"].contains(mode) {
            guard case let DesktopRecordingRegistryCapabilityError.unavailable(native) = failure.primaryError else {
                return XCTFail("Unavailable procfs must preserve unsupported status and native errno.")
            }
            let code = mode == "wrong-proc" ? ENODEV : mode == "linked-proc" ? ENOTDIR : ENOENT
            XCTAssertEqual(native.code, Int(code))
        }
    }
}
#endif
