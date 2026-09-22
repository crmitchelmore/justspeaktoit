import Foundation
import SpeakCore

/// Shared History search policy for desktop hosts. A query matches a record
/// when its folded text appears in the original transcript, the processed
/// transcript or the canonical friendly model name. The policy only decides
/// which records are visible and in what order; it never alters a record, its
/// identifier or its transcript contents.
public enum DesktopHistorySearch {
    /// Folds case, canonical diacritics and whitespace runs so "Café" matches
    /// "cafe", "CAFÉ" and "cafe\u{301}". Normalisation is deterministic and
    /// locale-independent, so every desktop host agrees on the same matches.
    public static func fold(_ text: String) -> String {
        var folded = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars {
            if scalar.properties.isWhitespace {
                pendingSpace = !folded.isEmpty
                continue
            }
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: continue
            default: break
            }
            if pendingSpace {
                folded.append(" ")
                pendingSpace = false
            }
            folded.append(scalar)
        }
        return String(folded)
    }

    /// The friendly name shown for a record's model. Search matches this name
    /// rather than the raw identifier, so hosts must display the same string.
    public static func modelDisplayName(for identifier: String) -> String {
        ModelCatalog.friendlyName(for: identifier)
    }

    /// Folded text a host can cache per record and reuse for every keystroke.
    /// Field boundaries are separated so a query cannot span two fields.
    public static func searchText(for record: DesktopRecordingStore.Record) -> String {
        [record.originalText, record.processedText, modelDisplayName(for: record.modelIdentifier)]
            .compactMap { $0 }
            .map(fold)
            .joined(separator: "\u{1F}")
    }

    /// Whether a query is active after folding; blank queries show everything.
    public static func isActive(_ query: String) -> Bool { !fold(query).isEmpty }

    public static func matches(query: String, searchText: String) -> Bool {
        let folded = fold(query)
        return folded.isEmpty || searchText.contains(folded)
    }

    /// Newest first. Equal timestamps fall back to the identifier so repeated
    /// refreshes and filtered subsets never reorder rows.
    public static func ordered(_ records: [DesktopRecordingStore.Record]) -> [DesktopRecordingStore.Record] {
        records.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Visible records for a query, in presentation order. `searchText` lets a
    /// host supply cached folded text; the default folds each record.
    public static func filter(
        _ records: [DesktopRecordingStore.Record],
        query: String,
        searchText: (DesktopRecordingStore.Record) -> String = searchText(for:)
    ) -> [DesktopRecordingStore.Record] {
        let folded = fold(query)
        let visible = folded.isEmpty ? records : records.filter { searchText($0).contains(folded) }
        return ordered(visible)
    }
}
