import CloudKit
import CryptoKit
import SpeakCore
import XCTest
@testable import SpeakSync

// The behavioral scenarios share one deterministic harness so their race ordering stays explicit.
// swiftlint:disable file_length

@MainActor
// swiftlint:disable:next type_body_length
final class CloudKitKeySyncTests: XCTestCase {
    func testSyncableIdentifiers_containsXAI() {
        XCTAssertTrue(CloudKitKeySync.syncableIdentifiers.contains("xai.apiKey"))
    }

    func testEncryptDecryptRoundTripWithCorrectPassphrase() throws {
        let salt = Data("stable-test-salt".utf8)
        let key = EncryptedSecretCrypto.deriveKey(passphrase: "correct horse battery staple", salt: salt)
        let updatedAt = Date(timeIntervalSince1970: 1_720_000_000)

        let encrypted = try EncryptedSecretCrypto.encryptSecret(
            identifier: "openai.apiKey",
            value: "secret-value",
            updatedAt: updatedAt,
            key: key
        )

        let decrypted = try EncryptedSecretCrypto.decryptSecret(encrypted, key: key)
        XCTAssertEqual(decrypted, "secret-value")
        XCTAssertEqual(encrypted.identifier, "openai.apiKey")
        XCTAssertEqual(encrypted.updatedAt, updatedAt)
    }

    func testDecryptFailsWithIncorrectPassphrase() throws {
        let salt = Data("stable-test-salt".utf8)
        let correctKey = EncryptedSecretCrypto.deriveKey(passphrase: "correct", salt: salt)
        let wrongKey = EncryptedSecretCrypto.deriveKey(passphrase: "incorrect", salt: salt)
        let encrypted = try EncryptedSecretCrypto.encryptSecret(
            identifier: "deepgram.apiKey",
            value: "secret-value",
            updatedAt: Date(),
            key: correctKey
        )

        XCTAssertThrowsError(try EncryptedSecretCrypto.decryptSecret(encrypted, key: wrongKey))
    }

    func testEncryptedSecretRecordRoundTrip() {
        let updatedAt = Date(timeIntervalSince1970: 1_720_000_001)
        let secret = EncryptedSecret(
            identifier: "assemblyai.apiKey",
            ciphertext: Data([1, 2, 3]),
            nonce: Data([4, 5, 6]),
            tag: Data([7, 8, 9]),
            updatedAt: updatedAt,
            isDeleted: true
        )

        let record = EncryptedSecretRecordMapper.record(from: secret)
        let mapped = EncryptedSecretRecordMapper.secret(from: record)

        XCTAssertEqual(record.recordType, EncryptedSecretRecordMapper.recordType)
        XCTAssertEqual(record.recordID.recordName, EncryptedSecretRecordMapper.recordName(for: secret.identifier))
        XCTAssertEqual(mapped, secret)
    }

    func testDeriveKeyOffMainActor_MatchesSynchronousDerivation() async {
        let salt = Data("stable-test-salt".utf8)
        let expected = EncryptedSecretCrypto.deriveKey(
            passphrase: "correct horse battery staple",
            salt: salt
        )
        let actual = await EncryptedSecretCrypto.deriveKeyOffMainActor(
            passphrase: "correct horse battery staple",
            salt: salt
        )

        XCTAssertEqual(
            expected.withUnsafeBytes { Data($0) },
            actual.withUnsafeBytes { Data($0) }
        )
    }

    func testPendingMutation_CodableRoundTripsDeletion() throws {
        let mutation = PendingKeySyncMutation(
            operationID: UUID(uuidString: "E30F13E5-8DAB-4D46-8BD1-5566B3D72893")!,
            identifier: "openai.apiKey",
            updatedAt: Date(timeIntervalSince1970: 1_720_000_002),
            kind: .deletion
        )

        let encoded = try JSONEncoder().encode(mutation)
        let decoded = try JSONDecoder().decode(PendingKeySyncMutation.self, from: encoded)

        XCTAssertEqual(decoded, mutation)
    }

