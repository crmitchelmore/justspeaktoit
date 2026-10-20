import Foundation
#if os(Linux) && canImport(Glibc)
import Glibc

/// The exclusive 0700 leaf is the mutation boundary. Ancestor descriptors are
/// retained, not reconstructed from read receipts. Other users cannot mutate
/// the leaf; callers must not share its write authority with another operation.
final class DesktopPOSIXCaptureWriter: DesktopOwnedCaptureWriter, @unchecked Sendable {
    let url: URL
    private let handle: FileHandle
    private let anchors: [Anchor]
    private let filename: String
    private var closed = false

    private struct Anchor {
        let descriptor: Int32
        let name: String
    }

    init(root: URL, directoryID: UUID, recordingID: UUID) throws {
        guard root.isFileURL, root.host?.isEmpty != false, root.query == nil, root.fragment == nil,
              root.path.hasPrefix("/"), !root.path.utf8.contains(0),
              root.pathComponents.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw DesktopOwnedCaptureError.unsafeDirectory
        }
        let filename = recordingID.uuidString + ".wav"
        let folder = root.appendingPathComponent(directoryID.uuidString, isDirectory: true)
        self.url = folder.appendingPathComponent(filename)
        self.filename = filename
        var anchors: [Anchor] = []
        var file: Int32 = -1
        do {
            let first = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard first >= 0 else { throw Self.posixError() }
            anchors.append(Anchor(descriptor: first, name: "/"))
            try Self.requireSecureDirectory(first)
            for name in root.pathComponents.dropFirst() {
                let next = openat(anchors[anchors.count - 1].descriptor, name,
                                  O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Self.posixError() }
                anchors.append(Anchor(descriptor: next, name: name))
                try Self.requireSecureDirectory(next)
            }
            let parent = anchors[anchors.count - 1].descriptor
            guard mkdirat(parent, directoryID.uuidString, 0o700) == 0 else { throw Self.posixError() }
            let leaf = openat(parent, directoryID.uuidString, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard leaf >= 0 else { throw Self.posixError() }
            anchors.append(Anchor(descriptor: leaf, name: directoryID.uuidString))
            try Self.requireSecureDirectory(leaf, privateLeaf: true)
            file = openat(leaf, filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard file >= 0 else { throw Self.posixError() }
            self.handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
            self.anchors = anchors
        } catch {
            // No path-based recursive cleanup. A failed allocation may leave an
            // empty private UUID directory, but cannot remove a replacement.
            if file >= 0 { _ = Self.closeDescriptor(file) }
            for anchor in anchors.reversed() { _ = Self.closeDescriptor(anchor.descriptor) }
            throw error
        }
    }

    deinit { try? close() }

    func write(_ data: Data) throws {
        try requireOpen()
        try handle.write(contentsOf: data)
    }

    func seek(toOffset offset: UInt64) throws {
        try requireOpen()
        try handle.seek(toOffset: offset)
    }

    func synchronize() throws {
        try requireOpen()
        try handle.synchronize()
    }

    func validateLocation() throws {
        try requireOpen()
        for (index, anchor) in anchors.enumerated() {
            try Self.requireSecureDirectory(anchor.descriptor, privateLeaf: index == anchors.count - 1)
            if index > 0 {
                try requireSameFile(
                    parent: anchors[index - 1].descriptor, name: anchor.name, descriptor: anchor.descriptor
                )
            }
        }
        try requireSameFile(
            parent: anchors[anchors.count - 1].descriptor, name: filename, descriptor: handle.fileDescriptor
        )
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { throw Self.posixError() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0 else { throw DesktopOwnedCaptureError.changedLocation }
    }

    func removeUnpublished() throws {
        try requireOpen()
        let leaf = anchors[anchors.count - 1].descriptor
        try Self.requireSecureDirectory(leaf, privateLeaf: true)
        // The held, exclusively owned directory is the authority. This check
        // additionally refuses a violated single-owner contract; it is not CAS.
        try requireSameFile(parent: leaf, name: filename, descriptor: handle.fileDescriptor)
        guard unlinkat(leaf, filename, 0) == 0 else { throw Self.posixError() }
        // Never rmdir by a formerly owned name in the selected root.
    }

    func close() throws {
        guard !closed else { return }
        closed = true
        var failure: Error?
        do { try handle.close() } catch { failure = error }
        for anchor in anchors.reversed() {
            if Self.closeDescriptor(anchor.descriptor) != 0, failure == nil { failure = Self.posixError() }
        }
        if let failure { throw failure }
    }

    private func requireOpen() throws {
        guard !closed else { throw DesktopOwnedCaptureError.closed }
    }

    private func requireSameFile(parent: Int32, name: String, descriptor: Int32) throws {
        var held = stat()
        var named = stat()
        guard fstat(descriptor, &held) == 0 else { throw Self.posixError() }
        guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              held.st_dev == named.st_dev, held.st_ino == named.st_ino,
              held.st_mode & S_IFMT == named.st_mode & S_IFMT else {
            throw DesktopOwnedCaptureError.changedLocation
        }
    }

    private static func requireSecureDirectory(_ descriptor: Int32, privateLeaf: Bool = false) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid() || (!privateLeaf && info.st_uid == 0),
              info.st_mode & (privateLeaf ? 0o077 : 0o022) == 0 else {
            throw DesktopOwnedCaptureError.unsafeDirectory
        }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private static func closeDescriptor(_ descriptor: Int32) -> Int32 {
        Glibc.close(descriptor)
    }
}
#endif
