import Foundation
#if os(Linux) && canImport(Glibc)
import Glibc

/// Opens and checks the descriptors behind the recording registry: the
/// no-follow chain from `/` to History, the private namespace leaf and its
/// lock, and the identity and ownership checks every read and append repeats.
enum DesktopPOSIXRecordingDescriptors {
    static func same(parent: Int32, name: String, descriptor: Int32) throws {
        var held = stat()
        var named = stat()
        guard fstat(descriptor, &held) == 0 else { throw posixError() }
        guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              held.st_dev == named.st_dev, held.st_ino == named.st_ino,
              held.st_mode & S_IFMT == named.st_mode & S_IFMT else {
            throw DesktopRecordingLocationError.changedLocation
        }
    }
    static func sameDescriptor(_ first: Int32, _ second: Int32) throws {
        var left = stat()
        var right = stat()
        guard fstat(first, &left) == 0, fstat(second, &right) == 0 else { throw posixError() }
        guard left.st_dev == right.st_dev, left.st_ino == right.st_ino else {
            throw DesktopRecordingLocationError.changedLocation
        }
    }
    static func secureDirectory(_ descriptor: Int32, privateLeaf: Bool) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() || (!privateLeaf && info.st_uid == 0),
              info.st_mode & (privateLeaf ? 0o077 : 0o022) == 0 else {
            throw DesktopRecordingRegistryError.foreign
        }
    }

    static func regularPrivateFile(_ descriptor: Int32) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & 0o777 == 0o400, info.st_size >= 0,
              info.st_size <= DesktopRecordingLocationCodec.maximumBytes else {
            throw DesktopRecordingRegistryError.corrupt
        }
        return info
    }

    static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

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
