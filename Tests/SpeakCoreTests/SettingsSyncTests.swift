import XCTest

@testable import SpeakCore

final class SettingsSyncTests: XCTestCase {
    private final class MemoryStore: SettingsSyncBackingStore {
        var values: [String: Any] = [:]
        var synchronizeCount = 0

        func object(forKey defaultName: String) -> Any? {
            values[defaultName]
        }

        func set(_ value: Any?, forKey defaultName: String) {
            values[defaultName] = value
        }

        func removeObject(forKey defaultName: String) {
            values.removeValue(forKey: defaultName)
        }

        func synchronize() -> Bool {
            synchronizeCount += 1
            return true
        }
    }

    private var suiteNames: [String] = []

    override func tearDown() {
        for suiteName in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "SettingsSyncTests.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeSUT(
        store: SettingsSyncBackingStore? = nil,
        defaults: UserDefaults? = nil,
        isAvailable: Bool = false,
        now: @escaping () -> Date = Date.init,
        deviceID: @escaping () -> String = { "device-a" }
    ) -> SettingsSync {
        SettingsSync(
            ubiquitousStore: store,
            localStorage: defaults ?? makeDefaults(),
            isUbiquitousStoreAvailable: isAvailable,
            now: now,
            deviceID: deviceID
        )
    }

