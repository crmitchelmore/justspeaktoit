import Foundation
import SpeakCore
import XCTest
@testable import SpeakDesktop
#if os(Linux)
import Glibc
#endif

final class DesktopRecordingRegistryTests: XCTestCase {
    func testCodecRejectsTruncationTrailingBytesCorruptionAndForeignNames() throws {
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        let identity = try DesktopRecordingLocationIdentity.directory(fixture.history)
        let binding = DesktopRecordingLocationCodec.Binding(
            id: UUID(), history: fixture.history, historyIdentity: identity, namespaceIdentity: identity
        )
        let envelope = DesktopRecordingLocationCodec.Envelope(binding: binding, payload: .header)
        let bytes = try DesktopRecordingLocationCodec.encode(envelope)
        XCTAssertEqual(try DesktopRecordingLocationCodec.decode(bytes).binding, binding)
        XCTAssertEqual(try DesktopRecordingLocationCodec.decode(bytes).filename, "registry.jloc")
        for length in 0 ..< bytes.count {
            XCTAssertThrowsError(try DesktopRecordingLocationCodec.decode(Data(bytes.prefix(length))))
        }
        var corrupt = bytes
        corrupt[bytes.count / 2] ^= 1
        XCTAssertThrowsError(try DesktopRecordingLocationCodec.decode(corrupt))
        XCTAssertThrowsError(try DesktopRecordingLocationCodec.decode(bytes + Data([0])))
        XCTAssertThrowsError(try DesktopRecordingLocationCodec.decode(
            Data(repeating: 0, count: DesktopRecordingLocationCodec.maximumBytes + 1)
        ))
    }

    func testNativeInitializeReopenAndNoOverwriteOrMissingFallback() throws {
        #if !os(Linux)
        throw XCTSkip("Native registry identity and append are qualified on Linux only.")
        #else
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        XCTAssertThrowsError(try DesktopLocalRecordingPersistence.open(historyDirectory: fixture.history))
        let persistence = try DesktopLocalRecordingPersistence.initialize(historyDirectory: fixture.history)
        var locations = try DesktopRecordingLocations(historyDirectory: fixture.history, persistence: persistence)
        let first = try locations.authorizeLocallySelectedRoot(fixture.first)
        let second = try locations.authorizeLocallySelectedRoot(fixture.second)
        XCTAssertNotEqual(first, second)
        XCTAssertThrowsError(try locations.authorizeLocallySelectedRoot(fixture.first, id: first))
        XCTAssertThrowsError(try DesktopLocalRecordingPersistence.open(historyDirectory: fixture.history))
        try persistence.close()
        try persistence.close()
        XCTAssertThrowsError(try persistence.loadVerified())
        XCTAssertThrowsError(try DesktopLocalRecordingPersistence.initialize(historyDirectory: fixture.history))
        let reopened = try DesktopLocalRecordingPersistence.open(historyDirectory: fixture.history)
        defer { try? reopened.close() }
        XCTAssertEqual(Set(try reopened.loadVerified().registrations.map(\.id)), Set([first, second]))
        _ = try DesktopRecordingLocations(historyDirectory: fixture.history, persistence: reopened)
        let names = try FileManager.default.contentsOfDirectory(
            atPath: fixture.history.appendingPathComponent(".recording-locations").path
        )
        XCTAssertEqual(names.count, 3)
        XCTAssertTrue(names.allSatisfy { $0.hasSuffix(".jloc") })
        #endif
    }

    func testNativeCancellationEffectsRetainOnlyPublishedLeaf() throws {
        #if !os(Linux)
        throw XCTSkip("Requires qualified Linux immutable append.")
        #else
        for cancellationCheck in [2, 3] {
            let fixture = try RecordingLocationFixture()
            defer { try? fixture.clean() }
            let native = try DesktopPOSIXRecordingRegistry(history: fixture.history, initialize: true)
            defer { try? native.close() }
            let bytes = try header(native, history: fixture.history)
            let unrelated = fixture.first.appendingPathComponent("unrelated.wav")
            try Data([92]).write(to: unrelated)
            var checks = 0
            XCTAssertThrowsError(try native.append("registry.jloc", data: bytes, checkCancellation: {
                checks += 1
                if checks == cancellationCheck { throw CancellationError() }
            })) { error in
                guard let failure = error as? DesktopRecordingRegistryWriteFailure else {
                    return XCTFail("Expected an explicit publication effect.")
                }
                XCTAssertTrue(failure.primaryError is CancellationError)
                XCTAssertNil(failure.cleanupError)
                switch failure.effect {
                case .published: XCTAssertEqual(cancellationCheck, 3)
                case .unpublished: XCTAssertEqual(cancellationCheck, 2)
                }
            }
            XCTAssertEqual(try native.names(), cancellationCheck == 3 ? ["registry.jloc"] : [])
            XCTAssertEqual(try Data(contentsOf: unrelated), Data([92]))
            if cancellationCheck == 3 {
                XCTAssertEqual(try native.read("registry.jloc"), bytes)
                XCTAssertThrowsError(try native.append("registry.jloc", data: bytes, checkCancellation: {}))
                XCTAssertEqual(try native.read("registry.jloc"), bytes)
            }
        }
        #endif
    }

