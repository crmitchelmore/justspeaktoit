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
/// - a minus sign starting a numeral ("-5") must be read as one word carrying
///   no number ("minus", "negative"), so "-5" read as "five" fails;
/// - a decimal point between digits ("3.5") may be read as one such word
///   ("point") or left out, and is never read inside an integer, so "35" read
///   as "three point five" fails;
/// - spoken words that match nothing are allowed only for symbols read aloud
///   ("&" as "and", "$5" as "five dollars"), `wordsPerSymbol` each. Anything
///   more, such as an inserted "not", an answer or commentary, fails.
enum RealtimeReadingCheck {
    static let maximumNumeralWords = 8
    static let wordsPerSymbol = 2
    /// Longer digit runs are not parsed as numbers; they become bounded slots.
    static let maximumNumeralDigits = 15

    enum Token: Equatable {
        case word(String), number(String), mixed, minus, point
    }

    /// What `words` emits for a minus sign and a decimal point; no alphanumeric
    /// run can produce either.
    static let minusWord = "-"
    static let pointWord = "."

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
        let next = start < heard.count ? heard[start] : nil
        switch token {
        case .word(let word):
            return next == word ? [start + 1] : []
        case .minus:
            return next.map(carriesNoNumber) == true ? [start + 1] : []
        case .point:
            return next.map(carriesNoNumber) == true ? [start, start + 1] : [start]
        case .number, .mixed:
            break
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

    /// A spoken sign or decimal point: a word with no digits, number or negation
    /// in it ("minus", "point", or another language's).
    private static func carriesNoNumber(_ word: String) -> Bool {
        !isDigits(word) && NumberWords.value(of: word) == nil && !negations.contains(word)
    }

    private static let negations: Set<String> = [
        "not", "no", "never", "none", "nothing", "nobody", "neither", "nor", "without"
    ]

    private static func token(_ word: String) -> Token {
        if word == minusWord { return .minus }
        if word == pointWord { return .point }
        if isDigits(word) { return word.count <= maximumNumeralDigits ? .number(word) : .mixed }
        return word.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains) ? .mixed : .word(word)
    }

    static func isDigits(_ word: String) -> Bool {
        !word.isEmpty && word.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Case-folded alphanumeric runs, with thousands separators removed so
    /// "2,026" is one numeral, and `minusWord` and `pointWord` for a numeral's
    /// sign and decimal point.
    static func words(_ text: String) -> [String] {
        let characters = Array(text.lowercased())
        var words: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { words.append(current) }
            current = ""
        }
        for (index, character) in characters.enumerated() {
            if character == ",", isThousandsSeparator(characters, at: index) { continue }
            if isMinusSign(characters, at: index) || isDecimalPoint(characters, at: index) {
                flush()
                words.append(character == "." ? pointWord : minusWord)
                continue
            }
            for scalar in character.unicodeScalars {
                if CharacterSet.alphanumerics.contains(scalar) { current.unicodeScalars.append(scalar) } else { flush() }
            }
        }
        flush()
        return words
    }

    private static func isDigit(_ characters: [Character], at index: Int) -> Bool {
        characters.indices.contains(index) && characters[index].isASCII && characters[index].isNumber
    }

    private static func isThousandsSeparator(_ characters: [Character], at index: Int) -> Bool {
        isDigit(characters, at: index - 1) && (1...3).allSatisfy { isDigit(characters, at: index + $0) }
            && !isDigit(characters, at: index + 4)
    }

    /// A hyphen or minus sign starting a word, directly before a digit.
    private static func isMinusSign(_ characters: [Character], at index: Int) -> Bool {
        guard characters[index] == "-" || characters[index] == "\u{2212}" else { return false }
        return (index == 0 || characters[index - 1].isWhitespace) && isDigit(characters, at: index + 1)
    }

    private static func isDecimalPoint(_ characters: [Character], at index: Int) -> Bool {
        characters[index] == "." && isDigit(characters, at: index - 1) && isDigit(characters, at: index + 1)
    }

    private static let punctuation = Set(".,;:!?'\"’‘“”()[]{}-–—…")

    /// Symbols that are read aloud as words. A numeral's minus sign is not one:
    /// it is a slot of its own that must be read.
    static func symbolCount(_ text: String) -> Int {
        let characters = Array(text)
        return characters.indices.filter { index in
            let character = characters[index]
            if isMinusSign(characters, at: index) { return false }
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

    /// Words between numbers that carry no digits ("ten colon thirty"). A
    /// decimal point is not one: an integer is never read with one inside it.
    private static let separators: Set<String> = ["and", "comma", "colon", "dash", "hyphen"]
    private static let limit = 1_000_000_000_000_000

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
                // Checked before multiplying, which would otherwise overflow.
                let base = max(current, 1)
                guard base <= (limit - 1 - total) / scale else { return nil }
                if scale == 100 {
                    current = base * 100
                } else {
                    total += base * scale
                    current = 0
                }
            } else {
                return nil
            }
            sawValue = true
            guard total + current < limit else { return nil }
        }
        return sawValue ? total + current : nil
    }
}
