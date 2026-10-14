import CWindowsSupport
import Foundation

struct WindowsRegistryCause: Error, Equatable {
    let kind: UInt32
    let domain: UInt32
    let code: UInt32
    let stage: UInt32
    let resourceID: UInt64
}

struct WindowsRegistryCleanupFailure: LocalizedError {
    let primaryError: Error
    let cleanupError: Error
    var errorDescription: String? { "Native registry operation and cleanup both failed." }
}

struct WindowsRegistryOutcome: Equatable {
    let published: Bool
    let causes: [WindowsRegistryCause]
    let primaryIndex: Int?
    let cleanupCount: UInt32
    let closeAttempts: UInt32
    let unconfirmedReleases: UInt32
    let poisoned: Bool

    init(_ value: JSTIRegistryOutcomeV2) throws {
        guard value.abi_version == JSTI_REGISTRY_ABI_V2,
              value.struct_size == MemoryLayout<JSTIRegistryOutcomeV2>.size,
              value.cause_count <= JSTI_REGISTRY_MAX_CAUSES_V2,
              value.effect <= JSTI_REGISTRY_EFFECT_PUBLISHED_V2,
              value.capability_poisoned <= 1,
              value.primary_index == UInt32.max || value.primary_index < value.cause_count else {
            throw WindowsRegistryCapabilityError.invalidOutcome
        }
        self.published = value.effect == JSTI_REGISTRY_EFFECT_PUBLISHED_V2
        self.causes = withUnsafeBytes(of: value.causes) { bytes in
            bytes.bindMemory(to: JSTIRegistryCauseV2.self).prefix(Int(value.cause_count)).map {
                WindowsRegistryCause(
                    kind: $0.kind, domain: $0.domain, code: $0.native_code,
                    stage: $0.stage, resourceID: $0.resource_id
                )
            }
        }
        self.primaryIndex = value.primary_index == UInt32.max ? nil : Int(value.primary_index)
        self.cleanupCount = value.cleanup_count
        self.closeAttempts = value.close_attempt_count
        self.unconfirmedReleases = value.release_unconfirmed_count
        self.poisoned = value.capability_poisoned != 0
        guard self.causes.filter({ $0.kind == JSTI_REGISTRY_CAUSE_CLEANUP_V2 }).count == self.cleanupCount,
              self.causes.allSatisfy({
                  (UInt32(JSTI_REGISTRY_CAUSE_PRIMARY_V2)...UInt32(JSTI_REGISTRY_CAUSE_CLEANUP_V2))
                      .contains($0.kind) &&
                      (UInt32(JSTI_REGISTRY_DOMAIN_WIN32_V2)...UInt32(JSTI_REGISTRY_DOMAIN_CONTRACT_V2))
                      .contains($0.domain) &&
                      (UInt32(JSTI_REGISTRY_STAGE_ADMISSION_V2)...UInt32(JSTI_REGISTRY_STAGE_DESTROY_V2))
                      .contains($0.stage)
              }),
              self.causes.isEmpty == (self.primaryIndex == nil),
              self.unconfirmedReleases <= self.cleanupCount,
              self.unconfirmedReleases == 0 || self.poisoned else {
            throw WindowsRegistryCapabilityError.invalidOutcome
        }
    }
}

struct WindowsRegistryFailure: LocalizedError {
    let outcomes: [WindowsRegistryOutcome]
    let originalCancellation: Error?

    var published: Bool { self.outcomes.contains(where: \.published) }
    var errorDescription: String? {
        self.published
            ? "Native registry publication occurred, but completion failed."
            : "Native registry capability operation failed."
    }
}

enum WindowsRegistryCapabilityError: LocalizedError {
    case unsupported, invalidLocation, invalidOutcome, closed, reentrant, unconfirmedRelease

    var errorDescription: String? { "The qualification-only native registry capability is unavailable or invalid." }
}

struct WindowsRegistryIdentity: Equatable {
    let volume: UInt64
    let bytes: [UInt8]

    init(_ value: JSTIRegistryIdentityV2) throws {
        let bytes = withUnsafeBytes(of: value.file_id) { Array($0) }
        guard bytes.count == 16, bytes.contains(where: { $0 != 0 }) else {
            throw WindowsRegistryCapabilityError.invalidOutcome
        }
        self.volume = value.volume_serial
        self.bytes = bytes
    }
}

protocol WindowsRegistryBackend: AnyObject {
    func identity() throws -> (WindowsRegistryIdentity, WindowsRegistryIdentity)
    func names() throws -> [String]
    func read(_ name: String) throws -> Data
    func append(_ name: String, data: Data, cancelled: (UInt32) -> Int32) throws -> WindowsRegistryOutcome
    func validate() throws
    func close() throws
    func destroy() throws
}