    func testTypedRecordCodable_roundtripsStringBoolDoubleArrayAndNull() throws {
        let records = [
            SyncedSettingRecord(
                key: .selectedModel, value: .string("model"),
                updatedAt: Date(timeIntervalSince1970: 1), originDeviceID: "a"
            ),
            SyncedSettingRecord(
                key: .autoStartRecording, value: .bool(true),
                updatedAt: Date(timeIntervalSince1970: 2), originDeviceID: "a"
            ),
            SyncedSettingRecord(
                key: .lastSyncTimestamp, value: .double(3),
                updatedAt: Date(timeIntervalSince1970: 3), originDeviceID: "a"
            ),
            SyncedSettingRecord(
                key: .hapticFeedback, value: .stringArray(["one", "two"]),
                updatedAt: Date(timeIntervalSince1970: 4), originDeviceID: "a"
            ),
            SyncedSettingRecord(
                key: .postProcessingPrompt, value: .null,
                updatedAt: Date(timeIntervalSince1970: 5), originDeviceID: "a"
            )
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode([SyncedSettingRecord].self, from: encoder.encode(records))

        XCTAssertEqual(decoded, records)
    }

    func testLWWResolver_newerTimestampWins() {
        let older = SyncedSettingRecord(
            key: .selectedModel,
            value: .string("old"),
            updatedAt: Date(timeIntervalSince1970: 1),
            originDeviceID: "device-z"
        )
        let newer = SyncedSettingRecord(
            key: .selectedModel,
            value: .string("new"),
            updatedAt: Date(timeIntervalSince1970: 2),
            originDeviceID: "device-a"
        )

        XCTAssertTrue(SettingsConflictResolver.shouldReplace(existing: older, with: newer))
        XCTAssertFalse(SettingsConflictResolver.shouldReplace(existing: newer, with: older))
    }

    func testLWWResolver_equalTimestampUsesStableOriginDeviceTieBreak() {
        let date = Date(timeIntervalSince1970: 1)
        let lower = SyncedSettingRecord(
            key: .selectedModel, value: .string("lower"),
            updatedAt: date, originDeviceID: "device-a"
        )
        let higher = SyncedSettingRecord(
            key: .selectedModel, value: .string("higher"),
            updatedAt: date, originDeviceID: "device-b"
        )

        XCTAssertTrue(SettingsConflictResolver.shouldReplace(existing: lower, with: higher))
        XCTAssertFalse(SettingsConflictResolver.shouldReplace(existing: higher, with: lower))
    }

    func testUnchangedSetPreservesTimestampAndDoesNotNotifyAgain() {
        var now = Date(timeIntervalSince1970: 10)
        let sut = makeSUT(now: { now })
        var localNotificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: SettingsSync.didChangeLocalRecordsNotification,
            object: sut,
            queue: nil
        ) { _ in
            localNotificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        sut.set(.string("model-a"), forKey: .selectedModel)
        now = Date(timeIntervalSince1970: 20)
        sut.set(.string("model-a"), forKey: .selectedModel)

        XCTAssertEqual(sut.record(forKey: .selectedModel)?.updatedAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(localNotificationCount, 1)
    }

    func testLocalFallbackRecordRoundtripAndMergeChangedKeys() {
        let defaults = makeDefaults()
        let sut = makeSUT(defaults: defaults, now: { Date(timeIntervalSince1970: 10) })
        sut.set(.bool(true), forKey: .autoStartRecording)

        let reloaded = makeSUT(defaults: defaults)
        XCTAssertEqual(reloaded.record(forKey: .autoStartRecording)?.value, .bool(true))

        let changed = reloaded.mergeIncomingRecords([
            SyncedSettingRecord(
                key: .autoStartRecording,
                value: .bool(false),
                updatedAt: Date(timeIntervalSince1970: 20),
                originDeviceID: "device-b"
            ),
            SyncedSettingRecord(
                key: .postProcessingEnabled,
                value: .bool(true),
                updatedAt: Date(timeIntervalSince1970: 20),
                originDeviceID: "device-b"
            )
        ])

        XCTAssertEqual(changed, [.autoStartRecording, .postProcessingEnabled])
        XCTAssertFalse(reloaded.bool(forKey: .autoStartRecording))
        XCTAssertTrue(reloaded.bool(forKey: .postProcessingEnabled))
    }

    func testKVSAndLocalFallbackShareRecordMetadata() {
        let kvs = MemoryStore()
        let defaults = makeDefaults()
        let date = Date(timeIntervalSince1970: 42)
        let sut = makeSUT(store: kvs, defaults: defaults, isAvailable: true, now: { date }, deviceID: { "device-kvs" })

        sut.set(.string("openai/gpt-realtime-whisper-streaming"), forKey: .selectedModel)

        let localReloaded = makeSUT(defaults: defaults)
        let kvsReloaded = makeSUT(store: kvs, defaults: makeDefaults(), isAvailable: true)
        XCTAssertEqual(localReloaded.record(forKey: .selectedModel), kvsReloaded.record(forKey: .selectedModel))
        XCTAssertEqual(kvsReloaded.record(forKey: .selectedModel)?.updatedAt, date)
        XCTAssertEqual(kvsReloaded.record(forKey: .selectedModel)?.originDeviceID, "device-kvs")
    }

    func testLegacyPrimitiveMigratesWithDistantPastTimestamp() {
        let defaults = makeDefaults()
        defaults.set("legacy-model", forKey: SettingsSync.SyncKey.selectedModel.rawValue)

        let sut = makeSUT(defaults: defaults)

        let record = sut.record(forKey: .selectedModel)
        XCTAssertEqual(record?.value, .string("legacy-model"))
        XCTAssertEqual(record?.updatedAt, .distantPast)
        XCTAssertEqual(record?.originDeviceID, "legacy")
    }

    func testSecretLikeSyncKeyNamesCannotDecodeAsRecords() {
        let forbiddenKeys = ["sync.apiKey", "sync.token", "sync.secret", "sync.password"]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for key in forbiddenKeys {
            let json =
                #"{"key":"\#(key)","value":{"type":"string","value":"x"},"#
                + #""updatedAt":"2026-01-01T00:00:00Z","originDeviceID":"device"}"#
            XCTAssertThrowsError(try decoder.decode(SyncedSettingRecord.self, from: Data(json.utf8)))
        }
    }

    func testCredentialLikePromptIsRejected() {
        let sut = makeSUT()
        let result = sut.set(.string("use this API key sk-sensitive"), forKey: .postProcessingPrompt)

        XCTAssertNil(result)
        XCTAssertNil(sut.record(forKey: .postProcessingPrompt))
    }

    func testTransportAllowlistExcludesMetadataAndCredentialLikeKeys() {
        let forbiddenFragments = ["apikey", "api_key", "token", "secret", "password"]
        for key in SettingsSync.SyncKey.allCases {
            let lower = key.rawValue.lowercased()
            XCTAssertFalse(forbiddenFragments.contains(where: lower.contains))
        }

        let metadata = SyncedSettingRecord(
            key: .lastSyncTimestamp,
            value: .double(1),
            updatedAt: Date(timeIntervalSince1970: 1),
            originDeviceID: "device"
        )
        XCTAssertFalse(SettingsSync.isAllowed(record: metadata))
    }

    func testSettingsBatchAccumulatorConvergesDuplicateAndReorderedBatchesAtomically() {
        let requestID = UUID()
        let records = (0..<205).map { index in
            SyncedSettingRecord(
                key: SettingsSync.SyncKey.allCases[index % SettingsSync.SyncKey.allCases.count],
                value: .string("value-\(index)"),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                originDeviceID: "device"
            )
        }
        let batches = SettingsSyncBatchMessage.batches(requestID: requestID, records: records)
        var accumulator = SettingsBatchAccumulator()

        XCTAssertNil(accumulator.append(batches[1]))
        XCTAssertNil(accumulator.append(batches[1]))
        XCTAssertNil(accumulator.append(batches[2]))
        let assembled = accumulator.append(batches[0])

        XCTAssertEqual(assembled?.receivedBatchCount, 3)
        XCTAssertEqual(assembled?.snapshot.records, records)
    }

    func testSyncAvailability_prefersICloudWhenCloudKitAvailable() {
        let availability = SyncAvailability(
            iCloudKVStoreAvailable: false,
            iCloudCloudKitAvailable: true,
            transportAvailable: true
        )

        XCTAssertEqual(availability.preferredBackend, .iCloud)
    }

    func testSyncAvailability_fallsBackToTransportWhenICloudUnavailable() {
        let availability = SyncAvailability(
            iCloudKVStoreAvailable: false,
            iCloudCloudKitAvailable: false,
            transportAvailable: true
        )

        XCTAssertEqual(availability.preferredBackend, .transport)
    }

    func testSyncAvailability_usesLocalOnlyWhenNoBackendAvailable() {
        let availability = SyncAvailability(
            iCloudKVStoreAvailable: false,
            iCloudCloudKitAvailable: false,
            transportAvailable: false
        )

        XCTAssertEqual(availability.preferredBackend, .localOnly)
    }
}
