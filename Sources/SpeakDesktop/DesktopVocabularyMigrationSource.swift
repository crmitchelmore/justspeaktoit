import Foundation
import SpeakCore

enum DesktopVocabularyMigrationSource {
    static func read(
        _ path: String, root: URL, checkCancellation: () throws -> Void
    ) throws -> Data? {
        do {
            return try DesktopOwnedAppDataFileReader.read(
                path, appDirectory: root, maximumBytes: DataMigrationArchivePolicy.maximumJSONBytes,
                checkCancellation: checkCancellation
            )?.data
        } catch let error as DesktopOwnedAppDataFileReadError {
            throw vocabularyError(error)
        }
    }

    static func vocabularyError(_ error: DesktopOwnedAppDataFileReadError) -> Error {
        switch error {
        case .unsafeFile:
            return DataMigrationError.invalid(
                "A vocabulary source is linked, non-regular, or has unreadable ownership."
            )
        case .unsafeDirectory:
            return DataMigrationError.invalid("Vocabulary storage must be an owned non-linked directory.")
        case .exceedsByteBudget:
            return DataMigrationError.invalid("A vocabulary store exceeds the JSON size limit.")
        case .changedSource:
            return DataMigrationError.invalid("A vocabulary source changed during collection.")
        case .grewSource:
            return DataMigrationError.invalid("A vocabulary source grew during collection.")
        case .closeFailure(let original, let cleanup):
            let mapped = (original as? DesktopOwnedAppDataFileReadError).map(vocabularyError) ?? original
            return DataMigrationError.invalid(
                "\(mapped.localizedDescription) The vocabulary source could not be closed: "
                    + cleanup.localizedDescription
            )
        case .invalidLocation, .invalidRelativePath, .insufficientIdentity:
            return error
        }
    }
}
