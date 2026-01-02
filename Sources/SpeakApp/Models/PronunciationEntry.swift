import Foundation

/// Represents a custom pronunciation entry for TTS engines.
struct PronunciationEntry: Codable, Identifiable, Hashable {
    let id: UUID
    var word: String           // Original text to match
    var pronunciation: String  // How to pronounce (IPA or phonetic)
    var replacement: String?   // Simple text replacement alternative
    var category: String?      // e.g., "Technical", "Names", "Acronyms"
    var isRegex: Bool          // Whether word should be treated as a regex pattern
    var caseSensitive: Bool    // Whether matching should be case-sensitive

    init(
        id: UUID = UUID(),
        word: String,
        pronunciation: String,
        replacement: String? = nil,
        category: String? = nil,
        isRegex: Bool = false,
        caseSensitive: Bool = false
    ) {
        self.id = id
        self.word = word
        self.pronunciation = pronunciation
        self.replacement = replacement
        self.category = category
        self.isRegex = isRegex
        self.caseSensitive = caseSensitive
    }

    /// Commonly used categories for pronunciation entries.
    enum Category: String, CaseIterable, Identifiable {
        case technical = "Technical"
        case names = "Names"
        case acronyms = "Acronyms"
        case symbols = "Symbols"
        case brands = "Brands"
        case medical = "Medical"
        case custom = "Custom"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .technical: return "gearshape"
            case .names: return "person.fill"
            case .acronyms: return "textformat.abc"
            case .symbols: return "number"
            case .brands: return "building.2"
            case .medical: return "cross.case"
            case .custom: return "pencil"
            }
        }
    }
}

// MARK: - Default Entries

extension PronunciationEntry {
    /// Pre-populated common pronunciation entries.
    static let defaultEntries: [PronunciationEntry] = [
        // Technical terms
        PronunciationEntry(
            word: "API",
            pronunciation: "A P I",
            replacement: "A P I",
            category: Category.technical.rawValue
        ),
        PronunciationEntry(
            word: "SQL",
            pronunciation: "sequel",
            replacement: "sequel",
            category: Category.technical.rawValue
        ),
        PronunciationEntry(
            word: "iOS",
            pronunciation: "eye OS",
            replacement: "eye OS",
            category: Category.technical.rawValue
        ),
        PronunciationEntry(
            word: "macOS",
            pronunciation: "mac OS",
            replacement: "mac OS",
            category: Category.technical.rawValue
        ),
        PronunciationEntry(
            word: "CLI",
            pronunciation: "C L I",
            replacement: "C L I",
            category: Category.technical.rawValue
        ),
        PronunciationEntry(
            word: "GUI",
            pronunciation: "gooey",
            replacement: "gooey",
            category: Category.technical.rawValue
        ),
        PronunciationEntry(
            word: "JSON",
            pronunciation: "jay-son",
            replacement: "jason",
            category: Category.technical.rawValue
        ),
        PronunciationEntry(
            word: "YAML",
            pronunciation: "yam-el",
            replacement: "yamel",
            category: Category.technical.rawValue
        ),
        PronunciationEntry(
            word: "nginx",
            pronunciation: "engine-x",
            replacement: "engine X",
            category: Category.technical.rawValue
        ),
        PronunciationEntry(
            word: "kubectl",
            pronunciation: "cube-control",
            replacement: "cube control",
            category: Category.technical.rawValue
        ),

        // Names in tech
        PronunciationEntry(
            word: "Kubernetes",
            pronunciation: "koo-ber-net-ees",
            replacement: "koo ber nettees",
            category: Category.names.rawValue
        ),
        PronunciationEntry(
            word: "PostgreSQL",
            pronunciation: "post-gres-Q-L",
            replacement: "post gres Q L",
            category: Category.names.rawValue
        ),
        PronunciationEntry(
            word: "MySQL",
            pronunciation: "my-S-Q-L",
            replacement: "my S Q L",
            category: Category.names.rawValue
        ),
        PronunciationEntry(
            word: "Xcode",
            pronunciation: "ex-code",
            replacement: "ex code",
            category: Category.names.rawValue
        ),

        // Acronyms
        PronunciationEntry(
            word: "URL",
            pronunciation: "U R L",
            replacement: "U R L",
            category: Category.acronyms.rawValue
        ),
        PronunciationEntry(
            word: "HTTP",
            pronunciation: "H T T P",
            replacement: "H T T P",
            category: Category.acronyms.rawValue
        ),
        PronunciationEntry(
            word: "HTTPS",
            pronunciation: "H T T P S",
            replacement: "H T T P S",
            category: Category.acronyms.rawValue
        ),
        PronunciationEntry(
            word: "HTML",
            pronunciation: "H T M L",
            replacement: "H T M L",
            category: Category.acronyms.rawValue
        ),
        PronunciationEntry(
            word: "CSS",
            pronunciation: "C S S",
            replacement: "C S S",
            category: Category.acronyms.rawValue
        ),
        PronunciationEntry(
            word: "AWS",
            pronunciation: "A W S",
            replacement: "A W S",
            category: Category.acronyms.rawValue
        ),
        PronunciationEntry(
            word: "GCP",
            pronunciation: "G C P",
            replacement: "G C P",
            category: Category.acronyms.rawValue
        ),

        // Symbols
        PronunciationEntry(
            word: "@",
            pronunciation: "at",
            replacement: " at ",
            category: Category.symbols.rawValue
        ),
        PronunciationEntry(
            word: "#",
            pronunciation: "hashtag",
            replacement: " hashtag ",
            category: Category.symbols.rawValue
        ),
        PronunciationEntry(
            word: "&",
            pronunciation: "and",
            replacement: " and ",
            category: Category.symbols.rawValue
        ),
        PronunciationEntry(
            word: "->",
            pronunciation: "arrow",
            replacement: " arrow ",
            category: Category.symbols.rawValue
        ),
        PronunciationEntry(
            word: "=>",
            pronunciation: "arrow",
            replacement: " arrow ",
            category: Category.symbols.rawValue
        ),
        PronunciationEntry(
            word: "!=",
            pronunciation: "not equal",
            replacement: " not equal ",
            category: Category.symbols.rawValue
        ),
        PronunciationEntry(
            word: "==",
            pronunciation: "equals",
            replacement: " equals ",
            category: Category.symbols.rawValue
        ),

        // Brands
        PronunciationEntry(
            word: "GitHub",
            pronunciation: "git-hub",
            replacement: "git hub",
            category: Category.brands.rawValue
        ),
        PronunciationEntry(
            word: "GitLab",
            pronunciation: "git-lab",
            replacement: "git lab",
            category: Category.brands.rawValue
        ),
        PronunciationEntry(
            word: "OpenAI",
            pronunciation: "open A I",
            replacement: "open A I",
            category: Category.brands.rawValue
        ),
    ]
}