/// Synchronous qualification owner. Neither this owner nor its pointers are Sendable.
final class WindowsRecordingRegistryCapability {
    private let lock = NSRecursiveLock()
    private let backend: any WindowsRegistryBackend
    private var active = false
    private var closed = false
    private var poisoned = false
    private var terminalError: Error?

    init(backend: any WindowsRegistryBackend) { self.backend = backend }

    convenience init(history: URL, initialize: Bool) throws {
        #if os(Windows)
        try self.init(backend: WindowsRegistryNativeBackend(history: history, initialize: initialize))
        #else
        throw WindowsRegistryCapabilityError.unsupported
        #endif
    }

    deinit {
        do { try self.close() } catch {
            NSLog("Native registry qualification teardown could not be confirmed.")
        }
    }

    func identity() throws -> (WindowsRegistryIdentity, WindowsRegistryIdentity) {
        try self.perform { try self.backend.identity() }
    }

    func names() throws -> [String] { try self.perform { try self.backend.names() } }
    func read(_ name: String) throws -> Data { try self.perform { try self.backend.read(name) } }
    func validate() throws { try self.perform { try self.backend.validate() } }

    @discardableResult
    func append(
        _ name: String, data: Data, checkCancellation: () throws -> Void
    ) throws -> WindowsRegistryOutcome {
        try self.perform {
            var original: Error?
            do {
                return try self.backend.append(name, data: data) { _ in
                    do { try checkCancellation(); return 0 } catch {
                        if original == nil { original = error }
                        return 1
                    }
                }
            } catch let failure as WindowsRegistryFailure {
                throw WindowsRegistryFailure(outcomes: failure.outcomes, originalCancellation: original)
            }
        }
    }

    func close() throws {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.active else { throw WindowsRegistryCapabilityError.reentrant }
        if self.closed {
            if let terminalError = self.terminalError { throw terminalError }
            return
        }
        self.closed = true
        var closeError = self.terminalError
        do { try self.backend.close() } catch {
            if let primary = closeError {
                closeError = WindowsRegistryCleanupFailure(primaryError: primary, cleanupError: error)
            } else {
                closeError = error
            }
        }
        do { try self.backend.destroy() } catch {
            if let first = closeError as? WindowsRegistryFailure, let second = error as? WindowsRegistryFailure {
                closeError = WindowsRegistryFailure(
                    outcomes: first.outcomes + second.outcomes, originalCancellation: first.originalCancellation
                )
            } else if closeError == nil {
                closeError = error
            } else if let primary = closeError {
                closeError = WindowsRegistryCleanupFailure(primaryError: primary, cleanupError: error)
            }
        }
        self.terminalError = closeError
        if let closeError { throw closeError }
    }

    private func perform<T>(_ action: () throws -> T) throws -> T {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.active else { throw WindowsRegistryCapabilityError.reentrant }
        guard !self.closed else { throw WindowsRegistryCapabilityError.closed }
        guard !self.poisoned else { throw WindowsRegistryCapabilityError.unconfirmedRelease }
        self.active = true
        defer { self.active = false }
        do { return try action() } catch {
            if let failure = error as? WindowsRegistryFailure,
               failure.outcomes.contains(where: { $0.poisoned || $0.unconfirmedReleases != 0 }) {
                self.poisoned = true
                self.terminalError = error
            }
            throw error
        }
    }
}

private final class WindowsRegistryCancellationContext {
    let callback: (UInt32) -> Int32
    init(_ callback: @escaping (UInt32) -> Int32) { self.callback = callback }
}

private final class WindowsRegistryNativeBackend: WindowsRegistryBackend {
    private var native: OpaquePointer?

    init(history: URL, initialize: Bool) throws {
        guard history.isFileURL, history.host?.isEmpty != false, history.query == nil,
              history.fragment == nil, !history.path.utf8.contains(0) else {
            throw WindowsRegistryCapabilityError.invalidLocation
        }
        let path = Array(history.path.utf8)
        var created: OpaquePointer?
        do {
            try Self.checked { outcome in
                path.withUnsafeBufferPointer {
                    jsti_recording_registry_open_v2($0.baseAddress, $0.count, initialize ? 1 : 0, &created, outcome)
                }
            }
        } catch {
            let primary = error
            if created != nil {
                do {
                    try Self.checked { jsti_recording_registry_destroy_v2(&created, $0) }
                } catch {
                    throw WindowsRegistryCleanupFailure(primaryError: primary, cleanupError: error)
                }
            }
            throw primary
        }
        guard let created else { throw WindowsRegistryCapabilityError.invalidOutcome }
        self.native = created
    }

