import Foundation

/// Finds `@Published` stored properties in Swift source for the settings coverage guards,
/// whatever their access modifiers and attributes: `@Published var`, `@Published public var`,
/// `@Published public private(set) var`, `@MainActor @Published var` and so on.
enum PublishedPropertyScanner {
    private static let regex: NSRegularExpression = {
        let modifier = #"(?:@\w+(?:\([^)]*\))?|open|public|package|internal|fileprivate|private"#
            + #"|nonisolated|final|override|dynamic|lazy|weak|unowned)(?:\(set\))?"#
        // swiftlint:disable:next force_try - constant pattern; a typo should fail every guard loudly.
        return try! NSRegularExpression(pattern: #"@Published(?:\s+"# + modifier + #")*\s+var\s+(\w+)"#)
    }()

    static func propertyNames(in source: String) -> [String] {
        regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        }
    }
}
