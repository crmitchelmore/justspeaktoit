import Foundation

/// An internal commissioning control shared by native speech adapters.
///
/// This value permits one exact model/voice selection for an explicitly opted-in
/// caller. It does not certify provider format support or enable discovered
/// models. Existing adapter constructors retain disabled behavior.
public struct OpenRouterProgressiveSpeechOption: Equatable, Sendable {
    public static let disabled = Self(selectionID: nil)

    private let selectionID: String?

    private init(selectionID: String?) {
        self.selectionID = selectionID
    }

    /// Requires the existing canonical selection encoding; no model fallback or
    /// voice normalization broadens the caller's commissioning selection.
    public init?(selectionID: String) {
        guard OpenRouterSpeechSelection(id: selectionID) != nil else { return nil }
        self.selectionID = selectionID
    }

    public func allows(_ selection: OpenRouterSpeechSelection) -> Bool {
        // These identities are URL-safe Base64 ASCII. Comparing them preserves
        // distinct Unicode code units in provider model and voice identifiers.
        selectionID == selection.id
    }
}
