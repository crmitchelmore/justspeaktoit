import Foundation
import SpeakCore
import SpeakDesktopHost
import XCTest

final class DesktopVoiceCredentialViewTests: XCTestCase {
    func testNativeMessages_RequirePurposeUUIDEpochAndExplicitRemovalWithoutASecret() throws {
        let id = UUID(), epoch = UUID()
        let save = try VoiceOutputCredentialMessage(
            operation: "replace", purpose: "voice-output", identifier: "cartesia.apiKey",
            requestID: id.uuidString, selectionEpoch: epoch.uuidString, key: "synthetic")
        guard case .save(let key, let request) = save else { return XCTFail("Missing typed save") }
        XCTAssertEqual(key, "synthetic")
        XCTAssertEqual(request.id, id)
        XCTAssertEqual(request.selectionEpoch, epoch)
        XCTAssertEqual(request.operation, .replace)
        let remove = try VoiceOutputCredentialMessage(
            operation: "remove", purpose: "voice-output", identifier: request.identifier,
            requestID: id.uuidString, selectionEpoch: epoch.uuidString, key: "")
        guard case .save(let removed, let removal) = remove else { return XCTFail("Missing explicit removal") }
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(removal.operation, .remove)
        let invalid = [
            ("replace", "transcription", request.identifier, id.uuidString, epoch.uuidString, "synthetic"),
            ("replace", "voice-output", request.identifier, "invalid", epoch.uuidString, "synthetic"),
            ("replace", "voice-output", request.identifier, id.uuidString, "", "synthetic"),
            ("replace", "voice-output", "", id.uuidString, epoch.uuidString, "synthetic"),
            ("remove", "voice-output", request.identifier, id.uuidString, epoch.uuidString, "synthetic"),
            ("unknown", "voice-output", request.identifier, id.uuidString, epoch.uuidString, "synthetic"),
            ("open", "voice-output", "", id.uuidString, "", "synthetic"),
            ("cancel", "voice-output", request.identifier, id.uuidString, epoch.uuidString, "")
        ]
        for value in invalid {
            XCTAssertThrowsError(try VoiceOutputCredentialMessage(
                operation: value.0, purpose: value.1, identifier: value.2,
                requestID: value.3, selectionEpoch: value.4, key: value.5))
        }
        for operation in ["open", "cancel"] {
            let message = try VoiceOutputCredentialMessage(
                operation: operation, purpose: "voice-output", identifier: "",
                requestID: id.uuidString, selectionEpoch: "", key: "")
            switch message {
            case .open(let token), .cancel(let token): XCTAssertEqual(token, id)
            case .save: XCTFail("A presentation/cancellation request became a save")
            }
        }
    }

    func testNativeViews_DistinguishSavedMissingBusyAndUnknownWithoutReturningSecrets() throws {
        let slot = try VoiceOutputCredentialSlot(voice: .cartesia(CartesiaTTSCatalog.voices[0]))
        let epoch = UUID(), id = UUID()
        for saved in [false, true] {
            for canSave in [false, true] {
                let view = DesktopVoiceCredentialView(.success(.init(
                    slot: slot, selectionEpoch: epoch, hasSavedKey: saved, canSave: canSave)),
                    requestID: id, credentialStore: "Synthetic vault")
                XCTAssertEqual(view.saved, saved ? 1 : 0)
                XCTAssertEqual(view.canSave, canSave ? 1 : 0)
                XCTAssertEqual(view.identifier, "cartesia.apiKey")
                XCTAssertEqual(view.requestID, id.uuidString)
                XCTAssertEqual(view.selectionEpoch, epoch.uuidString)
                XCTAssertTrue(view.label.contains("Voice Output key"))
                XCTAssertTrue(view.status.contains(saved ? "A key is saved" : "No key is saved"))
                XCTAssertEqual(view.status.contains("Wait for"), !canSave)
                XCTAssertFalse(view.privacy.contains("synthetic-secret"))
            }
        }
        let failed = DesktopVoiceCredentialView(
            .failure(.readFailed), requestID: id, credentialStore: "Synthetic vault")
        XCTAssertEqual(failed.saved, -1)
        XCTAssertEqual(failed.canSave, 0)
        XCTAssertTrue(failed.identifier.isEmpty)
        XCTAssertTrue(failed.selectionEpoch.isEmpty)
        XCTAssertTrue(failed.status.contains("could not be checked"))
        XCTAssertFalse(failed.status.contains("No key is saved"))
    }
}
