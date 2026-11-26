import Foundation
import XCTest

@testable import SpeakCore

final class VoiceProfileStoreRecoveryPortableTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-profile-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testVoiceProfileValidation_RejectsMismatchedRemoteAndUnreservedLocalBindings() {
        let validClip = VoiceProfilePortableTests.makeClip()
        let consent = ConsentAttestation()

        let unreservedLocal = VoiceProfileEngineBinding(
            engineID: "custom-engine",
            engineDisplayName: "Custom",
            target: .localEmbedding(relativePath: "embeddings/custom.bin")
        )
        let badLocalProfile = VoiceProfile(
            name: "Voice",
            language: "en",
            clips: [validClip],
            consent: consent,
            engineBindings: ["custom-engine": unreservedLocal]
        )
        XCTAssertThrowsError(try badLocalProfile.validate()) {
            XCTAssertEqual($0 as? VoiceProfileValidationError, .invalidEngineBinding("custom-engine"))
        }

        let mismatchedRemote = VoiceProfileEngineBinding(
            engineID: "xai",
            engineDisplayName: "xAI",
            target: .remoteVoice(voiceID: "elevenlabs/foreign-1", providerDisplayName: "xAI")
        )
        let badRemoteProfile = VoiceProfile(
            name: "Voice",
            language: "en",
            clips: [validClip],
            consent: consent,
            engineBindings: ["xai": mismatchedRemote]
        )
        XCTAssertThrowsError(try badRemoteProfile.validate()) {
            XCTAssertEqual($0 as? VoiceProfileValidationError, .invalidEngineBinding("xai"))
        }
    }

    func testVoiceProfileStore_RejectsDuplicateProfileIDWithoutClobberingClips() throws {
        let store = VoiceProfileStore(directory: VoiceProfileStore.defaultDirectory(in: temporaryRoot))
        let profileID = UUID()
        let clipID = UUID()
        let firstInput = VoiceProfileStore.ClipInput(
            id: clipID,
            pcmBuffer: VoiceProfilePortableTests.makeSpeechBuffer(duration: 8.0, sampleRate: 24_000, withPauses: true),
            transcript: "Original",
            source: .recorded
        )
        let original = try store.createProfile(
            id: profileID, name: "Original", language: "en", clips: [firstInput], consent: ConsentAttestation()
        )
        let clipURL = try store.clipURL(for: original.clips[0], in: profileID)
        let originalWAV = try Data(contentsOf: clipURL)

        let duplicateInput = VoiceProfileStore.ClipInput(
            id: clipID,
            pcmBuffer: VoiceProfilePortableTests.makeSpeechBuffer(duration: 10.0, sampleRate: 24_000, withPauses: true),
            transcript: "Overwrite",
            source: .imported
        )
        XCTAssertThrowsError(
            try store.createProfile(
                id: profileID, name: "Duplicate", language: "en", clips: [duplicateInput], consent: ConsentAttestation()
            )
        )
        XCTAssertEqual(try Data(contentsOf: clipURL), originalWAV)
        XCTAssertEqual(try store.listProfiles(), [original])
    }

    func testVoiceProfileStore_RecoversPendingDeletionWithRemoteBindings() throws {
        let store = VoiceProfileStore(directory: VoiceProfileStore.defaultDirectory(in: temporaryRoot))
        let clip = VoiceProfileStore.ClipInput(
            pcmBuffer: VoiceProfilePortableTests.makeSpeechBuffer(duration: 8.0, sampleRate: 24_000, withPauses: true),
            transcript: "Clip A",
            source: .recorded
        )
        let created = try store.createProfile(
            name: "Clone Target", language: "en", clips: [clip], consent: ConsentAttestation()
        )
        let folder = try store.profileDirectory(for: created.id)
        let pendingDoc = VoiceProfileStore.StoreDocument(
            schemaVersion: 1,
            profiles: [],
            pendingDeletions: [
                VoiceProfileStore.PendingDeletion(
                    profileID: created.id,
                    profileName: created.name,
                    remoteBindings: [
                        VoiceProfileStore.PendingRemoteBinding(
                            engineID: "elevenlabs",
                            remoteVoiceID: "el-pending-9",
                            providerDisplayName: "ElevenLabs"
                        )
                    ]
                )
            ]
        )
        _ = try store.saveDocument(pendingDoc)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        let resumed = try store.deleteProfile(id: created.id)
        XCTAssertEqual(resumed.remoteBindings.map(\.remoteVoiceID), ["el-pending-9"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertThrowsError(try store.deleteProfile(id: created.id)) {
            XCTAssertEqual($0 as? VoiceProfileStoreError, .profileNotFound(created.id))
        }
    }
}
