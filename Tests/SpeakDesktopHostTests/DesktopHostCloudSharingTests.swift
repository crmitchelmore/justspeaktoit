import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

/// What the fake host was asked to show, so the tests can answer as the user would.
final class CloudConsentRecorder: @unchecked Sendable {
    static let shared = CloudConsentRecorder()
    private let lock = NSLock()
    private var shown: [(id: UUID, prompt: DesktopCloudSharingPrompt)] = []
    private var published: [DesktopCloudSharingPresentation] = []
    private var canAsk = true

    func reset() { lock.withLock { shown = []; published = []; canAsk = true } }
    var prompts: [(id: UUID, prompt: DesktopCloudSharingPrompt)] { lock.withLock { shown } }
    var presentations: [DesktopCloudSharingPresentation] { lock.withLock { published } }
    var available: Bool {
        get { lock.withLock { canAsk } }
        set { lock.withLock { canAsk = newValue } }
    }

    func ask(id: UUID, prompt: DesktopCloudSharingPrompt) throws {
        try lock.withLock {
            guard canAsk else { throw DesktopHostError(message: "Synthetic host cannot show the question.") }
            shown.append((id, prompt))
        }
    }
    func present(_ presentation: DesktopCloudSharingPresentation) { lock.withLock { published.append(presentation) } }
}

extension FakePlatform {
    static func requestCloudSharingConsent(id: UUID, prompt: DesktopCloudSharingPrompt) throws {
        try CloudConsentRecorder.shared.ask(id: id, prompt: prompt)
    }
    static func presentCloudSharing(_ presentation: DesktopCloudSharingPresentation) {
        CloudConsentRecorder.shared.present(presentation)
    }
}

final class DesktopHostCloudSharingTests: XCTestCase {
    private var directory: URL!
    private var effects: SyntheticEffects!
    private var controller: DesktopHostController<FakePlatform>!
    private var batchIndex = 0
    private var providerID = ""
    private var consent: CloudConsentRecorder { .shared }

