import CoreAudio
import Foundation
import os

/// Adds and removes Core Audio property listener blocks. Injected so the
/// listener lifetime can be tested without audio hardware.
protocol CoreAudioPropertyListenerRegistrar: Sendable {
  func addListener(
    to objectID: AudioObjectID,
    address: AudioObjectPropertyAddress,
    queue: DispatchQueue,
    block: @escaping AudioObjectPropertyListenerBlock
  ) -> OSStatus

  func removeListener(
    from objectID: AudioObjectID,
    address: AudioObjectPropertyAddress,
    queue: DispatchQueue,
    block: @escaping AudioObjectPropertyListenerBlock
  ) -> OSStatus
}

struct SystemCoreAudioPropertyListenerRegistrar: CoreAudioPropertyListenerRegistrar {
  func addListener(
    to objectID: AudioObjectID,
    address: AudioObjectPropertyAddress,
    queue: DispatchQueue,
    block: @escaping AudioObjectPropertyListenerBlock
  ) -> OSStatus {
    var address = address
    return AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block)
  }

  func removeListener(
    from objectID: AudioObjectID,
    address: AudioObjectPropertyAddress,
    queue: DispatchQueue,
    block: @escaping AudioObjectPropertyListenerBlock
  ) -> OSStatus {
    var address = address
    return AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
  }
}

/// One Core Audio property listener, owned for exactly as long as this object
/// lives.
///
/// Core Audio removes a block only when given the same object, address, queue
/// and block it was added with, so all four are kept here. Retirement is
/// synchronous: `invalidate()` (and `deinit`) first closes the gate the block
/// checks, so a callback Core Audio already queued runs as a no-op instead of
/// reaching an owner that is going away, then removes the block. Add and
/// remove failures are reported, never ignored.
final class CoreAudioPropertyListener: @unchecked Sendable {
  enum Operation: String, Sendable {
    case add
    case remove
  }

  typealias FailureHandler = @Sendable (Operation, AudioObjectPropertyAddress, OSStatus) -> Void

  let objectID: AudioObjectID
  let address: AudioObjectPropertyAddress
  let queue: DispatchQueue
  private let block: AudioObjectPropertyListenerBlock
  private let registrar: any CoreAudioPropertyListenerRegistrar
  private let onFailure: FailureHandler
  /// True while callbacks may reach the handler; also whether the block is
  /// still registered and so needs removing.
  private let isActive: OSAllocatedUnfairLock<Bool>

  /// Registers `handler` for `address`; it runs on `queue` until this
  /// listener is invalidated. When Core Audio rejects the registration the
  /// failure is reported and `isRegistered` is false.
  init(
    objectID: AudioObjectID = AudioObjectID(kAudioObjectSystemObject),
    address: AudioObjectPropertyAddress,
    queue: DispatchQueue,
    registrar: any CoreAudioPropertyListenerRegistrar = SystemCoreAudioPropertyListenerRegistrar(),
    onFailure: @escaping FailureHandler,
    handler: @escaping @Sendable () -> Void
  ) {
    let isActive = OSAllocatedUnfairLock(initialState: true)
    self.objectID = objectID
    self.address = address
    self.queue = queue
    self.registrar = registrar
    self.onFailure = onFailure
    self.isActive = isActive
    self.block = { _, _ in
      guard isActive.withLock({ $0 }) else { return }
      handler()
    }
    let status = registrar.addListener(to: objectID, address: address, queue: queue, block: block)
    if status != noErr {
      isActive.withLock { $0 = false }
      onFailure(.add, address, status)
    }
  }

  var isRegistered: Bool {
    isActive.withLock { $0 }
  }

  /// Stops callbacks and removes the block. Idempotent.
  func invalidate() {
    let wasActive = isActive.withLock { active in
      defer { active = false }
      return active
    }
    guard wasActive else { return }
    let status = registrar.removeListener(from: objectID, address: address, queue: queue, block: block)
    if status != noErr {
      onFailure(.remove, address, status)
    }
  }

  deinit {
    invalidate()
  }
}
