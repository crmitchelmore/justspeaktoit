import Foundation

extension PronunciationRenderer {
    /// Renders plain text as an SSML fragment. Regex entries remain replacement
    /// templates; generated phonemes and all replacement text are XML literals.
    public func generateSSML(
        for text: String, entries: [PronunciationEntry], provider: PronunciationPhonemeCapable
    ) -> String {
        guard provider.supportsSSMLPhonemes else { return applyReplacements(to: text, entries: entries) }
        var pieces: [PronunciationSpeechPiece] = [.text(text)]
        for entry in entries {
            if entry.isRegex && entry.replacement == nil { continue }
            let context = pieces.map(\.context).joined()
            let matches = pronunciationMatches(in: context, entry: entry)
            var offset = 0
            var next: [PronunciationSpeechPiece] = []
            for piece in pieces {
                defer { offset += piece.context.utf16.count }
                guard case .text(let value) = piece else {
                    next.append(piece)
                    continue
                }
                let length = value.utf16.count
                let applicable = matches.filter {
                    $0.range.location >= offset && NSMaxRange($0.range) <= offset + length
                }
                let string = value as NSString
                var cursor = 0
                for match in applicable {
                    let start = match.range.location - offset
                    next.append(.text(string.substring(with: NSRange(location: cursor, length: start - cursor))))
                    if let replacement = match.replacement {
                        next.append(.text(replacement))
                    } else {
                        next.append(.phoneme(word: entry.word, pronunciation: entry.pronunciation,
                                             alphabet: provider.phonemeAlphabet))
                    }
                    cursor = NSMaxRange(match.range) - offset
                }
                next.append(.text(string.substring(from: cursor)))
            }
            pieces = Self.coalescingSpeechText(next)
        }
        finishSSMLDictionaryPass(entries)
        return pieces.map(\.xml).joined()
    }

    private func pronunciationMatches(in text: String, entry: PronunciationEntry) -> [PronunciationSpeechMatch] {
        if !entry.isRegex && entry.caseSensitive {
            guard !entry.word.isEmpty else { return [] }
            var matches: [PronunciationSpeechMatch] = []
            var start = text.startIndex
            while start < text.endIndex,
                  let range = text.range(of: entry.word, range: start..<text.endIndex) {
                matches.append(.init(range: NSRange(range, in: text), replacement: nil))
                start = range.upperBound
            }
            return matches
        }
        let pattern = entry.isRegex ? entry.word : Self.wordPattern(entry.word)
        let options = entry.isRegex ? Self.regexOptions(caseSensitive: entry.caseSensitive) : .caseInsensitive
        guard let regex = cachedRegex(pattern: pattern, options: options) else { return [] }
        // Match in the whole context so anchors/lookarounds do not restart at
        // piece boundaries. Only matches wholly in unprotected text are used.
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            let replacement = entry.isRegex ? regex.replacementString(
                for: match, in: text, offset: 0, template: entry.replacement ?? "") : nil
            return PronunciationSpeechMatch(range: match.range, replacement: replacement)
        }
    }

    private static func coalescingSpeechText(_ pieces: [PronunciationSpeechPiece]) -> [PronunciationSpeechPiece] {
        var result: [PronunciationSpeechPiece] = []
        for piece in pieces {
            if case .text(let value) = piece, case .text(let previous)? = result.last {
                result[result.count - 1] = .text(previous + value)
            } else {
                result.append(piece)
            }
        }
        return result
    }
}

private struct PronunciationSpeechMatch {
    let range: NSRange
    let replacement: String?
}

private enum PronunciationSpeechPiece {
    case text(String)
    case phoneme(word: String, pronunciation: String, alphabet: String)

    var context: String {
        switch self {
        case .text(let text): return text
        case .phoneme: return xml
        }
    }

    var xml: String {
        switch self {
        case .text(let text): return VoiceSynthesisMarkup.escapeXML(text)
        case .phoneme(let word, let pronunciation, let alphabet):
            let alphabet = VoiceSynthesisMarkup.escapeXML(alphabet)
            let pronunciation = VoiceSynthesisMarkup.escapeXML(pronunciation)
            return "<phoneme alphabet=\"\(alphabet)\" ph=\"\(pronunciation)\">"
                + "\(VoiceSynthesisMarkup.escapeXML(word))</phoneme>"
        }
    }
}