    func testPBKDF2SHA256_MatchesIndependentKnownAnswerVector() {
        let derived = EncryptedSecretCrypto.pbkdf2SHA256(
            password: Data("password".utf8),
            salt: Data("salt".utf8),
            iterations: 4_096,
            keyByteCount: 32
        )

        XCTAssertEqual(
            derived.map { String(format: "%02x", $0) }.joined(),
            "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a"
        )
    }

    func testRepeatedLocalChanges_CoalesceIntoOneUpload() async throws {
        let harness = makeHarness()
        let isAvailable = await harness.sync.isAvailable()
        XCTAssertTrue(isAvailable)
        let firstDate = Date(timeIntervalSince1970: 1_720_100_001)
        let secondDate = Date(timeIntervalSince1970: 1_720_100_002)
        await harness.secrets.set("latest", identifier: "openai.apiKey")

        postLocalChange(harness, identifier: "openai.apiKey", updatedAt: firstDate)
        try await eventually { await harness.sleeper.waiterCount == 1 }
        postLocalChange(harness, identifier: "openai.apiKey", updatedAt: secondDate)
        await harness.sleeper.resumeNext()
        try await eventually { await harness.sleeper.waiterCount == 1 }
        await harness.sleeper.resumeNext()

        try await eventually { harness.cloud.savedRecords.count == 1 }
        let saved = try XCTUnwrap(EncryptedSecretRecordMapper.secret(from: harness.cloud.savedRecords[0]))
        XCTAssertEqual(saved.updatedAt, secondDate)
        XCTAssertEqual(try EncryptedSecretCrypto.decryptSecret(saved, key: harness.key), "latest")
        let journalKey = pendingKey("openai.apiKey")
        try await eventually { harness.defaults.data(forKey: journalKey) == nil }
        XCTAssertNil(harness.defaults.data(forKey: journalKey))
    }

    func testFailedDeletion_RemainsJournaledAndRetries() async throws {
        let harness = makeHarness()
        let isAvailable = await harness.sync.isAvailable()
        XCTAssertTrue(isAvailable)
        harness.cloud.saveFailuresRemaining = 1
        let updatedAt = Date(timeIntervalSince1970: 1_720_100_003)

        postLocalChange(
            harness,
            identifier: "deepgram.apiKey",
            operation: "remove",
            updatedAt: updatedAt
        )
        try await eventually { await harness.sleeper.waiterCount == 1 }
        await harness.sleeper.resumeNext()
        try await eventually { harness.cloud.saveAttempts == 1 }
        XCTAssertNotNil(harness.defaults.data(forKey: pendingKey("deepgram.apiKey")))

        try await eventually { await harness.sleeper.waiterCount == 1 }
        await harness.sleeper.resumeNext()
        try await eventually { await harness.sleeper.waiterCount == 1 }
        await harness.sleeper.resumeNext()

        try await eventually { harness.cloud.savedRecords.count == 1 }
        let saved = try XCTUnwrap(EncryptedSecretRecordMapper.secret(from: harness.cloud.savedRecords[0]))
        XCTAssertTrue(saved.isDeleted)
        XCTAssertEqual(saved.updatedAt, updatedAt)
        let journalKey = pendingKey("deepgram.apiKey")
        try await eventually { harness.defaults.data(forKey: journalKey) == nil }
        XCTAssertNil(harness.defaults.data(forKey: journalKey))
    }

    func testFailedUpdate_RemainsJournaledAndRetries() async throws {
        let harness = makeHarness()
        let isAvailable = await harness.sync.isAvailable()
        XCTAssertTrue(isAvailable)
        harness.cloud.saveFailuresRemaining = 1
        await harness.secrets.set("retry-value", identifier: "openai.apiKey")

        postLocalChange(
            harness,
            identifier: "openai.apiKey",
            updatedAt: Date(timeIntervalSince1970: 1_720_100_003.5)
        )
        try await eventually { await harness.sleeper.waiterCount == 1 }
        await harness.sleeper.resumeNext()
        try await eventually { harness.cloud.saveAttempts == 1 }
        let journalKey = pendingKey("openai.apiKey")
        XCTAssertNotNil(harness.defaults.data(forKey: journalKey))

        try await eventually { await harness.sleeper.waiterCount == 1 }
        await harness.sleeper.resumeNext()
        try await eventually { await harness.sleeper.waiterCount == 1 }
        await harness.sleeper.resumeNext()

        try await eventually { harness.cloud.savedRecords.count == 1 }
        let saved = try XCTUnwrap(EncryptedSecretRecordMapper.secret(from: harness.cloud.savedRecords[0]))
        XCTAssertFalse(saved.isDeleted)
        XCTAssertEqual(try EncryptedSecretCrypto.decryptSecret(saved, key: harness.key), "retry-value")
        try await eventually { harness.defaults.data(forKey: journalKey) == nil }
    }

