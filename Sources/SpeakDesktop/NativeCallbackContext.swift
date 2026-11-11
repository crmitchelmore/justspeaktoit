import Foundation

/// The `void *` context one native callback registration borrows.
///
/// Creating it retains the box, and through it `Value`, for native code, so a
/// registration can never outlive the object it calls back into.
/// `unregister()` drops `Value` once native code has been told to stop:
/// callbacks still in flight or arriving later resolve `nil` and do nothing.
/// `release()` also frees the box; call it only when native code can no longer
/// call (its own unregister returned, or the synchronous call that borrowed the
/// pointer finished). A registration native code never detaches keeps only the
/// empty box after `unregister()`.
public final class NativeCallbackContext<Value: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    private var retainedForNative = true

    public init(_ value: Value) {
        stored = value
        // The native registration's reference, balanced once by `release()`.
        _ = Unmanaged.passRetained(self)
    }

    /// The context to hand native code. Stable for the box's life.
    public var pointer: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    /// The registered object, or nil once unregistered.
    public var value: Value? { lock.withLock { stored } }

    /// The object behind a native callback's context, or nil when the
    /// registration has ended. Only pointers from `pointer` of the same `Value`.
    public static func resolve(_ pointer: UnsafeMutableRawPointer?) -> Value? {
        guard let pointer else { return nil }
        return Unmanaged<NativeCallbackContext<Value>>.fromOpaque(pointer).takeUnretainedValue().value
    }

    /// Later callbacks become no-ops; `Value` is released. Idempotent.
    public func unregister() { lock.withLock { stored = nil } }

    /// Unregisters and frees the box. Native code must no longer hold `pointer`.
    public func release() {
        let balance = lock.withLock {
            stored = nil
            defer { retainedForNative = false }
            return retainedForNative
        }
        if balance { Unmanaged.passUnretained(self).release() }
    }

    /// Lends `value` to one synchronous native call whose ABI guarantees no
    /// callback after it returns.
    public static func withScoped<Result>(
        _ value: Value, _ body: (UnsafeMutableRawPointer) throws -> Result
    ) rethrows -> Result {
        let context = NativeCallbackContext(value)
        defer { context.release() }
        return try body(context.pointer)
    }
}

/// A native handler slot that holds at most one registration. `attach` sets
/// the C handler with the context, or clears it when passed nil, and reports
/// success. The slot's lock is never held by callback forwarding.
public final class NativeCallbackSlot<Value: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private let attach: (UnsafeMutableRawPointer?) -> Bool
    private var active: NativeCallbackContext<Value>?

    public init(attach: @escaping (UnsafeMutableRawPointer?) -> Bool) { self.attach = attach }

    /// Replaces any current registration; nil when the native slot refused it.
    public func begin(_ value: Value) -> NativeCallbackContext<Value>? {
        lock.withLock {
            if let active, !endLocked(active) { return nil }
            let registration = NativeCallbackContext(value)
            guard attach(registration.pointer) else {
                registration.release()
                return nil
            }
            active = registration
            return registration
        }
    }

    /// Detaches `registration` if it is still current. False when the native
    /// slot could not be cleared, so it may still call.
    @discardableResult
    public func end(_ registration: NativeCallbackContext<Value>) -> Bool {
        lock.withLock { endLocked(registration) }
    }

    private func endLocked(_ registration: NativeCallbackContext<Value>) -> Bool {
        guard active === registration else { return true }
        guard attach(nil) else { return false }
        active = nil
        // A callback already running may still read the box; it resolves nil.
        registration.unregister()
        return true
    }
}
