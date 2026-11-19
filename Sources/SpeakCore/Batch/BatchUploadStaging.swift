import Foundation

/// Shared batch clients never select a weaker policy than the host supplied.
enum BatchUploadStaging {
    static func resolve(_ supplied: SharedMultipartUploadStaging?) throws -> SharedMultipartUploadStaging {
        if let supplied { return supplied }
        #if os(Windows)
        throw CocoaError(.fileWriteNoPermission)
        #else
        return .posixShared
        #endif
    }
}