    func testNewerMutation_SurvivesOlderUploadCompletion() async throws {
        let harness = makeHarness()
        let isAvailable = await harness.sync.isAvailable()
        XCTAssertTrue(isAvailable)
        let saveGate = TestGate()
        harness.cloud.saveGate = saveGate
        await harness.secrets.set("first", identifier: "openai.apiKey")
        let firstDate = Date(timeIntervalSince1970: 1_720_100_004)
        let secondDate = Date(timeIntervalSince1970: 1_720_100_005)

        postLocalChange(harness, identifier: "openai.apiKey", updatedAt: firstDate)
        try await eventually { await harness.sleeper.waiterCount == 1 }
        await harness.sleeper.resumeNext()
        try await eventually { await saveGate.waiterCount == 1 }

        await harness.secrets.set("second", identifier: "openai.apiKey")
        postLocalChange(harness, identifier: "openai.apiKey", updatedAt: secondDate)
        await saveGate.open()
        try await eventually { await harness.sleeper.waiterCount == 1 }
        XCTAssertNotNil(harness.defaults.data(forKey: pendingKey("openai.apiKey")))
        harness.cloud.saveGate = nil
        await harness.sleeper.resumeNext()

        try await eventually { harness.cloud.savedRecords.count == 2 }
        let saved = try XCTUnwrap(EncryptedSecretRecordMapper.secret(from: harness.cloud.savedRecords[1]))
        XCTAssertEqual(saved.updatedAt, secondDate)
        XCTAssertEqual(try EncryptedSecretCrypto.decryptSecret(saved, key: harness.key), "second")
        let journalKey = pendingKey("openai.apiKey")
        try await eventually { harness.defaults.data(forKey: journalKey) == nil }
        XCTAssertNil(harness.defaults.data(forKey: journalKey))
    }

    func testRemoteApplyFailure_DoesNotAdvanceChangeToken() async throws {
        let harness = makeHarness()
        let oldToken = Data("old-token".utf8)
        let newToken = Data("new-token".utf8)
        harness.defaults.set(oldToken, forKey: CloudKitKeySync.syncTokenKey)
        await harness.secrets.failNextStore()
        harness.cloud.fetchResults = [.success(KeySyncFetchResult(
            records: [try remoteRecord(
                identifier: "openai.apiKey",
                value: "remote",
                updatedAt: Date(timeIntervalSince1970: 1_720_100_006),
                key: harness.key
            )],
            deletedIDs: [],
            serverChangeTokenData: newToken,
            moreComing: false
        ))]

        await XCTAssertThrowsErrorAsync { try await harness.sync.syncNow() }
        XCTAssertEqual(harness.defaults.data(forKey: CloudKitKeySync.syncTokenKey), oldToken)
    }

    func testExpiredChangeToken_RetriesExactlyOnceWithoutToken() async throws {
        let harness = makeHarness()
        let oldToken = Data("expired-token".utf8)
        let newToken = Data("replacement-token".utf8)
        harness.defaults.set(oldToken, forKey: CloudKitKeySync.syncTokenKey)
        harness.cloud.fetchResults = [
            .failure(CKError(.changeTokenExpired)),
            .success(KeySyncFetchResult(
                records: [],
                deletedIDs: [],
                serverChangeTokenData: newToken,
                moreComing: false
            ))
        ]

        try await harness.sync.syncNow()

        XCTAssertEqual(harness.cloud.fetchTokens, [oldToken, nil])
        XCTAssertEqual(harness.defaults.data(forKey: CloudKitKeySync.syncTokenKey), newToken)
    }

