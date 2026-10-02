import AppKit
import SpeakCore
import XCTest

@testable import SpeakApp

/// WireUp bootstrap tests run the real service graph over a host's owned
/// storage. These seed synthetic history, a write-ahead log, a lexicon rule,
/// Compare Models state and preferences inside a host, bootstrap, and prove
/// that startup recovery and every store acted on that root, and that the
/// process-wide integrations were requested rather than started.
@MainActor
final class WireUpHostIsolationTests: XCTestCase {
    private let syncedIDsKey = "speak.sync.syncedMacHistoryIDs"

    func testBootstrap_recoversSeededStateInsideTheHostOnly() async throws {
        let host = try makeWireUpTestHost()
        let history = try historyFiles(in: host)
        let kept = makeItem(text: "Synthetic snapshot entry")
        let recovered = makeItem(text: "Synthetic write-ahead entry")
        let log = HistoryWALStore(storageURL: history.snapshot, walURL: history.writeAheadLog)
        try await log.writeSnapshot([kept])
        try await log.append(WALEntry(operation: .append, item: recovered))
        let rule = PersonalLexiconRule(
            displayName: "Synthetic", canonical: "Synthetik", aliases: ["synthetic"],
            activation: .automatic, contextTags: [], confidence: .high, notes: nil
        )
        try await PersonalLexiconStore(fileManager: host.fileManager).save([rule])
        let comparisons = host.appSupportDirectory.appendingPathComponent("Comparisons", isDirectory: true)
        let samples = comparisons.appendingPathComponent("Samples", isDirectory: true)
        try FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: comparisons.appendingPathComponent("rounds.json"))
        let orphan = samples.appendingPathComponent("Synthetic-orphan.wav")
        try Data([0]).write(to: orphan)
        host.defaults.set([kept.id.uuidString], forKey: syncedIDsKey)
        let usage = TTSUsageRecord(
            provider: .system, voice: "system/synthetic", duration: 1, characterCount: 9, cost: nil, timestamp: Date()
        )
        host.defaults.set(try JSONEncoder().encode([usage]), forKey: "ttsUsageHistory")

        let environment = WireUp.bootstrap(options: host.options())
        await environment.history.waitUntilLoaded()
        await environment.personalLexicon.waitUntilLoaded()

