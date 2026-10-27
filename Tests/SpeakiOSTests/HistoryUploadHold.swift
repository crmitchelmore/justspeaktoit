#if os(iOS)
import Foundation
import SpeakCore
import SpeakSync
import XCTest
@testable import SpeakiOSLib

@MainActor
final class HistoryManagerReference {
    weak var value: iOSHistoryManager?
}

/// Only synthetic transport calls are held. Failure cleanup releases present and
/// future calls so a failed expectation cannot strand an owned sync task.
@MainActor
final class HistoryUploadHold {
    private let entered: [XCTestExpectation]
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var next = 0
    private var allReleased = false

    init(entered: [XCTestExpectation]) { self.entered = entered }

    func wait() async -> Int {
        let index = next
        next += 1
        guard !allReleased else { return index }
        await withCheckedContinuation { continuation in
            continuations[index] = continuation
            if entered.indices.contains(index) { entered[index].fulfill() }
        }
        return index
    }

    func release(_ index: Int) { continuations.removeValue(forKey: index)?.resume() }

    func releaseAll() {
        allReleased = true
        let owned = continuations.values
        continuations.removeAll()
        for continuation in owned { continuation.resume() }
    }
}

@MainActor
final class HistoryHeldUploadTransport: HistorySyncTransport {
    let hold: HistoryUploadHold
    private(set) var uploaded: [[SyncableHistoryEntry]] = []

    init(hold: HistoryUploadHold) { self.hold = hold }

    func fetchChanges(after tokenData: Data?) async throws -> HistoryChangePage {
        .init(changes: [], serverChangeTokenData: nil, moreComing: false)
    }

    func upload(entries: [SyncableHistoryEntry]) async -> HistoryUploadResult {
        uploaded.append(entries)
        _ = await hold.wait()
        return .success(ids: Set(entries.map(\.id)))
    }

    func delete(entryID: UUID) async throws {}
}
#endif
