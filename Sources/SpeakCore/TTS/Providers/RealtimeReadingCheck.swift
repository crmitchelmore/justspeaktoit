import Foundation

/// Decides whether a Realtime response's own transcript is a verbatim reading of
/// its input. Android mirrors these rules in `RealtimeReading.kt`; change both.
///
/// The input is aligned with the transcript in order:
/// - every word must be spoken, so dropping one ("not") fails;
/// - an all-digit numeral is a slot that must be read as the same digits, or as
///   English number words that reproduce them ("2026" as "two thousand and
///   twenty six" or "twenty twenty six"), so "5" read as "six" fails. A reading
///   with no digits or English number words (another language) is accepted as
///   up to `maximumNumeralWords` words, never a negation;
/// - a token mixing letters and digits ("5kg", "1st") is that same bounded slot;
/// - spoken words that match nothing are allowed only for symbols read aloud
///   ("&" as "and", "$5" as "five dollars"), `wordsPerSymbol` each. Anything
///   more, such as an inserted "not", an answer or commentary, fails.
enum RealtimeReadingCheck {
    static let maximumNumeralWords = 8
    static let wordsPerSymbol = 2
    /// Longer digit runs are not parsed as numbers; they become bounded slots.
    static let maximumNumeralDigits = 15

    enum Token: Equatable {
        case word(String), number(String), mixed
    }

    static func isFaithful(expected: String, spoken: String) -> Bool {
        let tokens = words(expected).map(token)
        let heard = words(spoken)
        let budget = symbolCount(expected) * wordsPerSymbol
        let unreachable = Int.max
        var best = [[Int]](repeating: [Int](repeating: unreachable, count: heard.count + 1),
                           count: tokens.count + 1)
        best[0][0] = 0
        for index in 0...tokens.count {
            for position in 0...heard.count {
                let cost = best[index][position]
                guard cost <= budget else { continue }
                if position < heard.count {
                    best[index][position + 1] = min(best[index][position + 1], cost + 1)
                }
                guard index < tokens.count else { continue }
                for end in slotEnds(tokens[index], heard: heard, from: position) {
                    best[index + 1][end] = min(best[index + 1][end], cost)
                }
            }
        }
        return best[tokens.count][heard.count] <= budget
    }

    private static func slotEnds(_ token: Token, heard: [String], from start: Int) -> [Int] {
        if case .word(let word) = token {
            return start < heard.count && heard[start] == word ? [start + 1] : []
        }
        let longest = min(heard.count, start + maximumNumeralWords)
        guard start < longest else { return [] }
        return (start + 1...longest).filter { accepts(token, Array(heard[start..<$0])) }
    }

    static func accepts(_ token: Token, _ heard: [String]) -> Bool {
        guard !heard.contains(where: negations.contains) else { return false }
        guard case .number(let digits) = token else { return true }
        guard heard.contains(where: { isDigits($0) || NumberWords.value(of: $0) != nil }) else {
            return true
        }
        return NumberWords.canRead(heard, as: digits)
    }

    private static let negations: Set<String> = [
        "not", "no", "never", "none", "nothing", "nobody", "neither", "nor", "without"
    ]

