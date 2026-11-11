import Foundation

/// The `void *` context one native callback registration borrows.
///
/// Creating it retains the box, and through it `Value`, for native code, so a
/// registration can never outlive the object it calls back into.
/// `unregister()` drops `Value` once native code has been told to stop:
/// callbacks still in flight or arriving later resolve `nil` and do nothing.
/// `release()` also frees the box; call it only when native code can no longer
/// call (its own unregister returned after draining callbacks, or the
/// synchronous call that borrowed the pointer finished). `retire(nativeQuiescent:)`
/// picks between the two from what native code confirmed. A registration
/// native code may still call keeps only the empty box after `unregister()`.
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

    /// Ends the registration from what native code confirmed. Quiescent:
    /// native code returned only after every running callback finished and
    /// never calls again, so the box is freed. Otherwise a late callback may
    /// still read the box, so it is kept (empty) and only `Value` is released.
    /// Returns true when the box was freed.
    @discardableResult
    public func retire(nativeQuiescent: Bool) -> Bool {
        guard nativeQuiescent else {
            unregister()
            return false
        }
        release()
        return true
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

/// What a native handler slot reported when asked to stop calling a context.
public enum NativeCallbackDetach: Equatable, Sendable {
    /// The slot could not be cleared; native code may still call.
    case refused
    /// No new callback starts, but one already running may still read the context.
    case stopped
    /// The slot waited for every running callback to finish; native code never calls again.
    case quiescent
}

/// A native handler slot that holds at most one registration.
///
/// A registration ends when it is replaced or `end` is called. If native code
/// confirms quiescence its box is freed at once; otherwise the empty box is
/// kept as a retired registration, so a late callback resolves nil rather
/// than reading freed memory. Retired boxes are bounded by `retiredLimit`:
/// `begin` refuses a new registration once that many are outstanding, and
/// `reclaimRetired()` frees them when native code later confirms that none can
/// be called (for example, the thread that delivers callbacks has exited).
/// The slot's lock is never held by callback forwarding.
public final class NativeCallbackSlot<Value: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private let attach: (UnsafeMutableRawPointer) -> Bool
    private let detach: () -> NativeCallbackDetach
    private let retiredLimit: Int
    private var active: NativeCallbackContext<Value>?
    private var retired: [NativeCallbackContext<Value>] = []

    /// `attach` installs the C handler with a context and reports success.
    /// `detach` clears it and reports whether native code is quiescent.
    public init(
        retiredLimit: Int = 4,
        attach: @escaping (UnsafeMutableRawPointer) -> Bool,
        detach: @escaping () -> NativeCallbackDetach
    ) {
        self.retiredLimit = max(1, retiredLimit)
        self.attach = attach
        self.detach = detach
    }

    /// `attach` sets the C handler with the context, or clears it when passed
    /// nil, and reports success. A cleared handler is not assumed quiescent.
    public convenience init(retiredLimit: Int = 4, attach: @escaping (UnsafeMutableRawPointer?) -> Bool) {
        self.init(retiredLimit: retiredLimit, attach: { attach($0) }, detach: { attach(nil) ? .stopped : .refused })
    }

    /// Ended registrations whose boxes native code may still read.
    public var retiredCount: Int { lock.withLock { retired.count } }

    /// Replaces any current registration; nil when the native slot refused
    /// it, or when `retiredLimit` retired boxes are still unreclaimed.
    public func begin(_ value: Value) -> NativeCallbackContext<Value>? {
        lock.withLock {
            if let active, !endLocked(active) { return nil }
            guard retired.count < retiredLimit else { return nil }
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

    /// Frees every retired box. Call only once native code has confirmed that
    /// no callback for them is running or can start.
    public func reclaimRetired() {
        let boxes = lock.withLock { () -> [NativeCallbackContext<Value>] in
            defer { retired = [] }
            return retired
        }
        boxes.forEach { $0.release() }
    }

    private func endLocked(_ registration: NativeCallbackContext<Value>) -> Bool {
        guard active === registration else { return true }
        let outcome = detach()
        guard outcome != .refused else { return false }
        active = nil
        // A callback already running may still read a stopped box; it resolves nil.
        if !registration.retire(nativeQuiescent: outcome == .quiescent) { retired.append(registration) }
        return true
    }
}
