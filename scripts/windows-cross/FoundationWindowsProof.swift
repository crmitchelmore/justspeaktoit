import Foundation

struct Proof: Codable, Equatable {
    let platform: String
    let text: String
    let values: [Int]
}

let expected = Proof(platform: "Windows", text: "Hello, Windows — café 🎙️", values: [2, 4, 6, 8])
let encoded = try JSONEncoder().encode(expected)
let decoded = try JSONDecoder().decode(Proof.self, from: encoded)
precondition(decoded == expected, "Foundation JSON round-trip failed")
precondition(Array(1...4).map { $0 * 2 } == expected.values, "Swift Array transform failed")
precondition(String(data: Data(expected.text.utf8), encoding: .utf8) == expected.text,
             "Unicode Data round-trip failed")
let expression = try NSRegularExpression(pattern: "café")
precondition(expression.numberOfMatches(in: expected.text, range: NSRange(expected.text.startIndex..., in: expected.text))
             == 1, "Foundation regular expression failed")
let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("jsti-foundation-cross-proof-" + UUID().uuidString, isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: directory) }
let output = directory.appendingPathComponent("proof.json")
try encoded.write(to: output, options: .atomic)
let reloaded = try Data(contentsOf: output)
precondition(reloaded == encoded, "Foundation file round-trip failed")
#if os(Windows)
print("JSTI_FOUNDATION_WINDOWS_CROSS_PROOF_OK: Unicode, Array, Codable, Data, URL, regex and atomic file I/O")
#else
fatalError("This proof must run as a Windows executable")
#endif
