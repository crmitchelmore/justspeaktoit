import Foundation

import SpeakSync

/// Thread-safe counter shared with a `UserDefaults` subclass, which must stay
/// `Sendable` and therefore cannot hold mutable state of its own.
final class WriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

/// UserDefaults that counts writes, so the tests can assert how many times the
/// synced-ID bookkeeping array is rewritten during a sync pass.
final class WriteCountingUserDefaults: UserDefaults {
    let writes = WriteCounter()

    override func set(_ value: Any?, forKey defaultName: String) {
        writes.increment()
        super.set(value, forKey: defaultName)
    }
}

/// A remote entry as the sync engine would hand it to the delegate.
func makeEntry(
    id: UUID = UUID(),
    text: String,
    updatedAt: Date = Date(timeIntervalSince1970: 10)
) -> SyncableHistoryEntry {
    SyncableHistoryEntry(
        id: id,
        createdAt: Date(timeIntervalSince1970: 1),
        rawTranscription: text,
        postProcessedText: nil,
        model: "test",
        duration: 1,
        wordCount: 1,
        originPlatform: "ios",
        updatedAt: updatedAt
    )
}