    func testDisable_CancelsInFlightFetchBeforeWritesOrTokenCommit() async throws {
        let harness = makeHarness()
        let fetchGate = TestGate()
        harness.cloud.fetchGate = fetchGate
        let token = Data("must-not-commit".utf8)
        harness.cloud.fetchResults = [.success(KeySyncFetchResult(
            records: [try remoteRecord(
                identifier: "openai.apiKey",
                value: "remote",
                updatedAt: Date(timeIntervalSince1970: 1_720_100_007),
                key: harness.key
            )],
            deletedIDs: [],
            serverChangeTokenData: token,
            moreComing: false
        ))]

        let syncTask = Task { try await harness.sync.syncNow() }
        try await eventually { await fetchGate.waiterCount == 1 }
        let disableTask = Task { await harness.sync.disable() }
        await fetchGate.open()
        _ = try? await syncTask.value
        await disableTask.value

        XCTAssertFalse(harness.defaults.bool(forKey: CloudKitKeySync.enabledKey))
        XCTAssertNil(harness.defaults.data(forKey: CloudKitKeySync.syncTokenKey))
        let storedValue = try? await harness.secrets.secret(identifier: "openai.apiKey")
        XCTAssertNil(storedValue)
    }

    func testAccountChange_ClearsAccountStateAndCancelsInFlightSync() async throws {
        let harness = makeHarness(accountName: "first-account")
        let fetchGate = TestGate()
        harness.cloud.fetchGate = fetchGate
        harness.cloud.fetchResults = [.success(KeySyncFetchResult(
            records: [],
            deletedIDs: [],
            serverChangeTokenData: Data("stale-token".utf8),
            moreComing: false
        ))]
        let pending = PendingKeySyncMutation(
            operationID: UUID(),
            identifier: "openai.apiKey",
            updatedAt: Date(timeIntervalSince1970: 1_720_100_010),
            kind: .update
        )
        harness.defaults.set(
            try JSONEncoder().encode(pending),
            forKey: CloudKitKeySync.pendingMutationKey(identifier: "openai.apiKey")
        )

        let syncTask = Task { try await harness.sync.syncNow() }
        try await eventually { await fetchGate.waiterCount == 1 }
        harness.cloud.accountName = "second-account"
        harness.notifications.post(name: .CKAccountChanged, object: nil)
        await fetchGate.open()
        _ = try? await syncTask.value

        try await eventually {
            harness.defaults.string(forKey: CloudKitKeySync.accountIdentifierKey)
                == accountFingerprint("second-account")
        }
        XCTAssertFalse(harness.defaults.bool(forKey: CloudKitKeySync.enabledKey))
        XCTAssertNil(harness.defaults.data(forKey: CloudKitKeySync.pendingMutationKey(identifier: "openai.apiKey")))
        XCTAssertNil(harness.defaults.data(forKey: CloudKitKeySync.syncTokenKey))
    }

    func testNewerRemoteSecret_SupersedesPendingLocalMutation() async throws {
        let harness = makeHarness()
        let localDate = Date(timeIntervalSince1970: 1_720_100_008)
        let remoteDate = Date(timeIntervalSince1970: 1_720_100_009)
        let mutation = PendingKeySyncMutation(
            operationID: UUID(),
            identifier: "openai.apiKey",
            updatedAt: localDate,
            kind: .update
        )
        harness.defaults.set(try JSONEncoder().encode(mutation), forKey: pendingKey("openai.apiKey"))
        await harness.secrets.set("local", identifier: "openai.apiKey")
        harness.cloud.fetchResults = [.success(KeySyncFetchResult(
            records: [try remoteRecord(
                identifier: "openai.apiKey",
                value: "remote",
                updatedAt: remoteDate,
                key: harness.key
            )],
            deletedIDs: [],
            serverChangeTokenData: Data("new-token".utf8),
            moreComing: false
        ))]

        try await harness.sync.syncNow()

        let storedValue = try await harness.secrets.secret(identifier: "openai.apiKey")
        XCTAssertEqual(storedValue, "remote")
        XCTAssertTrue(harness.cloud.savedRecords.isEmpty)
        XCTAssertNil(harness.defaults.data(forKey: pendingKey("openai.apiKey")))
    }

