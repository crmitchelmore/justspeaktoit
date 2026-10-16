import SpeakCore

enum DesktopPronunciationCategories {
    static let marker = "pronunciationCategories.v1"

    static func fields(for entries: [PronunciationEntry]) -> [String] {
        var fields = [marker, String(entries.count)]
        for category in PronunciationEntry.Category.allCases {
            let count = entries.filter { $0.category == category.rawValue }.count
            if count > 0 { fields += [category.rawValue, String(count)] }
        }
        return fields
    }
}