    override func setUp() async throws {
        FakeLog.shared.reset()
        consent.reset()
        DesktopHostModels.configure(streamingQualified: false)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("host-consent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        effects = SyntheticEffects()
        // Constructed directly: a new computer has allowed nothing.
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        await controller.markReadyForSelfTest()
        batchIndex = try XCTUnwrap(
            DesktopHostModels.all.firstIndex { DesktopTranscription.provider(for: $0.id) != nil }
        )
        let model = DesktopHostModels.all[batchIndex].id
        let credential = try XCTUnwrap(DesktopHostModels.provider(for: model)).apiKeyIdentifier
        FakeLog.shared.setKey("synthetic-key", name: credential)
        providerID = CloudSharingProviderCatalogue.providerID(forCredentialIdentifier: credential)
    }

    override func tearDown() async throws {
        await controller.close()
        try? FileManager.default.removeItem(at: directory)
        DesktopHostModels.configure(streamingQualified: true)
    }

    private func records() async throws -> [DesktopRecordingStore.Record] {
        try await DesktopRecordingStore(directory: directory.appendingPathComponent("History"))
            .recoverInterruptedRecordings().records
    }

    private func record(on host: DesktopHostController<FakePlatform>? = nil) async {
        await (host ?? controller).toggle(
            target: nil, modelIndex: batchIndex, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
    }

    func testFirstRecordingAsksBeforeAnythingIsCaptured() async throws {
        await record()
        let asked = try XCTUnwrap(consent.prompts.first)
        XCTAssertEqual(consent.prompts.count, 1)
        XCTAssertEqual(asked.prompt.entries.map(\.providerID), [providerID])
        XCTAssertFalse(asked.prompt.entries[0].detail.isEmpty)
        XCTAssertTrue(FakeLog.shared.allStatuses.contains { $0.hasPrefix("Choose Allow to share with") })
        let saved = try await records()
        XCTAssertTrue(saved.isEmpty, "nothing is recorded or uploaded before the user allows it")
    }

    func testAllowIsRememberedAcrossRecordingsAndRestarts() async throws {
        await record()
        let asked = try XCTUnwrap(consent.prompts.first)
        await controller.answerCloudSharing(asked.id.uuidString, allow: true)
        XCTAssertEqual(consent.presentations.last?.entries.map(\.providerID), [providerID])
        await record()
        let saved = try await records()
        XCTAssertEqual(saved.count, 1, "an allowed provider records without asking again")
        XCTAssertEqual(consent.prompts.count, 1)

        await controller.close()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
        do {
            try await controller.requireCloudSharing([
                DesktopHostCloudSharing.transcription(model: DesktopHostModels.all[batchIndex].id)
            ])
        } catch { XCTFail("an allowed provider asked again: \(error)") }
        XCTAssertEqual(consent.prompts.count, 1, "the answer survives a restart")
    }

    func testNotNowKeepsAskingAndAllowsNothing() async throws {
        await record()
        await controller.answerCloudSharing(try XCTUnwrap(consent.prompts.first).id.uuidString, allow: false)
        XCTAssertTrue(consent.presentations.isEmpty)
        await record()
        XCTAssertEqual(consent.prompts.count, 2)
        let saved = try await records()
        XCTAssertTrue(saved.isEmpty)
    }

    func testWithdrawingAProviderAsksAgainBeforeTheNextUpload() async throws {
        await record()
        await controller.answerCloudSharing(try XCTUnwrap(consent.prompts.first).id.uuidString, allow: true)
        await controller.withdrawCloudSharing(providerID: providerID)
        XCTAssertEqual(consent.presentations.last?.entries.count, 0)
        await record()
        XCTAssertEqual(consent.prompts.count, 2)
        let saved = try await records()
        XCTAssertTrue(saved.isEmpty)
    }

    func testAStaleAnswerIsRejectedAndAllowsNothing() async throws {
        await record()
        await controller.answerCloudSharing(UUID().uuidString, allow: true)
        XCTAssertTrue(FakeLog.shared.allStatuses.contains { $0.contains("no longer current") })
        XCTAssertTrue(consent.presentations.isEmpty)
        await record()
        XCTAssertEqual(consent.prompts.count, 2, "the stale answer granted nothing")
    }

    func testAHostThatCannotAskSendsNothing() async throws {
        consent.available = false
        await record()
        XCTAssertTrue(consent.prompts.isEmpty)
        let saved = try await records()
        XCTAssertTrue(saved.isEmpty)
    }

    func testAutomationNeverOpensTheQuestion() async throws {
        let request = DesktopHostCloudSharing.transcription(model: DesktopHostModels.all[batchIndex].id)
        do {
            try await controller.requireAutomationCloudSharing([request])
            XCTFail("automation sent without consent")
        } catch { XCTAssertTrue(error is AutomationError) }
        XCTAssertTrue(consent.prompts.isEmpty)
    }

    func testOnDeviceModelsAndLocalCleanupNeedNoConsent() async throws {
        DesktopHostModels.configure(streamingQualified: false, local: DesktopLocalTranscription.options(host: .linux))
        defer { DesktopHostModels.configure(streamingQualified: false, local: []) }
        let local = try XCTUnwrap(DesktopHostModels.local.first)
        XCTAssertNil(DesktopHostCloudSharing.transcription(model: local.id))
        try await controller.requireCloudSharing([nil])
        XCTAssertTrue(consent.prompts.isEmpty)
    }

    func testEachCloudWorkflowNamesItsOwnProviderAndData() throws {
        let transcription = try XCTUnwrap(
            DesktopHostCloudSharing.transcription(model: DesktopHostModels.all[batchIndex].id))
        XCTAssertEqual(transcription.kinds, [.audio])
        let voice = DesktopHostCloudSharing.voice(credentialIdentifier: "openai")
        XCTAssertEqual(voice.kinds, [.textToSpeak])
        XCTAssertEqual(voice.provider.id, "openai")
    }
}