    func testPagedRemoteChanges_AppliesEveryPageAndAdvancesTokens() async throws {
        let harness = makeHarness()
        let firstToken = Data("first-page-token".utf8)
        let finalToken = Data("final-page-token".utf8)
        harness.cloud.fetchResults = [
            .success(KeySyncFetchResult(
                records: [try remoteRecord(
                    identifier: "openai.apiKey",
                    value: "first-page",
                    updatedAt: Date(timeIntervalSince1970: 1_720_100_011),
                    key: harness.key
                )],
                deletedIDs: [],
                serverChangeTokenData: firstToken,
                moreComing: true
            )),
            .success(KeySyncFetchResult(
                records: [try remoteRecord(
                    identifier: "deepgram.apiKey",
                    value: "second-page",
                    updatedAt: Date(timeIntervalSince1970: 1_720_100_012),
                    key: harness.key
                )],
                deletedIDs: [],
                serverChangeTokenData: finalToken,
                moreComing: false
            ))
        ]

        try await harness.sync.syncNow()

        XCTAssertEqual(harness.cloud.fetchTokens, [nil, firstToken])
        let firstValue = try await harness.secrets.secret(identifier: "openai.apiKey")
        let secondValue = try await harness.secrets.secret(identifier: "deepgram.apiKey")
        XCTAssertEqual(firstValue, "first-page")
        XCTAssertEqual(secondValue, "second-page")
        XCTAssertEqual(harness.defaults.data(forKey: CloudKitKeySync.syncTokenKey), finalToken)
    }

    func testDisable_PromptlyCancelsStalledProductionFetch() async throws {
        let fetchOperation = FakeFetchOperation()
        let harness = makeHarness(fetchOperation: { _, _ in fetchOperation })

        let syncTask = Task { try await harness.sync.syncNow() }
        try await eventually { fetchOperation.runCount == 1 }

        // The fake never completes on its own and ignores cancel(), modelling a
        // stalled network operation. Without the cancellation handler this await
        // would hang on the in-flight fetch.
        await harness.sync.disable()

        XCTAssertGreaterThanOrEqual(fetchOperation.cancelCount, 1)
        _ = try? await syncTask.value
        XCTAssertFalse(harness.defaults.bool(forKey: CloudKitKeySync.enabledKey))
        XCTAssertNil(harness.defaults.data(forKey: CloudKitKeySync.syncTokenKey))
    }

    func testFetchCancellation_RacingCompletion_DoesNotDoubleResume() async throws {
        let fetchOperation = FakeFetchOperation()
        fetchOperation.completesOnCancel = true
        let harness = makeHarness(fetchOperation: { _, _ in fetchOperation })

        let syncTask = Task { try await harness.sync.syncNow() }
        try await eventually { fetchOperation.runCount == 1 }

        // cancel() invokes the CloudKit completion while the cancellation handler
        // resumes the gate itself; a late completion afterwards must be ignored.
        // A double resume of the checked continuation would crash the test run.
        await harness.sync.disable()
        fetchOperation.complete(with: .success(()))
        fetchOperation.complete(with: .failure(CKError(.networkFailure)))

        _ = try? await syncTask.value
        XCTAssertGreaterThanOrEqual(fetchOperation.cancelCount, 1)
        XCTAssertFalse(harness.defaults.bool(forKey: CloudKitKeySync.enabledKey))
    }

    func testProductionFetchBridge_CompletesNormally() async throws {
        let fetchOperation = FakeFetchOperation()
        let harness = makeHarness(fetchOperation: { _, _ in fetchOperation })

        let syncTask = Task { try await harness.sync.syncNow() }
        try await eventually { fetchOperation.runCount == 1 }
        fetchOperation.complete(with: .success(()))

        try await syncTask.value

        XCTAssertEqual(fetchOperation.cancelCount, 0)
        XCTAssertEqual(fetchOperation.runCount, 1)
    }

