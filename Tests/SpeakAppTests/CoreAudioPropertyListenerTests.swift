import CoreAudio
import Foundation
import os
import XCTest

@testable import SpeakApp

private final class FakeListenerRegistrar: CoreAudioPropertyListenerRegistrar, @unchecked Sendable {
  struct Call {
    let objectID: AudioObjectID
    let selector: AudioObjectPropertySelector
    let queue: DispatchQueue
    let block: AudioObjectPropertyListenerBlock
  }

  private let lock = NSLock()
  private var _adds: [Call] = []
  private var _removes: [Call] = []
  var addStatus: OSStatus = noErr
  var removeStatus: OSStatus = noErr

  var adds: [Call] { lock.withLock { _adds } }
  var removes: [Call] { lock.withLock { _removes } }

  func addListener(
    to objectID: AudioObjectID,
    address: AudioObjectPropertyAddress,
    queue: DispatchQueue,
    block: @escaping AudioObjectPropertyListenerBlock
  ) -> OSStatus {
    lock.withLock { _adds.append(Call(objectID: objectID, selector: address.mSelector, queue: queue, block: block)) }
    return addStatus
  }

  func removeListener(
    from objectID: AudioObjectID,
    address: AudioObjectPropertyAddress,
    queue: DispatchQueue,
    block: @escaping AudioObjectPropertyListenerBlock
  ) -> OSStatus {
    lock.withLock { _removes.append(Call(objectID: objectID, selector: address.mSelector, queue: queue, block: block)) }
    return removeStatus
  }

  /// Fires a registered block the way Core Audio would.
  func fire(_ call: Call) {
    var address = AudioObjectPropertyAddress(
      mSelector: call.selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    call.block(1, &address)
  }
}

private final class Counter: @unchecked Sendable {
  private let value = OSAllocatedUnfairLock(initialState: 0)
  func increment() { value.withLock { $0 += 1 } }
  var count: Int { value.withLock { $0 } }
}

private final class FailureLog: @unchecked Sendable {
  private let entries = OSAllocatedUnfairLock(initialState: [(CoreAudioPropertyListener.Operation, OSStatus)]())
  func record(_ operation: CoreAudioPropertyListener.Operation, _ status: OSStatus) {
    entries.withLock { $0.append((operation, status)) }
  }
  var all: [(CoreAudioPropertyListener.Operation, OSStatus)] { entries.withLock { $0 } }
}

final class CoreAudioPropertyListenerTests: XCTestCase {
  private let address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
  )

  private func makeListener(
    registrar: FakeListenerRegistrar,
    queue: DispatchQueue,
    counter: Counter,
    failures: FailureLog = FailureLog()
  ) -> CoreAudioPropertyListener {
    CoreAudioPropertyListener(
      address: address,
      queue: queue,
      registrar: registrar,
      onFailure: { operation, _, status in failures.record(operation, status) },
      handler: { counter.increment() }
    )
  }

  func testCallbacksReachTheHandlerWhileRegistered() {
    let registrar = FakeListenerRegistrar()
    let counter = Counter()
    let listener = makeListener(registrar: registrar, queue: .main, counter: counter)

    registrar.fire(registrar.adds[0])

    XCTAssertTrue(listener.isRegistered)
    XCTAssertEqual(counter.count, 1)
  }

  func testRemovalUsesTheRegisteredObjectAddressAndQueue() {
    let registrar = FakeListenerRegistrar()
    let queue = DispatchQueue(label: "listener-test")
    var listener: CoreAudioPropertyListener? = makeListener(registrar: registrar, queue: queue, counter: Counter())
    XCTAssertNotNil(listener)

    listener = nil

    XCTAssertEqual(registrar.removes.count, 1)
    let (added, removed) = (registrar.adds[0], registrar.removes[0])
    XCTAssertEqual(removed.objectID, added.objectID)
    XCTAssertEqual(removed.selector, added.selector)
    XCTAssertTrue(removed.queue === added.queue)
  }

  func testCallbackQueuedBeforeRetirementIsANoOp() {
    let registrar = FakeListenerRegistrar()
    let queue = DispatchQueue(label: "listener-test")
    let counter = Counter()
    var listener: CoreAudioPropertyListener? = makeListener(registrar: registrar, queue: queue, counter: counter)
    XCTAssertNotNil(listener)
    let added = registrar.adds[0]

    // Core Audio has already queued a callback when the owner retires.
    let gate = DispatchSemaphore(value: 0)
    let delivered = expectation(description: "queued callback ran")
    queue.async {
      gate.wait()
      registrar.fire(added)
      delivered.fulfill()
    }
    listener = nil
    gate.signal()

    wait(for: [delivered], timeout: 2)
    XCTAssertEqual(counter.count, 0)
  }

  func testInvalidateIsIdempotent() {
    let registrar = FakeListenerRegistrar()
    let listener = makeListener(registrar: registrar, queue: .main, counter: Counter())

    listener.invalidate()
    listener.invalidate()

    XCTAssertFalse(listener.isRegistered)
    XCTAssertEqual(registrar.removes.count, 1)
  }

  func testAddFailureIsReportedAndNothingIsRemoved() {
    let registrar = FakeListenerRegistrar()
    registrar.addStatus = OSStatus(kAudioHardwareBadObjectError)
    let failures = FailureLog()
    var listener: CoreAudioPropertyListener? = makeListener(
      registrar: registrar, queue: .main, counter: Counter(), failures: failures
    )

    XCTAssertEqual(listener?.isRegistered, false)
    listener = nil

    XCTAssertTrue(registrar.removes.isEmpty)
    XCTAssertEqual(failures.all.map(\.0), [.add])
    XCTAssertEqual(failures.all.map(\.1), [OSStatus(kAudioHardwareBadObjectError)])
  }

  func testRemoveFailureIsReported() {
    let registrar = FakeListenerRegistrar()
    registrar.removeStatus = OSStatus(kAudioHardwareUnspecifiedError)
    let failures = FailureLog()
    let listener = makeListener(registrar: registrar, queue: .main, counter: Counter(), failures: failures)

    listener.invalidate()

    XCTAssertEqual(failures.all.map(\.0), [.remove])
  }

  @MainActor
  func testDeviceManagerRetiresBothHardwareListenersOnDeinit() {
    let registrar = FakeListenerRegistrar()
    var manager: AudioInputDeviceManager? = AudioInputDeviceManager(
      appSettings: AppSettings(defaults: UserDefaults(suiteName: "CoreAudioListenerTests-\(UUID().uuidString)")!),
      listenerRegistrar: registrar
    )
    XCTAssertNotNil(manager)
    XCTAssertEqual(
      Set(registrar.adds.map(\.selector)),
      [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]
    )

    manager = nil

    XCTAssertEqual(registrar.removes.count, 2)
  }
}
