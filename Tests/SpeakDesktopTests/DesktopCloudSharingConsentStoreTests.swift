import Foundation
import XCTest
import SpeakCore
@testable import SpeakDesktop

final class DesktopCloudSharingConsentStoreTests: XCTestCase {
    private var directory: URL!
    private var writes = 0

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("consent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        writes = 0
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func store(failing: Bool = false) -> DesktopCloudSharingConsentStore {
        DesktopCloudSharingConsentStore(directory: directory) { [self] data, url in
            if failing { throw CocoaError(.fileWriteNoPermission) }
            writes += 1
            try data.write(to: url, options: .atomic)
        }
    }

    private func request(_ credential: String, _ kind: CloudSharedDataKind = .audio) -> CloudSharingRequest {
        CloudSharingConsent.request(credentialIdentifier: credential, providerName: "Provider", kind: kind)
    }

    func testNothingIsAllowedOnAFreshComputer() {
        let fresh = store()
        XCTAssertEqual(fresh.missing([request("openai")]).map(\.provider.id), ["openai"])
    }

    func testGrantIsPersistedAndSurvivesANewStore() throws {
        try store().grant([request("openai")])
        XCTAssertTrue(store().missing([request("openai")]).isEmpty)
        XCTAssertEqual(store().missing([request("openai", .textToSpeak)]).map(\.provider.id), ["openai"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(DesktopCloudSharingConsentStore.fileName).path))
    }

    func testWithdrawOneProviderLeavesTheOthers() throws {
        let value = store()
        try value.grant([request("openai"), request("groq")])
        try value.withdraw(providerID: "openai")
        XCTAssertEqual(store().missing([request("openai"), request("groq")]).map(\.provider.id), ["openai"])
        try value.withdrawAll()
        XCTAssertEqual(store().consent.allowedRequests.count, 0)
    }

    func testACorruptFileFailsClosed() throws {
        try Data("not json".utf8).write(to: directory.appendingPathComponent(DesktopCloudSharingConsentStore.fileName))
        XCTAssertEqual(store().missing([request("openai")]).map(\.provider.id), ["openai"])
    }

    func testAFailedWriteDoesNotAllowAnything() {
        let value = store(failing: true)
        XCTAssertThrowsError(try value.grant([request("openai")]))
        XCTAssertEqual(value.missing([request("openai")]).map(\.provider.id), ["openai"],
                       "a send never relies on consent that was not saved")
    }

    func testTheFileStaysInsideTheDirectory() throws {
        try store().grant([request("openai")])
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names, [DesktopCloudSharingConsentStore.fileName])
    }
}