        // Recovery replayed the log into the host's snapshot and cleared it.
        XCTAssertEqual(Set(environment.history.allItems.map(\.id)), [kept.id, recovered.id])
        XCTAssertEqual(Set(try decodeSnapshot(at: history.snapshot).map(\.id)), [kept.id, recovered.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.writeAheadLog.path))
        // Every file-backed store resolved inside the host.
        XCTAssertEqual(environment.personalLexicon.rules.map(\.id), [rule.id])
        let corrections = host.appSupportDirectory.appendingPathComponent("AutoCorrections", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: corrections.path))
        XCTAssertTrue(isInside(environment.comparisonRounds.storageURL, host))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path), "The sample sweep ran on the host's copy")
        XCTAssertTrue(isInside(environment.settings.recordingsDirectory, host))
        // Stores that keep their own preferences read the host's suite.
        XCTAssertEqual(environment.historySyncAdapter?.pendingEntries().map(\.id), [recovered.id])
        XCTAssertEqual(environment.tts.usageHistory.map(\.voice), ["system/synthetic"])
        // Process-wide integrations were requested for the retained objects, not started.
        let start = try XCTUnwrap(host.cloudSyncStarts.first)
        XCTAssertEqual(host.cloudSyncStarts.count, 1)
        XCTAssertTrue(start.history === environment.historySyncAdapter)
        XCTAssertTrue(start.comparisons === environment.comparisonSyncAdapter)
        XCTAssertTrue(start.remoteTranscripts === environment.remoteTranscriptDelivery)
        XCTAssertEqual(host.analyticsRequests, 1)
        XCTAssertFalse(environment.analyticsAvailable)
        XCTAssertEqual(host.activationPolicies, [.regular])
        XCTAssertEqual(host.loginItemRequests, [false])
    }

    func testBootstrap_quarantinesAnUnreadableLogInsideTheHostOnly() async throws {
        let host = try makeWireUpTestHost()
        let history = try historyFiles(in: host)
        let kept = makeItem(text: "Synthetic snapshot entry")
        try await HistoryWALStore(storageURL: history.snapshot, walURL: history.writeAheadLog).writeSnapshot([kept])
        try Data("not a history log".utf8).write(to: history.writeAheadLog)

        let environment = WireUp.bootstrap(options: host.options())
        await environment.history.waitUntilLoaded()

        XCTAssertEqual(environment.history.allItems.map(\.id), [kept.id])
        let names = try FileManager.default.contentsOfDirectory(
            atPath: history.writeAheadLog.deletingLastPathComponent().path
        )
        XCTAssertFalse(names.contains(history.writeAheadLog.lastPathComponent))
        XCTAssertEqual(names.filter { $0.hasPrefix("history-wal.corrupt-") }.count, 1)
    }

    func testHostSettings_recordDockAndLoginItemChangesInsteadOfApplyingThem() throws {
        let host = try makeWireUpTestHost()
        let settings = host.makeSettings()

        settings.appVisibility = .menuBarOnly
        settings.runAtLogin = true

        XCTAssertEqual(host.activationPolicies, [.regular, .accessory])
        XCTAssertEqual(host.loginItemRequests, [false, true])
        XCTAssertTrue(isInside(settings.recordingsDirectory, host))
        XCTAssertTrue(FileManager.default.fileExists(atPath: settings.recordingsDirectory.path))
    }

    func testEnvironmentHolder_addsNoStatusItemForTheDockOnlyHost() throws {
        let host = try makeWireUpTestHost()
        let holder = EnvironmentHolder()

        holder.bootstrap(options: host.options())

        let environment = try XCTUnwrap(holder.environment)
        XCTAssertFalse(environment.settings.shouldShowStatusBarIcon)
        XCTAssertNil(environment.statusBarController)
    }

    func testHostFileManager_resolvesEverySearchPathInsideTheRoot() throws {
        let host = try makeWireUpTestHost()
        let directories: [FileManager.SearchPathDirectory] = [
            .applicationSupportDirectory, .cachesDirectory, .documentDirectory, .libraryDirectory, .downloadsDirectory
        ]
        for directory in directories {
            for mask: FileManager.SearchPathDomainMask in [.userDomainMask, .localDomainMask, .allDomainsMask] {
                let urls = host.fileManager.urls(for: directory, in: mask)
                XCTAssertFalse(urls.isEmpty)
                XCTAssertTrue(urls.allSatisfy { isInside($0, host) }, "\(directory.rawValue) in \(mask.rawValue)")
            }
        }
        XCTAssertTrue(isInside(host.fileManager.homeDirectoryForCurrentUser, host))
    }

    /// Pure path checks: nothing here creates or removes anything.
    func testHostTeardown_refusesDirectoriesItDoesNotOwn() throws {
        let host = try makeWireUpTestHost()
        let temporary = FileManager.default.temporaryDirectory

        XCTAssertTrue(WireUpTestHost.owns(root: host.root, name: host.name))
        XCTAssertFalse(WireUpTestHost.owns(root: temporary, name: host.name))
        XCTAssertFalse(WireUpTestHost.owns(root: host.root.appendingPathComponent("nested"), name: host.name))
        XCTAssertFalse(WireUpTestHost.owns(root: temporary.appendingPathComponent("unrelated"), name: "unrelated"))
        let bare = WireUpTestHost.namePrefix
        XCTAssertFalse(WireUpTestHost.owns(root: temporary.appendingPathComponent(bare), name: bare))
        let elsewhere = temporary.deletingLastPathComponent().appendingPathComponent(host.name)
        XCTAssertFalse(WireUpTestHost.owns(root: elsewhere, name: host.name))
    }

    // MARK: - Helpers

    private func historyFiles(in host: WireUpTestHost) throws -> (snapshot: URL, writeAheadLog: URL) {
        let directory = host.appSupportDirectory.appendingPathComponent("History", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (
            directory.appendingPathComponent("history-log.json", isDirectory: false),
            directory.appendingPathComponent("history-wal.json", isDirectory: false)
        )
    }

    private func decodeSnapshot(at url: URL) throws -> [HistoryItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([HistoryItem].self, from: Data(contentsOf: url))
    }

    private func isInside(_ url: URL, _ host: WireUpTestHost) -> Bool {
        url.standardizedFileURL.path.hasPrefix(host.root.standardizedFileURL.path + "/")
    }

    private func makeItem(text: String) -> HistoryItem {
        HistoryItem(
            id: UUID(),
            createdAt: Date(),
            modelsUsed: ["apple/local/SFSpeechRecognizer"],
            rawTranscription: text,
            postProcessedTranscription: nil,
            recordingDuration: 1,
            cost: nil,
            audioFileURL: nil,
            networkExchanges: [],
            events: [],
            phaseTimestamps: PhaseTimestamps(
                recordingStarted: nil,
                recordingEnded: nil,
                transcriptionStarted: nil,
                transcriptionEnded: nil,
                postProcessingStarted: nil,
                postProcessingEnded: nil,
                outputDelivered: nil
            ),
            trigger: HistoryTrigger(
                gesture: .singleTap,
                hotKeyDescription: "Synthetic",
                outputMethod: .clipboard,
                destinationApplication: nil
            ),
            personalCorrections: nil,
            errors: []
        )
    }
}