    func testAwaitFetchCompletion_CancelledBeforeStart_NeverRunsOperation() async throws {
        let fetchOperation = FakeFetchOperation()
        let task = Task {
            // Enter the bridge only once cancellation is already observed so the
            // pre-add check is what rejects the fetch.
            while !Task.isCancelled { await Task.yield() }
            try await CloudKitKeySync.awaitFetchCompletion(of: fetchOperation)
        }

        task.cancel()

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(fetchOperation.runCount, 0)
    }

    func testSleeperCancellation_ResumesTheMatchingWaiter() async throws {
        let sleeper = TestSleeper()
        let sleepTask = Task { try await sleeper.sleep(123) }
        try await eventually { await sleeper.waiterCount == 1 }

        sleepTask.cancel()

        do {
            try await sleepTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        try await eventually { await sleeper.waiterCount == 0 }
        let requestedNanoseconds = await sleeper.requestedNanoseconds
        XCTAssertEqual(requestedNanoseconds, [123])
    }
}

private extension CloudKitKeySyncTests {
    struct Harness {
        let sync: CloudKitKeySync
        let secrets: MemorySecretStorage
        let state: MemorySecretStorage
        let defaults: UserDefaults
        let notifications: NotificationCenter
        let cloud: FakeKeySyncCloud
        let sleeper: TestSleeper
        let key: SymmetricKey
    }

    func makeHarness(
        accountName: String = "test-account",
        fetchOperation: ((CloudKitKeySyncDatabase, Data?) -> any KeySyncFetchOperationRunning)? = nil
    ) -> Harness {
        let suiteName = "CloudKitKeySyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: CloudKitKeySync.enabledKey)
        defaults.set(accountFingerprint(accountName), forKey: CloudKitKeySync.accountIdentifierKey)
        let notifications = NotificationCenter()
        let cloud = FakeKeySyncCloud(accountName: accountName)
        let sleeper = TestSleeper()
        let secrets = MemorySecretStorage()
        let state = MemorySecretStorage()
        let key = SymmetricKey(data: Data(repeating: 7, count: 32))
        // When a fetch-operation seam is injected, leave `fetchChanges` nil so the
        // production continuation bridge (and its cancellation handling) runs.
        let fetchChanges: ((CloudKitKeySyncDatabase, Data?) async throws -> KeySyncFetchResult)? =
            fetchOperation == nil ? { _, token in try await cloud.fetch(token: token) } : nil
        let dependencies = CloudKitKeySyncDependencies(
            defaults: defaults,
            notificationCenter: notifications,
            now: { Date(timeIntervalSince1970: 1_720_199_999) },
            sleep: { try await sleeper.sleep($0) },
            hasCloudKitEntitlement: { true },
            privateDatabase: { cloud.database },
            accountStatus: { .available },
            accountRecordName: { cloud.accountName },
            setupInfrastructure: { _ in },
            fetchRecord: { id, _ in cloud.records[id.recordName] },
            saveRecord: { record, _ in try await cloud.save(record) },
            fetchChanges: fetchChanges,
            makeFetchOperation: fetchOperation
        )
        let sync = CloudKitKeySync(
            secureStorage: secrets,
            stateStorage: state,
            dependencies: dependencies,
            isConfigured: true,
            symmetricKey: key
        )
        return Harness(
            sync: sync,
            secrets: secrets,
            state: state,
            defaults: defaults,
            notifications: notifications,
            cloud: cloud,
            sleeper: sleeper,
            key: key
        )
    }

    func postLocalChange(
        _ harness: Harness,
        identifier: String,
        operation: String = "store",
        updatedAt: Date
    ) {
        harness.notifications.post(
            name: SecureStorage.didChangeSecretNotification,
            object: nil,
            userInfo: [
                SecureStorage.NotificationUserInfoKey.identifier: identifier,
                SecureStorage.NotificationUserInfoKey.operation: operation,
                SecureStorage.NotificationUserInfoKey.updatedAt: updatedAt
            ]
        )
    }

    func pendingKey(_ identifier: String) -> String {
        CloudKitKeySync.pendingMutationKey(identifier: identifier)
    }

