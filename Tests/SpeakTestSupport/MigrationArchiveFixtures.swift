import Foundation

public enum MigrationArchiveFixtures {
    public static let audio = Data("synthetic audio fixture".utf8)

    public static func url(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "zip", subdirectory: "MigrationArchiveFixtures"
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }
}