    func testNativeRootReplacementAndLinkedCorruptForeignRecordsFailClosed() throws {
        #if !os(Linux)
        throw XCTSkip("Requires qualified Linux registry verification.")
        #else
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        let persistence = try DesktopLocalRecordingPersistence.initialize(historyDirectory: fixture.history)
        let root = fixture.history.appendingPathComponent(".recording-locations")
        let old = fixture.history.appendingPathComponent(".old-recording-locations")
        try FileManager.default.moveItem(at: root, to: old)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        XCTAssertThrowsError(try persistence.loadVerified())
        try persistence.close()
        XCTAssertThrowsError(try DesktopLocalRecordingPersistence.open(historyDirectory: fixture.history))
        try FileManager.default.removeItem(at: root)
        try FileManager.default.moveItem(at: old, to: root)
        let headerURL = root.appendingPathComponent("registry.jloc")
        let original = try Data(contentsOf: headerURL)
        try FileManager.default.removeItem(at: headerURL)
        try FileManager.default.createSymbolicLink(at: headerURL, withDestinationURL: fixture.first)
        XCTAssertThrowsError(try DesktopLocalRecordingPersistence.open(historyDirectory: fixture.history))
        try FileManager.default.removeItem(at: headerURL)
        try Data([0]).write(to: headerURL)
        XCTAssertThrowsError(try DesktopLocalRecordingPersistence.open(historyDirectory: fixture.history))
        try original.write(to: headerURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: headerURL.path)
        let reopened = try DesktopLocalRecordingPersistence.open(historyDirectory: fixture.history)
        defer { try? reopened.close() }
        let foreign = fixture.second.appendingPathComponent("foreign.jloc")
        try original.write(to: foreign)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("registration-\(UUID().uuidString).jloc"), withDestinationURL: foreign
        )
        XCTAssertThrowsError(try reopened.loadVerified())
        #endif
    }

    func testSourceReplacementBeforeCommitCleansHeldPendingNotReplacement() throws {
        #if !os(Linux)
        throw XCTSkip("Requires held native Linux namespace.")
        #else
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        let native = try DesktopPOSIXRecordingRegistry(history: fixture.history, initialize: true)
        defer { try? native.close() }
        let root = fixture.history.appendingPathComponent(".recording-locations")
        let old = fixture.history.appendingPathComponent(".original-registry")
        var checks = 0
        XCTAssertThrowsError(try native.append("registry.jloc", data: header(native, history: fixture.history),
                                              checkCancellation: {
            checks += 1
            if checks == 2 {
                try FileManager.default.moveItem(at: root, to: old)
                try FileManager.default.createDirectory(
                    at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
                )
                try Data([92]).write(to: root.appendingPathComponent("unrelated.jloc"))
            }
        })) { error in
            guard let failure = error as? DesktopRecordingRegistryWriteFailure else {
                return XCTFail("Expected fenced unpublished effect.")
            }
            guard case .unpublished = failure.effect else { return XCTFail("Must not publish after replacement.") }
            XCTAssertNil(failure.cleanupError)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: old.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("unrelated.jloc")), Data([92]))
        #endif
    }

    func testSubprocessRestartResolvesAllChoicesAndLegacyHistory() async throws {
        #if !os(Linux)
        throw XCTSkip("Executable subprocess/restart qualification is Linux only.")
        #else
        let environment = ProcessInfo.processInfo.environment
        if let phase = environment["JSTI_REGISTRY_PROBE"], let path = environment["JSTI_REGISTRY_ROOT"] {
            try await restartProbe(phase: phase, root: URL(fileURLWithPath: path, isDirectory: true))
            print("JSTI_REGISTRY_RESTART_VERIFIED_" + phase)
            return
        }
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        for phase in ["create", "verify"] {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = [
                "SpeakDesktopTests.DesktopRecordingRegistryTests/"
                    + "testSubprocessRestartResolvesAllChoicesAndLegacyHistory"
            ]
            var childEnvironment = environment
            childEnvironment["JSTI_REGISTRY_PROBE"] = phase
            childEnvironment["JSTI_REGISTRY_ROOT"] = fixture.root.path
            child.environment = childEnvironment
            let output = Pipe()
            child.standardOutput = output
            child.standardError = output
            try child.run()
            defer { if child.isRunning { child.terminate() } }
            let deadline = Date().addingTimeInterval(30)
            while child.isRunning, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            if child.isRunning {
                child.terminate()
                XCTFail("The owned restart fixture exceeded its bounded runtime.")
            }
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
            XCTAssertEqual(child.terminationStatus, 0, text)
            XCTAssertTrue(text.contains("JSTI_REGISTRY_RESTART_VERIFIED_" + phase))
        }
        #endif
    }

}