    func remoteRecord(
        identifier: String,
        value: String,
        updatedAt: Date,
        key: SymmetricKey
    ) throws -> CKRecord {
        EncryptedSecretRecordMapper.record(from: try EncryptedSecretCrypto.encryptSecret(
            identifier: identifier,
            value: value,
            updatedAt: updatedAt,
            key: key
        ))
    }

    func eventually(
        attempts: Int = 2_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Condition was not satisfied after \(attempts) attempts", file: file, line: line)
        throw TestFailure.timedOut
    }
}

private enum TestFailure: Error {
    case injected
    case timedOut
}

private actor MemorySecretStorage: CloudKitKeySyncSecretStoring {
    private var values: [String: String] = [:]
    private var shouldFailNextStore = false

    func set(_ value: String, identifier: String) {
        values[identifier] = value
    }

    func failNextStore() {
        shouldFailNextStore = true
    }

    func storeSecret(_ value: String, identifier: String) async throws {
        if shouldFailNextStore {
            shouldFailNextStore = false
            throw TestFailure.injected
        }
        values[identifier] = value
    }

    func secret(identifier: String) async throws -> String {
        guard let value = values[identifier] else { throw SecureStorageError.valueNotFound }
        return value
    }

    func removeSecret(identifier: String) async throws {
        values[identifier] = nil
    }
}

@MainActor
private final class FakeKeySyncCloud {
    let database = CloudKitKeySyncDatabase(live: nil)
    var accountName: String
    var records: [String: CKRecord] = [:]
    var fetchResults: [Result<KeySyncFetchResult, Error>] = []
    var fetchTokens: [Data?] = []
    var savedRecords: [CKRecord] = []
    var saveAttempts = 0
    var saveFailuresRemaining = 0
    var saveGate: TestGate?
    var fetchGate: TestGate?

    init(accountName: String) {
        self.accountName = accountName
    }

    func save(_ record: CKRecord) async throws -> CKRecord {
        saveAttempts += 1
        if let saveGate { await saveGate.wait() }
        if saveFailuresRemaining > 0 {
            saveFailuresRemaining -= 1
            throw TestFailure.injected
        }
        savedRecords.append(record)
        records[record.recordID.recordName] = record
        return record
    }

    func fetch(token: Data?) async throws -> KeySyncFetchResult {
        fetchTokens.append(token)
        if let fetchGate { await fetchGate.wait() }
        guard !fetchResults.isEmpty else {
            return KeySyncFetchResult(
                records: [],
                deletedIDs: [],
                serverChangeTokenData: token,
                moreComing: false
            )
        }
        return try fetchResults.removeFirst().get()
    }
}

private final class FakeFetchOperation: KeySyncFetchOperationRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var storedCompletion: ((Result<Void, Error>) -> Void)?
    private var storedRunCount = 0
    private var storedCancelCount = 0
    private var storedCompletesOnCancel = false

    var runCount: Int { lock.withLock { storedRunCount } }
    var cancelCount: Int { lock.withLock { storedCancelCount } }
    var completesOnCancel: Bool {
        get { lock.withLock { storedCompletesOnCancel } }
        set { lock.withLock { storedCompletesOnCancel = newValue } }
    }

    func run(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        lock.withLock {
            storedRunCount += 1
            storedCompletion = completion
        }
    }

    func cancel() {
        let completion: ((Result<Void, Error>) -> Void)? = lock.withLock {
            storedCancelCount += 1
            guard storedCompletesOnCancel else { return nil }
            return storedCompletion
        }
        completion?(.failure(CKError(.operationCancelled)))
    }

    func complete(with result: Result<Void, Error>) {
        let completion = lock.withLock { storedCompletion }
        completion?(result)
    }
}

private actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiterCount: Int { waiters.count }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor TestSleeper {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var waiters: [Waiter] = []
    private(set) var requestedNanoseconds: [UInt64] = []

    var waiterCount: Int { waiters.count }

    func sleep(_ nanoseconds: UInt64) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                requestedNanoseconds.append(nanoseconds)
                waiters.append(Waiter(id: id, continuation: continuation))
                if Task.isCancelled {
                    cancelWaiter(id: id)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    func resumeNext() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume()
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

private func accountFingerprint(_ accountName: String) -> String {
    SHA256.hash(data: Data(accountName.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
