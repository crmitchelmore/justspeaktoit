import Foundation

/// Bounds parser work and rejects duplicate JSON members before Foundation can collapse them.
enum NativeConfigurationJSONScan {
    static func validate(_ data: Data, checkCancellation: () throws -> Void) throws {
        try JSONMemberPreflight.validate(
            data,
            limits: .init(
                maximumBytes: DesktopNativeConfigurationArchiveCodec.maximumEncodedBytes,
                maximumDepth: 8, maximumTokens: 4096,
                maximumRootRecords: DesktopNativeConfigurationArchiveCodec.maximumRecords,
                maximumObjectKeys: 32, maximumEncodedKeySpan: 512, cancellationStride: 4096
            ),
            checkCancellation: checkCancellation,
            invalid: { DataMigrationError.invalid("Malformed or unbounded native configuration JSON.") }
        )
    }
}