    func identity() throws -> (WindowsRegistryIdentity, WindowsRegistryIdentity) {
        let native = try self.requireOpen()
        var history = JSTIRegistryIdentityV2()
        var namespace = JSTIRegistryIdentityV2()
        try Self.checked { jsti_recording_registry_identity_v2(native, &history, &namespace, $0) }
        return try (WindowsRegistryIdentity(history), WindowsRegistryIdentity(namespace))
    }

    func names() throws -> [String] {
        let native = try self.requireOpen()
        var bytes = [UInt8](repeating: 0, count: Int(JSTI_REGISTRY_MAX_NAMES_BYTES_V2))
        var written = 0
        var count: UInt32 = 0
        try Self.checked { outcome in
            bytes.withUnsafeMutableBufferPointer {
                jsti_recording_registry_names_v2(native, $0.baseAddress, $0.count, &written, &count, outcome)
            }
        }
        guard written <= bytes.count, written >= 0, count <= JSTI_REGISTRY_MAX_NAMES_V2,
              written == 0 || bytes[written - 1] == 0 else { throw WindowsRegistryCapabilityError.invalidOutcome }
        let parts = bytes.prefix(written).split(separator: 0, omittingEmptySubsequences: false)
        guard written == 0 || parts.last?.isEmpty == true else { throw WindowsRegistryCapabilityError.invalidOutcome }
        let names = try (written == 0 ? [] : Array(parts.dropLast())).map { part in
            guard !part.isEmpty, part.allSatisfy({ $0 < 128 }), let name = String(bytes: part, encoding: .ascii) else {
                throw WindowsRegistryCapabilityError.invalidOutcome
            }
            return name
        }
        guard names.count == count else { throw WindowsRegistryCapabilityError.invalidOutcome }
        return names
    }

    func read(_ name: String) throws -> Data {
        let native = try self.requireOpen()
        let name = Array(name.utf8)
        var bytes = [UInt8](repeating: 0, count: Int(JSTI_REGISTRY_MAX_LEAF_BYTES_V2))
        var written = 0
        try Self.checked { outcome in
            name.withUnsafeBufferPointer { name in
                bytes.withUnsafeMutableBufferPointer {
                    jsti_recording_registry_read_v2(
                        native, name.baseAddress, name.count, $0.baseAddress, $0.count, &written, outcome
                    )
                }
            }
        }
        guard written > 0, written <= bytes.count else { throw WindowsRegistryCapabilityError.invalidOutcome }
        return Data(bytes.prefix(written))
    }

    func append(
        _ name: String, data: Data, cancelled: (UInt32) -> Int32
    ) throws -> WindowsRegistryOutcome {
        let native = try self.requireOpen()
        let name = Array(name.utf8)
        return try withoutActuallyEscaping(cancelled) { callback in
            let context = WindowsRegistryCancellationContext(callback)
            return try withExtendedLifetime(context) {
                try Self.checked { outcome in
                    name.withUnsafeBufferPointer { name in
                        data.withUnsafeBytes { bytes in
                            jsti_recording_registry_append_v2(
                                native, name.baseAddress, name.count,
                                bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                                { raw, checkpoint in
                                    guard let raw else { return 1 }
                                    return Unmanaged<WindowsRegistryCancellationContext>.fromOpaque(raw)
                                        .takeUnretainedValue().callback(checkpoint)
                                }, Unmanaged.passUnretained(context).toOpaque(), outcome
                            )
                        }
                    }
                }
            }
        }
    }

    func validate() throws {
        let native = try self.requireOpen()
        try Self.checked { jsti_recording_registry_validate_v2(native, $0) }
    }

    func close() throws {
        let native = try self.requireOpen()
        try Self.checked { jsti_recording_registry_close_v2(native, $0) }
    }

    func destroy() throws {
        try Self.checked { jsti_recording_registry_destroy_v2(&self.native, $0) }
    }

    private func requireOpen() throws -> OpaquePointer {
        guard let native = self.native else { throw WindowsRegistryCapabilityError.closed }
        return native
    }

    @discardableResult
    private static func checked(
        _ action: (UnsafeMutablePointer<JSTIRegistryOutcomeV2>) -> Int32
    ) throws -> WindowsRegistryOutcome {
        var native = JSTIRegistryOutcomeV2()
        native.abi_version = JSTI_REGISTRY_ABI_V2
        native.struct_size = UInt32(MemoryLayout<JSTIRegistryOutcomeV2>.size)
        let status = action(&native)
        let outcome = try WindowsRegistryOutcome(native)
        guard status == 0, outcome.causes.isEmpty, outcome.unconfirmedReleases == 0 else {
            guard status == -1, !outcome.causes.isEmpty else { throw WindowsRegistryCapabilityError.invalidOutcome }
            throw WindowsRegistryFailure(outcomes: [outcome], originalCancellation: nil)
        }
        return outcome
    }
}