    private static func token(_ word: String) -> Token {
        if isDigits(word) { return word.count <= maximumNumeralDigits ? .number(word) : .mixed }
        return word.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains) ? .mixed : .word(word)
    }

    static func isDigits(_ word: String) -> Bool {
        !word.isEmpty && word.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Case-folded alphanumeric runs, with thousands separators removed so
    /// "2,026" is one numeral.
    static func words(_ text: String) -> [String] {
        let characters = Array(text.lowercased())
        var kept = ""
        for (index, character) in characters.enumerated() {
            if character == ",", isThousandsSeparator(characters, at: index) { continue }
            kept.append(character)
        }
        return kept.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static func isThousandsSeparator(_ characters: [Character], at index: Int) -> Bool {
        let isDigit = { (offset: Int) in
            characters.indices.contains(offset) && characters[offset].isASCII && characters[offset].isNumber
        }
        return isDigit(index - 1) && (1...3).allSatisfy { isDigit(index + $0) } && !isDigit(index + 4)
    }

    private static let punctuation = Set(".,;:!?'\"’‘“”()[]{}-–—…")

    /// Symbols that are read aloud as words. A hyphen counts only as a minus
    /// sign directly before a digit.
    static func symbolCount(_ text: String) -> Int {
        let characters = Array(text)
        return characters.indices.filter { index in
            let character = characters[index]
            if character == "-" {
                let startsWord = index == 0 || characters[index - 1].isWhitespace
                let beforeDigit = index + 1 < characters.count && characters[index + 1].isNumber
                return startsWord && beforeDigit
            }
            return !character.isLetter && !character.isNumber && !character.isWhitespace
                && !punctuation.contains(character)
        }.count
    }
}

/// English number words, enough to check that a spoken reading of a numeral
/// reproduces its digits.
enum NumberWords {
    private static let small: [String: Int] = {
        let cardinals = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                         "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
                         "eighteen", "nineteen"]
        let ordinals = ["zeroth", "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth",
                        "ninth", "tenth", "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth",
                        "sixteenth", "seventeenth", "eighteenth", "nineteenth"]
        let tens = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        let tenths = ["twentieth", "thirtieth", "fortieth", "fiftieth", "sixtieth", "seventieth", "eightieth",
                      "ninetieth"]
        var values: [String: Int] = ["oh": 0, "o": 0, "nought": 0]
        for (value, word) in cardinals.enumerated() { values[word] = value }
        for (value, word) in ordinals.enumerated() { values[word] = value }
        for (index, word) in tens.enumerated() { values[word] = (index + 2) * 10 }
        for (index, word) in tenths.enumerated() { values[word] = (index + 2) * 10 }
        return values
    }()

    private static let scales: [String: Int] = [
        "hundred": 100, "hundredth": 100, "thousand": 1_000, "thousandth": 1_000,
        "million": 1_000_000, "millionth": 1_000_000, "billion": 1_000_000_000, "billionth": 1_000_000_000
    ]

    /// Words between numbers that carry no digits ("three point five").
    private static let separators: Set<String> = ["and", "point", "dot", "comma", "colon", "dash", "hyphen"]

    static func value(of word: String) -> Int? { small[word] ?? scales[word] }

    /// Whether `words` can be split into numbers whose digits, in order, are
    /// exactly `digits`. Separators may sit between those numbers.
    static func canRead(_ words: [String], as digits: String) -> Bool {
        let target = Array(digits)
        var reachable = Set([Pair(word: 0, digit: 0)])
        var frontier = [Pair(word: 0, digit: 0)]
        while let state = frontier.popLast() {
            if state.word == words.count { if state.digit == target.count { return true }; continue }
            var next: [Pair] = []
            if separators.contains(words[state.word]) { next.append(Pair(word: state.word + 1, digit: state.digit)) }
            for end in (state.word + 1)...words.count {
                for reading in readings(Array(words[state.word..<end])) {
                    let reachEnd = state.digit + reading.count
                    if reachEnd <= target.count, Array(target[state.digit..<reachEnd]) == Array(reading) {
                        next.append(Pair(word: end, digit: reachEnd))
                    }
                }
            }
            for pair in next where reachable.insert(pair).inserted { frontier.append(pair) }
        }
        return false
    }

    private struct Pair: Hashable { let word: Int, digit: Int }

    private static func readings(_ words: [String]) -> [String] {
        if words.count == 1, RealtimeReadingCheck.isDigits(words[0]) { return [words[0]] }
        if words.count == 1, ["oh", "o", "nought", "zero"].contains(words[0]) { return ["0"] }
        return cardinal(words).map { [String($0)] } ?? []
    }

    /// "two thousand and twenty six" → 2026, "a hundred" → 100.
    private static func cardinal(_ words: [String]) -> Int? {
        var total = 0, current = 0, sawValue = false
        for (index, word) in words.enumerated() {
            let isLast = index == words.count - 1
            if word == "and" {
                guard sawValue, !isLast else { return nil }
                continue
            }
            if word == "a" {
                guard !isLast, scales[words[index + 1]] != nil else { return nil }
                current += 1
            } else if RealtimeReadingCheck.isDigits(word), word.count <= RealtimeReadingCheck.maximumNumeralDigits,
                      let number = Int(word) {
                current += number
            } else if let number = small[word], !["oh", "o", "nought"].contains(word) {
                current += number
            } else if let scale = scales[word] {
                if scale == 100 {
                    current = max(current, 1) * 100
                } else {
                    total += max(current, 1) * scale
                    current = 0
                }
            } else {
                return nil
            }
            sawValue = true
            guard total + current < 1_000_000_000_000_000 else { return nil }
        }
        return sawValue ? total + current : nil
    }
}
