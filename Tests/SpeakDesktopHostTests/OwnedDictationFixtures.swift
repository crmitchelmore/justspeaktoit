import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

actor DictationFixtureGate {
    private var opened: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var entries = 0
    init(open: Bool = true) { opened = open }
    func pass() async {
        entries += 1
        if !opened { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

func dictationPCM(_ samples: [Int16]) -> Data {
    Data(samples.flatMap { sample -> [UInt8] in
        let bits = UInt16(bitPattern: sample)
        return [UInt8(truncatingIfNeeded: bits), UInt8(truncatingIfNeeded: bits >> 8)]
    })
}

actor DictationFixtureWorker: DesktopPressCaptureQuiescingWorker {
    let opening: DictationFixtureGate
    let quiescing: DictationFixtureGate
    let retiring: DictationFixtureGate
    private var receive: (@Sendable (Data) -> Void)?
    private var onFailure: (@Sendable (String) -> Void)?
    private var oldReceivers: [@Sendable (Data) -> Void] = []
    private var oldFailures: [@Sendable (String) -> Void] = []
    private(set) var opens = 0
    private(set) var quiescences = 0
    private(set) var retirements = 0
    private(set) var identities: [DesktopPressCaptureIdentity] = []
    private var initial = Data()
    private var tail = dictationPCM(Array(Int16(1)...Int16(73)))
    private var openFailure = false
    private var lateFailure = false
    private var retirementFailures = 0
    private(set) var events: [String] = []

    init(
        opening: DictationFixtureGate = .init(), quiescing: DictationFixtureGate = .init(),
        retiring: DictationFixtureGate = .init()
    ) {
        self.opening = opening
        self.quiescing = quiescing
        self.retiring = retiring
    }

    func configure(
        initial: Data = Data(), tail: Data = dictationPCM(Array(Int16(1)...Int16(73))),
        openFailure: Bool = false, lateFailure: Bool = false, retirementFailures: Int = 0
    ) {
        self.initial = initial
        self.tail = tail
        self.openFailure = openFailure
        self.lateFailure = lateFailure
        self.retirementFailures = retirementFailures
    }

    func open(
        id: UUID, identity: DesktopPressCaptureIdentity, receive: @escaping @Sendable (Data) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) async throws {
        opens += 1
        identities.append(identity)
        self.receive = receive
        self.onFailure = onFailure
        oldReceivers.append(receive)
        oldFailures.append(onFailure)
        events.append("open")
        if !initial.isEmpty { receive(initial) }
        await opening.pass()
        if openFailure { throw DesktopHostError(message: "fixture open failed after PCM") }
        events.append("ready")
    }

    func quiesce(id: UUID) async throws {
        quiescences += 1
        events.append("quiescing")
        await quiescing.pass()
        if !tail.isEmpty { receive?(tail) }
        if lateFailure { onFailure?("fixture final callback failed") }
        events.append("quiesced")
    }

    func close(id: UUID) async throws {
        retirements += 1
        events.append("retiring")
        await retiring.pass()
        if retirementFailures > 0 {
            retirementFailures -= 1
            throw DesktopHostError(message: "fixture retirement failed")
        }
        events.append("retired")
    }

    func emitLate(_ data: Data) { receive?(data) }
    func staleCallbacks() {
        oldReceivers.first?(dictationPCM([999]))
        oldFailures.first?("stale prior run failure")
    }
    func clearRetirementFailure() { retirementFailures = 0 }
}

final class DictationFixtureBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var raw = Data()
    private var failures: [DesktopPressCaptureFailureEvent] = []
    func append(_ delivery: DesktopPressCapturePCMDelivery) { lock.withLock { raw.append(delivery.data) } }
    func failure(_ event: DesktopPressCaptureFailureEvent) { lock.withLock { failures.append(event) } }
    var data: Data { lock.withLock { raw } }
    var errors: [DesktopPressCaptureFailureEvent] { lock.withLock { failures } }
}

func waitForDictation(
    isolation: isolated (any Actor)? = #isolation, _ condition: () async -> Bool
) async throws {
    for _ in 0..<2_000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("Synthetic owned dictation gate did not settle.")
    throw DesktopHostError(message: "Owned dictation fixture timed out.")
}

func assertDictationWAV(_ url: URL, samples: [Int16], file: StaticString = #filePath, line: UInt = #line) throws {
    let data = try Data(contentsOf: url)
    let pcm = dictationPCM(samples)
    XCTAssertEqual(data.count, 44 + pcm.count, file: file, line: line)
    guard data.count >= 44 else { return }
    func little(_ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
    }
    XCTAssertEqual(
        try XCTUnwrap(String(bytes: data[0..<4], encoding: .utf8)), "RIFF", file: file, line: line)
    XCTAssertEqual(
        try XCTUnwrap(String(bytes: data[8..<12], encoding: .utf8)), "WAVE", file: file, line: line)
    XCTAssertEqual(
        try XCTUnwrap(String(bytes: data[36..<40], encoding: .utf8)), "data", file: file, line: line)
    XCTAssertEqual(little(4), UInt32(36 + pcm.count), file: file, line: line)
    XCTAssertEqual(little(40), UInt32(pcm.count), file: file, line: line)
    XCTAssertEqual(
        try XCTUnwrap(String(bytes: data[12..<16], encoding: .utf8)), "fmt ", file: file, line: line)
    XCTAssertEqual(little(16), 16, file: file, line: line)
    XCTAssertEqual(Array(data[20..<24]), [1, 0, 1, 0], file: file, line: line)
    XCTAssertEqual(Array(data[32..<36]), [2, 0, 16, 0], file: file, line: line)
    XCTAssertTrue([UInt32(16_000), UInt32(24_000)].contains(little(24)), file: file, line: line)
    XCTAssertEqual(little(28), little(24) * 2, file: file, line: line)
    XCTAssertEqual(Data(data.dropFirst(44)), pcm, file: file, line: line)
}
