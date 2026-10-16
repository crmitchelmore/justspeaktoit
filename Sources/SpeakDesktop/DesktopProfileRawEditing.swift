import Foundation
import SpeakCore

extension DesktopDictationProfileStore {
    public func rawDocument() throws -> Data {
        FileManager.default.fileExists(atPath: fileURL.path) ? try Data(contentsOf: fileURL) : Data()
    }

    public func loadForEditing() throws -> (profiles: [DictationProfile], document: Data) {
        let document = try rawDocument()
        let profiles = document.isEmpty && !FileManager.default.fileExists(atPath: fileURL.path)
            ? [] : try DictationProfile.decodeList(document)
        return (profiles, document)
    }

    /// Applies only changes in the typed projection. Unknown fields, future
    /// routing values and unknown matcher objects remain in the canonical file.
    public func savePreservingUnknownFields(
        _ profiles: [DictationProfile], copiedFrom: [UUID: UUID] = [:], expectedDocument: Data? = nil
    ) throws {
        let document = try rawDocument()
        if let expectedDocument, expectedDocument != document {
            throw DesktopLinuxProfileEditor.Failure("Profiles changed outside this editor. Reopen Profiles before saving.")
        }
        let original: [[String: Any]]
        if !document.isEmpty || FileManager.default.fileExists(atPath: fileURL.path) {
            original = try Self.objects(document)
        } else {
            original = []
        }
        var result: [[String: Any]] = []
        for profile in profiles {
            let source = copiedFrom[profile.id] ?? profile.id
            let raw = original.first { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) == source }
            let updated = try Self.object(profile)
            guard var merged = raw else { result.append(updated); continue }
            let baselineData = try JSONSerialization.data(withJSONObject: merged)
            let baseline = try JSONDecoder().decode(DictationProfile.self, from: baselineData)
            let known = try Self.object(baseline)
            if baseline.unsupportedTranscriptionRouting != nil, profile.unsupportedTranscriptionRouting == nil {
                merged["transcriptionRouting"] = updated["transcriptionRouting"]
            }
            for key in Set(known.keys).union(updated.keys) {
                if key == "matchers" {
                    merged[key] = Self.mergeMatchers(raw: merged[key], updated: updated[key])
                } else if !Self.equal(known[key], updated[key]) {
                    merged[key] = updated[key]
                }
            }
            result.append(merged)
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        _ = try DictationProfile.decodeList(data)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func objects(_ data: Data) throws -> [[String: Any]] {
        _ = try DictationProfile.decodeList(data)
        guard let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return objects
    }

    private static func object(_ profile: DictationProfile) throws -> [String: Any] {
        let data = try JSONEncoder().encode(profile)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }

    private static func equal(_ left: Any?, _ right: Any?) -> Bool {
        guard let left, let right else { return left == nil && right == nil }
        return NSDictionary(dictionary: ["value": left]).isEqual(to: ["value": right])
    }

    private static func mergeMatchers(raw: Any?, updated: Any?) -> [[String: Any]] {
        var remaining = updated as? [[String: Any]] ?? []
        var result: [[String: Any]] = []
        for matcher in raw as? [[String: Any]] ?? [] {
            guard let kind = matcher["kind"] as? String,
                  DictationProfileMatcher.Kind(rawValue: kind) != nil else {
                result.append(matcher)
                continue
            }
            if let index = remaining.firstIndex(where: {
                equal($0["kind"], matcher["kind"]) && equal($0["value"], matcher["value"])
            }) {
                result.append(matcher)
                remaining.remove(at: index)
            }
        }
        return result + remaining
    }
}
