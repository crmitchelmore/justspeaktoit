import XCTest

@testable import SpeakCore

final class PairingManagerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var now: Date!

    override func setUp() {
        super.setUp()
        suiteName = "PairingManagerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        now = Date(timeIntervalSince1970: 1_750_000_000)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        suiteName = nil
        defaults = nil
        now = nil
        super.tearDown()
    }

    func testPairingCode_persistsUntilExpiry() {
        var codes = ["AAAAA-BBBBB", "CCCCC-DDDDD"]
        let manager = makeManager(codeGenerator: { codes.removeFirst() })

        XCTAssertEqual(manager.pairingCode, "AAAAA-BBBBB")
        XCTAssertEqual(manager.pairingCode, "AAAAA-BBBBB")
        XCTAssertTrue(manager.validatePairingCode("AAAAA-BBBBB"))

        now = now.addingTimeInterval(601)

        XCTAssertFalse(manager.validatePairingCode("AAAAA-BBBBB"))
        XCTAssertEqual(manager.pairingCode, "CCCCC-DDDDD")
        XCTAssertTrue(manager.validatePairingCode("CCCCC-DDDDD"))
    }

    func testRegeneratePairingCode_clearsPairedDevices() {
        var codes = ["AAAAA-BBBBB", "CCCCC-DDDDD"]
        let manager = makeManager(codeGenerator: { codes.removeFirst() })

        _ = manager.pairingCode
        manager.addPairedDevice(id: "ios-device", name: "iPhone")
        XCTAssertTrue(manager.isDevicePaired(id: "ios-device"))

        XCTAssertEqual(manager.regeneratePairingCode(), "CCCCC-DDDDD")
        XCTAssertFalse(manager.isDevicePaired(id: "ios-device"))
    }

    func testRotateAfterSuccessfulPairing_keepsPairedDevicesAndInvalidatesOldCode() {
        var codes = ["AAAAA-BBBBB", "CCCCC-DDDDD"]
        let manager = makeManager(codeGenerator: { codes.removeFirst() })

        XCTAssertEqual(manager.pairingCode, "AAAAA-BBBBB")
        manager.addPairedDevice(id: "ios-device", name: "iPhone")

        XCTAssertEqual(manager.rotateAfterSuccessfulPairing(), "CCCCC-DDDDD")

        XCTAssertFalse(manager.validatePairingCode("AAAAA-BBBBB"))
        XCTAssertTrue(manager.validatePairingCode("CCCCC-DDDDD"))
        XCTAssertTrue(manager.isDevicePaired(id: "ios-device"))
    }

    func testValidatePairingCode_normalisesCaseAndSeparators() {
        let manager = makeManager(codeGenerator: { "ABCDE-FGHIJ" })

        _ = manager.pairingCode

        XCTAssertTrue(manager.validatePairingCode("abcde fghij"))
        XCTAssertTrue(manager.validatePairingCode("ABCDE-FGHIJ"))
        XCTAssertFalse(manager.validatePairingCode("ABCDE-FGHIK"))
    }

    func testGeneratedPairingCode_hasExpectedEntropyShape() {
        let code = PairingManager.generateSecurePairingCode()
        let normalized = PairingManager.normalizedPairingCode(code)

        XCTAssertEqual(normalized.count, 10)
        XCTAssertEqual(code.count, 11)
        XCTAssertEqual(code[code.index(code.startIndex, offsetBy: 5)], "-")
        XCTAssertTrue(normalized.allSatisfy { $0.isUppercase || $0.isNumber })
    }

    private func makeManager(codeGenerator: @escaping () -> String) -> PairingManager {
        PairingManager(
            defaults: defaults,
            now: { self.now },
            codeLifetime: 600,
            codeGenerator: codeGenerator
        )
    }
}
