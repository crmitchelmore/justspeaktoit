import Foundation
import SpeakCore

extension DesktopVocabularyArchiveSource {
    public enum NativeDomainValidity: Equatable, Sendable {
        /// Valid/invalid refer only to the existing native decoder, not full-schema or credential validation.
        case absent, valid, invalid
    }

    /// Local evidence only. Native payloads remain unapplied, including when domain-valid.
    public struct SensitiveProjection: Sendable {
        public let records: [DataMigrationRecord]
        public let scope: DataMigrationScope
        public let selectedKinds: Set<String>
        public let collectionPresence: [String: Bool]
        public let nativeSourceIsPresent: Bool
        public let nativeDomainValidity: NativeDomainValidity
        public let nativeEvidence: DesktopNativeSourceDocument.Evidence?
        public var isCompleteCategory: Bool { false }
        public var hasApplyOrBackupAuthority: Bool { false }
    }
}

extension DesktopVocabularyArchiveSource.Snapshot {
    /// Sensitive opt-in is not backup admission. No source content or credential classification occurs here.
    public func projectWithSensitiveNativeEvidence(
        platform: DesktopNativeSourceDocument.Platform, allowSensitiveContent: Bool = false,
        scope: DataMigrationScope = .init(),
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> DesktopVocabularyArchiveSource.SensitiveProjection {
        let placeholder = try DesktopNativeSourceDocumentCodec.capture(
            platform: platform, source: .desktopVocabularyPreferences,
            rawBytes: unmappedPreferences.data.map { _ in Data() },
            allowSensitiveContent: allowSensitiveContent, checkCancellation: checkCancellation
        )
        var records = try compatibleRecords(scope: scope, checkCancellation: checkCancellation)
        let includeNative = scope.contains(
            id: placeholder.identity, date: nil, kind: DesktopNativeSourceDocumentCodec.recordKind
        )
        let header = try DesktopNativeSourceDocumentCodec.project(
            includeNative ? [placeholder] : [], allowSensitiveContent: true, checkCancellation: checkCancellation
        )
        let rawBytes = collections.reduce(UInt64(unmappedPreferences.data?.count ?? 0)) {
            $0 + UInt64($1.source.data?.count ?? 0)
        }
        try Self.requireSensitiveBudget(
            sourceBytes: rawBytes,
            encodedHeaderBytes: UInt64(DataMigrationCoding.encoder.encode(records + header.records).count),
            nativeBytes: includeNative ? UInt64(unmappedPreferences.data?.count ?? 0) : 0
        )
        try checkCancellation()
        var native: DesktopNativeSourceDocument.Evidence?
        if includeNative {
            let evidence = try DesktopNativeSourceDocumentCodec.capture(
                platform: platform, source: .desktopVocabularyPreferences, rawBytes: unmappedPreferences.data,
                allowSensitiveContent: true, checkCancellation: checkCancellation
            )
            native = evidence
            let projection = try DesktopNativeSourceDocumentCodec.project(
                [evidence], allowSensitiveContent: true, checkCancellation: checkCancellation
            )
            records += projection.records
        }
        try Self.requireSensitiveBudget(
            sourceBytes: rawBytes, encodedHeaderBytes: UInt64(DataMigrationCoding.encoder.encode(records).count),
            nativeBytes: 0
        )
        try revalidate(checkCancellation: checkCancellation)
        return .init(
            records: records,
            scope: .init(
                start: scope.start, end: scope.end, selectedIDs: scope.selectedIDs ?? Set(records.map(\.id)),
                selectedKinds: scope.selectedKinds
            ),
            selectedKinds: Set(collections.map(\.definition.kind).filter(scope.contains(kind:)))
                .union(includeNative ? header.selectedKinds : []),
            collectionPresence: Dictionary(uniqueKeysWithValues: collections.map {
                ($0.definition.kind, $0.source.data != nil)
            }),
            nativeSourceIsPresent: unmappedPreferences.data != nil,
            nativeDomainValidity: nativeDomainValidity, nativeEvidence: native
        )
    }

    static func requireSensitiveBudget(
        sourceBytes: UInt64, encodedHeaderBytes: UInt64, nativeBytes: UInt64
    ) throws {
        let maximum = DataMigrationArchivePolicy.maximumJSONBytes
        guard sourceBytes <= maximum, encodedHeaderBytes <= maximum - sourceBytes else {
            throw DataMigrationError.invalid("Sensitive vocabulary evidence exceeds the combined byte budget.")
        }
        let remaining = maximum - sourceBytes - encodedHeaderBytes
        guard nativeBytes <= sourceBytes, ((nativeBytes + 2) / 3) * 4 <= remaining else {
            throw DataMigrationError.invalid("Sensitive vocabulary evidence exceeds the combined byte budget.")
        }
    }
}
