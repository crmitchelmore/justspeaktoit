import Foundation
import SpeakCore

public enum MigrationPlannerFixtures {
    public static let changedID = "463AC06A-C058-6ADE-2D86-9B62E63BBF4F"
    public static let sharedID = "AF59691D-824B-56FC-A936-44F2A232250B"
    public static let linkedID = "89BA3905-1010-71DE-3DAF-E4E87BB371A4"
    public static let fallbackID = "036D8099-F3DA-16E3-00CD-05119A2304BA"
    public static let collisionID = "AB0F00A2-AE33-6A56-026B-30A493E819E8"

    // Independently generated SHA-256 vectors; this is not a digest implementation.
    public static func digest(_ data: Data) throws -> String {
        let vectors = [
            "session:changed": "463ac06ac0586ade2d869b62e63bbf4f116eed68caa14e1851ec3b3883e7e1ec",
            "session:shared": "af59691d824b56fca93644f2a232250b252a3571a7860adc4b0c5816bc4fd9e0",
            "session:linked": "89ba3905101071de3dafe4e87bb371a4926a9b3f1691310b3a5854f0f0efc3aa",
            "\"Changed\"": "85821ded8cd8c1c1aa00a327d06bf00595b1e3914c2e1efd4ea6144cadb45221",
            "\"Changed again\"": "8258373789735b3f7ed550a191e1bca995242faada781d05ebc4c920567310f0",
            "session:85821ded8cd8c1c1aa00a327d06bf00595b1e3914c2e1efd4ea6144cadb45221":
                "036d8099f3da16e300cd05119a2304baae4ac14ecdfa9edef7caa2d712ceeb92",
            "\(sharedID):8258373789735b3f7ed550a191e1bca995242faada781d05ebc4c920567310f0":
                "ab0f00a2ae336a56026b30a493e819e825c1fd86d1d9a3bcd69b2aa356e3656e"
        ]
        guard let input = String(data: data, encoding: .utf8), let result = vectors[input] else {
            throw DataMigrationError.invalid("Missing deterministic migration digest fixture.")
        }
        return result
    }
}
