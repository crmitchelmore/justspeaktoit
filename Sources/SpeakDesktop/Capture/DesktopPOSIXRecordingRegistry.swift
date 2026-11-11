import Foundation
#if os(Linux) && canImport(Glibc)
import CRecordingFileSupport
import Glibc

enum DesktopRecordingRegistryCapabilityError: LocalizedError {
    case unavailable(NSError), invalidOutcome

    var errorDescription: String? {
        switch self {
        case .unavailable: return "The native anonymous recording registration capability is unavailable."
        case .invalidOutcome: return "The native recording registration capability returned an invalid outcome."
        }
    }
}

/// A held private namespace and process lock grant append authority. Identity rereads are fences, not CAS.
final class DesktopPOSIXRecordingRegistry: DesktopRecordingRegistryNamespace, @unchecked Sendable {
    let historyDevice: UInt64
    let historyFile: UInt64
    let namespaceDevice: UInt64
    let namespaceFile: UInt64
    private var anchors: [(descriptor: Int32, name: String)]
    private var closed = false
    private var directory: Int32 { anchors[anchors.count - 1].descriptor }

    init(history: URL, initialize: Bool) throws {
        try Self.validHistory(history)
        var held: [(descriptor: Int32, name: String)] = []
        do {
            let historyInfo = try Self.openHistory(history, anchors: &held)
            let parent = held[held.count - 1].descriptor
            let leaf = try Self.openNamespace(parent: parent, initialize: initialize)
            held.append((leaf, ".recording-locations"))
            let info = try Self.lockNamespace(leaf)
            if initialize, fsync(parent) != 0 { throw Self.posixError() }
            self.historyDevice = UInt64(historyInfo.st_dev)
            self.historyFile = UInt64(historyInfo.st_ino)
            self.namespaceDevice = UInt64(info.st_dev)
            self.namespaceFile = UInt64(info.st_ino)
            self.anchors = held
        } catch {
            let primary = error
            var cleanup: Error?
            for anchor in held.reversed() {
                if Glibc.close(anchor.descriptor) != 0, cleanup == nil { cleanup = Self.posixError() }
            }
            if let cleanup {
                throw DesktopRecordingLocationCleanupFailure(primaryError: primary, cleanupError: cleanup)
            }
            throw primary
        }
    }

    deinit { try? close() }

    func validate() throws {
        guard !closed else { throw DesktopRecordingRegistryError.closed }
        for (index, anchor) in anchors.enumerated() {
            try Self.secureDirectory(anchor.descriptor, privateLeaf: index == anchors.count - 1)
            if index > 0 {
                try Self.same(parent: anchors[index - 1].descriptor, name: anchor.name, descriptor: anchor.descriptor)
            }
        }
    }

    func close() throws {
        guard !closed else { return }
        closed = true
        var failure: Error?
        for anchor in anchors.reversed() {
            if Glibc.close(anchor.descriptor) != 0, failure == nil { failure = Self.posixError() }
        }
        anchors.removeAll()
        if let failure { throw failure }
    }
}

extension DesktopPOSIXRecordingRegistry {
    func names() throws -> [String] {
        try validate()
        let duplicate = fcntl(directory, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else { throw Self.posixError() }
        guard let stream = fdopendir(duplicate) else {
            let primary = Self.posixError()
            if Glibc.close(duplicate) != 0 {
                throw DesktopRecordingLocationCleanupFailure(primaryError: primary, cleanupError: Self.posixError())
            }
            throw primary
        }
        var result: [String] = []
        var failure: Error?
        do {
            result = try Self.enumerate(stream)
            try validate()
        } catch { failure = error }
        if closedir(stream) != 0 {
            let cleanup = Self.posixError()
            if let failure {
                throw DesktopRecordingLocationCleanupFailure(primaryError: failure, cleanupError: cleanup)
            }
            throw cleanup
        }
        if let failure { throw failure }
        return result
    }

    func read(_ name: String) throws -> Data {
        guard Self.validName(name) else { throw DesktopRecordingRegistryError.unexpectedLeaf }
        try validate()
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else {
            if errno == ENOENT { throw DesktopRecordingRegistryError.missing }
            throw Self.posixError()
        }
        var result = Data()
        var failure: Error?
        do {
            result = try Self.readBytes(file)
            try Self.same(parent: directory, name: name, descriptor: file)
            try validate()
        } catch { failure = error }
        if Glibc.close(file) != 0 {
            let cleanup = Self.posixError()
            if let failure {
                throw DesktopRecordingLocationCleanupFailure(primaryError: failure, cleanupError: cleanup)
            }
            throw cleanup
        }
        if let failure { throw failure }
        return result
    }

    private static func enumerate(_ stream: OpaquePointer) throws -> [String] {
        // dup shares the directory cursor with the held descriptor.
        rewinddir(stream)
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw posixError() }
                return result
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard validName(name) else { throw DesktopRecordingRegistryError.unexpectedLeaf }
            result.append(name)
            guard result.count <= DesktopLocalRecordingPersistence.maximumRecords else {
                throw DesktopRecordingRegistryError.budget
            }
            try Task.checkCancellation()
        }
    }

    private static func readBytes(_ file: Int32, checkingCancellation: Bool = true) throws -> Data {
        let before = try regularPrivateFile(file)
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            if checkingCancellation { try Task.checkCancellation() }
            let count = buffer.withUnsafeMutableBytes {
                pread(file, $0.baseAddress, $0.count, off_t(result.count))
            }
            guard count >= 0 else { throw posixError() }
            if count == 0 { break }
            guard result.count + count <= DesktopRecordingLocationCodec.maximumBytes else {
                throw DesktopRecordingRegistryError.budget
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        let after = try regularPrivateFile(file)
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtim.tv_sec == after.st_mtim.tv_sec,
              before.st_mtim.tv_nsec == after.st_mtim.tv_nsec, before.st_ctim.tv_sec == after.st_ctim.tv_sec,
              before.st_ctim.tv_nsec == after.st_ctim.tv_nsec, result.count == Int(after.st_size) else {
            throw DesktopRecordingRegistryError.corrupt
        }
        return result
    }
}

