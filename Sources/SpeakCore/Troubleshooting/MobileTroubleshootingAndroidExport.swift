import Foundation

/// The phone Troubleshooting rules as JSON for the Android app, so it shows the same verdicts and fixes as
/// iOS. Every check lists the finding for each state the platform can report, worded for Android; a state
/// with no finding (such as a model that needs no key) is left out. Key findings name the provider with
/// ``providerPlaceholder``. `MobileTroubleshootingAndroidExportTests` fails when the committed asset is
/// stale; regenerate it with `scripts/update-android-assets`.
public enum MobileTroubleshootingAndroidExport {
    public static let providerPlaceholder = "{provider}"

    public static func json() throws -> Data {
        struct Rule: Encodable {
            let title, detail, severity: String
            let fixes: [String]
        }
        struct Check: Encodable {
            let id: String
            let states: [String: Rule]
        }
        struct Document: Encodable {
            let version: Int
            let providerPlaceholder: String
            /// Most severe first; findings sort by this, then by check order.
            let severities: [String]
            let checks: [Check]
        }
        let severities = MobileTroubleshooting.Severity.allCases.sorted { $0.priority < $1.priority }
        let document = Document(
            version: 1,
            providerPlaceholder: providerPlaceholder,
            severities: severities.map(\.rawValue),
            checks: MobileTroubleshooting.Check.allCases.map { check in
                Check(id: check.rawValue, states: rules(for: check))
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(document)
        data.append(0x0A)
        return data

        func rules(for check: MobileTroubleshooting.Check) -> [String: Rule] {
            var rules: [String: Rule] = [:]
            for (state, input) in inputs(for: check) {
                guard let finding = MobileTroubleshooting.finding(for: check, input, platform: .android) else {
                    continue
                }
                rules[state] = Rule(
                    title: finding.title, detail: finding.detail, severity: finding.severity.rawValue,
                    fixes: finding.fixes.map(\.rawValue)
                )
            }
            return rules
        }
    }

    /// One input per state of `check`, keyed by the state's raw value. Android cannot verify keys.
    private static func inputs(for check: MobileTroubleshooting.Check) -> [(String, MobileTroubleshooting.Input)] {
        typealias Input = MobileTroubleshooting.Input
        let noKey = MobileTroubleshooting.Provider(name: nil, key: .notRequired)
        func provider(_ key: MobileTroubleshooting.KeyState) -> MobileTroubleshooting.Provider {
            MobileTroubleshooting.Provider(name: providerPlaceholder, key: key)
        }
        switch check {
        case .microphone:
            return MobileTroubleshooting.Permission.allCases.map {
                ($0.rawValue, Input(microphone: $0, transcription: noKey))
            }
        case .speechRecognition:
            return MobileTroubleshooting.Permission.allCases.map {
                ($0.rawValue, Input(microphone: .granted, speechRecognition: $0, transcription: noKey))
            }
        case .recogniser:
            return MobileTroubleshooting.Recogniser.allCases.map {
                ($0.rawValue, Input(microphone: .granted, recogniser: $0, transcription: noKey))
            }
        case .transcriptionKey:
            return MobileTroubleshooting.KeyState.allCases.map {
                ($0.rawValue, Input(microphone: .granted, transcription: provider($0)))
            }
        case .postProcessingKey:
            return MobileTroubleshooting.KeyState.allCases.map {
                (
                    $0.rawValue,
                    Input(
                        microphone: .granted, transcription: noKey,
                        postProcessingEnabled: true, postProcessing: provider($0)
                    )
                )
            }
        case .keyboard:
            return MobileTroubleshooting.Keyboard.allCases.map {
                ($0.rawValue, Input(microphone: .granted, transcription: noKey, keyboard: $0))
            }
        }
    }
}
