import Foundation

public enum DesktopOwnedAppDataFileReadError: Error, LocalizedError {
    case invalidLocation
    case invalidRelativePath
    case unsafeDirectory
    case unsafeFile
    case exceedsByteBudget
    case changedSource
    case grewSource
    case insufficientIdentity
    case closeFailure(original: Error, cleanup: Error)

    public var errorDescription: String? {
        switch self {
        case .invalidLocation: return "An owned local application-data directory is required."
        case .invalidRelativePath: return "An owned application-data file requires a fixed relative path."
        case .unsafeDirectory: return "Application-data storage must be an owned non-linked directory."
        case .unsafeFile: return "An application-data source is linked, non-regular, or has unreadable ownership."
        case .exceedsByteBudget: return "An application-data source exceeds its byte budget."
        case .changedSource: return "An application-data source changed after its read."
        case .grewSource: return "An application-data source grew during its read."
        case .insufficientIdentity: return "Platform metadata cannot support strict application-data source binding."
        case .closeFailure(let original, let cleanup):
            return "\(original.localizedDescription) The application-data source could not be closed: "
                + cleanup.localizedDescription
        }
    }
}