extension DesktopPOSIXRecordingRegistry {
    func append(_ name: String, data: Data, checkCancellation: () throws -> Void) throws {
        guard Self.validName(name) else { throw DesktopRecordingRegistryError.unexpectedLeaf }
        guard !data.isEmpty, data.count <= DesktopRecordingLocationCodec.maximumBytes else {
            throw DesktopRecordingRegistryError.budget
        }
        try validate()
        try checkCancellation()
        let allocation = jsti_recording_anonymous_create(directory)
        if let failure = Self.nativeFailure(allocation.primary_errno, unsupported: allocation.unsupported) {
            throw DesktopRecordingRegistryWriteFailure(
                primaryError: failure, cleanupError: Self.nativeFailure(allocation.cleanup_errno),
                effect: .unpublished
            )
        }
        guard allocation.owned_fd >= 0, allocation.cleanup_errno == 0 else {
            throw DesktopRecordingRegistryCapabilityError.invalidOutcome
        }
        let file = allocation.owned_fd
        var outcome: (published: Bool, cleanup: Error?) = (false, nil)
        var failure: Error?
        do {
            try commit(
                file: file, name: name, data: data, outcome: &outcome,
                checkCancellation: checkCancellation
            )
        } catch { failure = error }
        if Glibc.close(file) != 0 {
            Self.collect(Self.posixError(), into: &outcome.cleanup)
        }
        if let failure {
            throw DesktopRecordingRegistryWriteFailure(
                primaryError: failure, cleanupError: outcome.cleanup,
                effect: outcome.published ? .published : .unpublished
            )
        }
        if let cleanup = outcome.cleanup {
            throw DesktopRecordingRegistryWriteFailure(
                primaryError: cleanup, cleanupError: nil, effect: outcome.published ? .published : .unpublished
            )
        }
    }

    private func commit(
        file: Int32, name: String, data: Data, outcome: inout (published: Bool, cleanup: Error?),
        checkCancellation: () throws -> Void
    ) throws {
        try Self.writeBytes(data, file: file)
        guard fchmod(file, 0o400) == 0, fsync(file) == 0 else {
            throw Self.posixError()
        }
        try checkCancellation()
        try validate()
        let result = jsti_recording_anonymous_publish(file, directory, name)
        outcome.published = result.did_publish != 0
        outcome.cleanup = Self.nativeFailure(result.cleanup_errno)
        var failure = Self.nativeFailure(result.primary_errno, unsupported: result.unsupported)
        if !outcome.published {
            if let failure { throw failure }
            if let error = outcome.cleanup { outcome.cleanup = nil; throw error }
            throw DesktopRecordingRegistryCapabilityError.invalidOutcome
        }
        if fsync(directory) != 0 { Self.collect(Self.posixError(), into: &failure) }
        do { try checkCancellation() } catch { Self.collect(error, into: &failure) }
        // Fences still run after cancellation; a committed name is never retried or rolled back.
        do { try verifyPublication(file: file, name: name, data: data) } catch {
            Self.collect(error, into: &failure)
        }
        if let failure { throw failure }
    }
    private func verifyPublication(file: Int32, name: String, data: Data) throws {
        try validate()
        _ = try Self.regularPrivateFile(file)
        try Self.same(parent: directory, name: name, descriptor: file)
        let reader = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard reader >= 0 else { throw Self.posixError() }
        var failure: Error?
        do {
            try Self.sameDescriptor(file, reader)
            guard try Self.readBytes(reader, checkingCancellation: false) == data else {
                throw DesktopRecordingRegistryError.corrupt
            }
            _ = try Self.regularPrivateFile(file)
            try Self.sameDescriptor(file, reader)
            try Self.same(parent: directory, name: name, descriptor: file)
            try validate()
        } catch { failure = error }
        if Glibc.close(reader) != 0 { Self.collect(Self.posixError(), into: &failure) }
        if let failure { throw failure }
    }
    private static func nativeFailure(_ code: Int32, unsupported: Int32 = 0) -> Error? {
        guard code != 0 else { return unsupported == 0 ? nil : DesktopRecordingRegistryCapabilityError.invalidOutcome }
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        return unsupported == 0 ? error : DesktopRecordingRegistryCapabilityError.unavailable(error)
    }
    private static func collect(_ error: Error, into failure: inout Error?) {
        if let primary = failure {
            failure = DesktopRecordingLocationCleanupFailure(primaryError: primary, cleanupError: error)
        } else {
            failure = error
        }
    }
    private static func writeBytes(_ data: Data, file: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Glibc.write(file, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw posixError() }
                offset += count
            }
        }
    }
}

