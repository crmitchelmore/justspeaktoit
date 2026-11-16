import Foundation

/// Validation shared by every "add a Hugging Face model" form, on every platform.
public enum HuggingFaceRepoInput {
    /// Whether the text names an `owner/repo` repository. Callers trim first
    /// when they submit, so a form can enable before trailing spaces are gone.
    public static func isValidRepoID(_ text: String) -> Bool {
        text.split(separator: "/").count == 2
    }
}