#if os(Linux)
extension DesktopRecordingRegistryTests {
    func testAnonymousPermissionAndLinkMutationsFailBeforePublication() throws {
        for variant in ["permissions", "hardlink"] {
            let fixture = try RecordingLocationFixture()
            defer { try? fixture.clean() }
            let native = try DesktopPOSIXRecordingRegistry(history: fixture.history, initialize: true)
            defer { try? native.close() }
            let root = fixture.history.appendingPathComponent(".recording-locations")
            let unrelated = fixture.first.appendingPathComponent("unrelated.jloc")
            var checks = 0
            XCTAssertThrowsError(try native.append("registry.jloc", data: Data([1, 2, 3]), checkCancellation: {
                checks += 1
                if checks == 2 {
                    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
                    let file = try RegistryAnonymousFixture.descriptor(in: root)
                    if variant == "permissions" {
                        XCTAssertEqual(fchmod(file, 0o600), 0)
                        try Data([92]).write(to: unrelated)
                    } else {
                        let result = jstiRegistryTestLink(file: file, to: unrelated)
                        XCTAssertEqual(result, 0)
                    }
                }
            })) { error in
                guard let failure = error as? DesktopRecordingRegistryWriteFailure,
                      failure.primaryError is NSError,
                      case .unpublished = failure.effect else {
                    return XCTFail("Modified anonymous files must fail before immutable publication.")
                }
                XCTAssertNil(failure.cleanupError)
            }
            XCTAssertTrue(try native.names().isEmpty)
            XCTAssertEqual(try Data(contentsOf: unrelated), variant == "permissions" ? Data([92]) : Data([1, 2, 3]))
        }
    }

    private func header(_ native: DesktopPOSIXRecordingRegistry, history: URL) throws -> Data {
        try DesktopRecordingLocationCodec.encode(.init(
            binding: .init(
                id: UUID(), history: history,
                historyIdentity: .init(device: native.historyDevice, file: native.historyFile),
                namespaceIdentity: .init(device: native.namespaceDevice, file: native.namespaceFile)
            ), payload: .header
        ))
    }

    private func restartProbe(phase: String, root: URL) async throws {
        let history = root.appendingPathComponent("History")
        let persistence: DesktopLocalRecordingPersistence
        if phase == "create" {
            persistence = try .initialize(historyDirectory: history)
        } else if phase == "verify" {
            persistence = try .open(historyDirectory: history)
        } else {
            throw DesktopRecordingRegistryError.corrupt
        }
        defer { try? persistence.close() }
        let store = try DesktopRecordingStore(
            directory: history,
            audioLocations: DesktopRecordingLocations(historyDirectory: history, persistence: persistence)
        )
        if phase == "create" {
            let legacy = DesktopRecordingStore.Record(
                id: UUID(), audioFilename: "legacy.wav", modelIdentifier: "legacy"
            )
            try Data([9, 8, 7]).write(to: history.appendingPathComponent("legacy.wav"))
            try await store.save(legacy)
            for name in ["Audio A", "Audio B", "Audio C"] {
                let directory = root.appendingPathComponent(name)
                if name == "Audio C" {
                    try FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
                    )
                }
                let location = try await store.authorizeLocallySelectedAudioRoot(directory)
                let capture = try await store.createLocallyAuthorizedCapture(at: location)
                let file = try PCMRecordingFile(ownedFile: capture.file, sampleRate: 16_000)
                try file.append(Data([1, 2, 3, 4]))
                _ = try file.finish()
                try await store.save(.init(capture: capture, modelIdentifier: name))
            }
        } else {
            let state = try persistence.loadVerified()
            XCTAssertEqual(state.registrations.count, 3)
            XCTAssertEqual(state.recordings.count, 3)
            let records = try await store.records()
            XCTAssertEqual(records.count, 4)
            for record in records {
                let bytes = try await store.readAudio(for: record, maximumBytes: 1_024)
                XCTAssertEqual(
                    bytes, record.localAudio == nil ? Data([9, 8, 7])
                        : PCMWaveWriter.wavData(pcm: Data([1, 2, 3, 4]), sampleRate: 16_000)
                )
            }
        }
    }

}
#endif