private extension DesktopPOSIXRecordingRegistry {
    private static func validName(_ name: String) -> Bool {
        if name == "registry.jloc" { return true }
        for prefix in ["registration-", "ownership-"] where name.hasPrefix(prefix) && name.hasSuffix(".jloc") {
            let value = String(name.dropFirst(prefix.count).dropLast(5))
            if let id = UUID(uuidString: value), id.uuidString == value { return true }
        }
        return false
    }

    private static func same(parent: Int32, name: String, descriptor: Int32) throws {
        var held = stat()
        var named = stat()
        guard fstat(descriptor, &held) == 0 else { throw posixError() }
        guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              held.st_dev == named.st_dev, held.st_ino == named.st_ino,
              held.st_mode & S_IFMT == named.st_mode & S_IFMT else {
            throw DesktopRecordingLocationError.changedLocation
        }
    }
    private static func sameDescriptor(_ first: Int32, _ second: Int32) throws {
        var left = stat()
        var right = stat()
        guard fstat(first, &left) == 0, fstat(second, &right) == 0 else { throw posixError() }
        guard left.st_dev == right.st_dev, left.st_ino == right.st_ino else {
            throw DesktopRecordingLocationError.changedLocation
        }
    }
    private static func secureDirectory(_ descriptor: Int32, privateLeaf: Bool) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() || (!privateLeaf && info.st_uid == 0),
              info.st_mode & (privateLeaf ? 0o077 : 0o022) == 0 else {
            throw DesktopRecordingRegistryError.foreign
        }
    }

    private static func regularPrivateFile(_ descriptor: Int32) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & 0o777 == 0o400, info.st_size >= 0,
              info.st_size <= DesktopRecordingLocationCodec.maximumBytes else {
            throw DesktopRecordingRegistryError.corrupt
        }
        return info
    }

    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    static func validHistory(_ history: URL) throws {
        guard history.isFileURL, history.host?.isEmpty != false, history.query == nil, history.fragment == nil,
              history.path.hasPrefix("/"), !history.path.utf8.contains(0),
              history.path == history.standardizedFileURL.path else {
            throw DesktopRecordingRegistryError.foreign
        }
    }

    static func openHistory(_ history: URL, anchors: inout [(descriptor: Int32, name: String)]) throws -> stat {
        let root = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw posixError() }
        anchors.append((root, "/"))
        try secureDirectory(root, privateLeaf: false)
        for name in history.pathComponents.dropFirst() {
            let next = openat(anchors[anchors.count - 1].descriptor, name,
                              O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw posixError() }
            anchors.append((next, name))
            try secureDirectory(next, privateLeaf: false)
        }
        var info = stat()
        guard fstat(anchors[anchors.count - 1].descriptor, &info) == 0 else { throw posixError() }
        guard info.st_uid == geteuid() else { throw DesktopRecordingRegistryError.foreign }
        let expected = try DesktopRecordingLocationIdentity.directory(history)
        guard expected.device == UInt64(info.st_dev), expected.file == UInt64(info.st_ino) else {
            throw DesktopRecordingRegistryError.identityUnavailable
        }
        return info
    }

    static func openNamespace(parent: Int32, initialize: Bool) throws -> Int32 {
        if initialize, mkdirat(parent, ".recording-locations", 0o700) != 0 { throw posixError() }
        let leaf = openat(parent, ".recording-locations", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard leaf >= 0 else {
            if errno == ENOENT { throw DesktopRecordingRegistryError.missing }
            throw posixError()
        }
        return leaf
    }

    static func lockNamespace(_ leaf: Int32) throws -> stat {
        try secureDirectory(leaf, privateLeaf: true)
        guard flock(leaf, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw DesktopRecordingRegistryError.busy }
            throw posixError()
        }
        var info = stat()
        guard fstat(leaf, &info) == 0 else { throw posixError() }
        return info
    }
}
#endif
