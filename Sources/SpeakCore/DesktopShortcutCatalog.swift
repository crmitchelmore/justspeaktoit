import Foundation

/// The individual action shortcuts the Mac stores under `customShortcutBindings`.
/// This is the single shared catalogue: identifiers, order, titles, defaults and
/// legacy migrations match `ShortcutAction` in SpeakApp, which a parity test
/// enforces. Membership is not host support: each platform projects the actions
/// it can actually perform and leaves the others untouched in the preference.
public enum DesktopShortcutAction: String, CaseIterable, Codable, Sendable {
    case openDashboard
    case startStopRecording
    case speakSelectedText
    case speakClipboard
    case pauseResumeTTS
    case stopTTS
    case openSettings
    case showHistory
    case openVoiceOutput
    case openCorrections
    case openTroubleshooting
    case openTranscriptionSettings
    case openPostProcessingSettings
    case openDataMigrationSettings
    case openProfilesSettings
    case openVoiceOutputSettings
    case openPronunciationSettings
    case openAPIKeysSettings
    case openKeyboardSettings
    case openPermissionsSettings
    case openCompareModelsSettings
    case openAboutSettings
    case quickVoice1
    case quickVoice2
    case quickVoice3
    case pasteLastHistoryItem
    case editSelectionByVoice

    public var displayName: String {
        switch self {
        case .openDashboard: "Open Dashboard"
        case .startStopRecording: "Start/Stop Recording"
        case .speakSelectedText: "Speak Selected Text"
        case .speakClipboard: "Speak Clipboard Content"
        case .pauseResumeTTS: "Pause/Resume TTS"
        case .stopTTS: "Stop TTS"
        case .openSettings: "Open General Settings"
        case .showHistory: "Show History"
        case .openVoiceOutput: "Open Voice Output"
        case .openCorrections: "Open Corrections"
        case .openTroubleshooting: "Open Troubleshooting"
        case .openTranscriptionSettings: "Open Transcription Settings"
        case .openPostProcessingSettings: "Open Post-processing Settings"
        case .openDataMigrationSettings: "Open Data & Migration"
        case .openProfilesSettings: "Open Profiles Settings"
        case .openVoiceOutputSettings: "Open Voice Output Settings"
        case .openPronunciationSettings: "Open Pronunciation Settings"
        case .openAPIKeysSettings: "Open API Keys Settings"
        case .openKeyboardSettings: "Open Keyboard Settings"
        case .openPermissionsSettings: "Open Permissions Settings"
        case .openCompareModelsSettings: "Open Compare Models"
        case .openAboutSettings: "Open About Settings"
        case .quickVoice1: "Quick Switch Voice 1"
        case .quickVoice2: "Quick Switch Voice 2"
        case .quickVoice3: "Quick Switch Voice 3"
        case .pasteLastHistoryItem: "Paste Last History Item"
        case .editSelectionByVoice: "Edit Selection by Voice"
        }
    }

    /// Actions that may work while another app is in front.
    public var supportsGlobalShortcut: Bool {
        switch self {
        case .startStopRecording, .speakSelectedText, .speakClipboard, .pasteLastHistoryItem,
             .editSelectionByVoice:
            true
        default: false
        }
    }

    public var isGlobalByDefault: Bool { supportsGlobalShortcut && self != .startStopRecording }

    public var defaultBinding: DesktopShortcutBinding {
        let command: DesktopShortcutModifiers = .command
        let commandShift: DesktopShortcutModifiers = [.command, .shift]
        let commandOption: DesktopShortcutModifiers = [.command, .option]
        func binding(_ keyCode: UInt16, _ modifiers: DesktopShortcutModifiers, enabled: Bool = true)
            -> DesktopShortcutBinding {
            DesktopShortcutBinding(
                keyCode: keyCode, modifiers: modifiers, isGlobal: isGlobalByDefault, isEnabled: enabled
            )
        }
        switch self {
        case .openDashboard: return binding(2, command)
        case .startStopRecording: return binding(1, commandShift)
        case .speakSelectedText: return binding(17, commandShift)
        case .speakClipboard: return binding(9, commandShift)
        case .pauseResumeTTS: return binding(49, [])
        case .stopTTS: return binding(53, [])
        case .openSettings: return binding(18, command)
        case .showHistory: return binding(16, command)
        case .openVoiceOutput: return binding(32, command)
        case .openCorrections: return binding(40, command)
        case .openTroubleshooting: return binding(17, command)
        case .openTranscriptionSettings: return binding(19, command)
        case .openPostProcessingSettings: return binding(20, command)
        case .openDataMigrationSettings: return binding(0, [], enabled: false)
        case .openProfilesSettings: return binding(29, command)
        case .openVoiceOutputSettings: return binding(21, command)
        case .openPronunciationSettings: return binding(23, command)
        case .openAPIKeysSettings: return binding(22, command)
        case .openKeyboardSettings: return binding(26, command)
        case .openPermissionsSettings: return binding(28, command)
        case .openCompareModelsSettings: return binding(0, [], enabled: false)
        case .openAboutSettings: return binding(25, command)
        case .quickVoice1: return binding(18, commandOption)
        case .quickVoice2: return binding(19, commandOption)
        case .quickVoice3: return binding(20, commandOption)
        case .pasteLastHistoryItem: return binding(9, commandOption)
        case .editSelectionByVoice: return binding(14, commandOption)
        }
    }

    /// Earlier Mac defaults. A stored binding equal to one of these is replaced
    /// by the current default when loaded, as the Mac does.
    public var legacyDefaultBindings: [DesktopShortcutBinding] {
        func legacy(_ keyCode: UInt16, _ modifiers: DesktopShortcutModifiers, global: Bool = false)
            -> [DesktopShortcutBinding] {
            [DesktopShortcutBinding(keyCode: keyCode, modifiers: modifiers, isGlobal: global, isEnabled: true)]
        }
        let commandOption: DesktopShortcutModifiers = [.command, .option]
        let commandOptionShift: DesktopShortcutModifiers = [.command, .option, .shift]
        switch self {
        case .startStopRecording: return legacy(1, [.command, .shift], global: true)
        case .openDashboard: return legacy(18, commandOption)
        case .showHistory: return legacy(19, commandOption)
        case .openVoiceOutput: return legacy(20, commandOption)
        case .openCorrections: return legacy(21, commandOption)
        case .openTroubleshooting: return legacy(23, commandOption)
        case .openSettings: return legacy(43, .command)
        case .openTranscriptionSettings: return legacy(18, commandOptionShift)
        case .openPostProcessingSettings: return legacy(19, commandOptionShift)
        case .openVoiceOutputSettings: return legacy(20, commandOptionShift)
        case .openPronunciationSettings: return legacy(21, commandOptionShift)
        case .openAPIKeysSettings: return legacy(23, commandOptionShift)
        case .openKeyboardSettings: return legacy(22, commandOptionShift)
        case .openPermissionsSettings: return legacy(26, commandOptionShift)
        case .openAboutSettings: return legacy(28, commandOptionShift)
        case .quickVoice1: return legacy(18, .command)
        case .quickVoice2: return legacy(19, .command)
        case .quickVoice3: return legacy(20, .command)
        default: return []
        }
    }
}

/// Modifier bits in the Mac's stored form (`NSEvent.ModifierFlags` raw values),
/// so a binding moves between platforms without translation.
public struct DesktopShortcutModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let shift = Self(rawValue: 1 << 17)
    public static let control = Self(rawValue: 1 << 18)
    public static let option = Self(rawValue: 1 << 19)
    public static let command = Self(rawValue: 1 << 20)
    public static let function = Self(rawValue: 1 << 23)
    /// The modifiers the Mac records for a shortcut.
    public static let recorded: Self = [.shift, .control, .option, .command]

    /// Mac order: Control, Option, Shift, Command.
    public var macSymbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "")
            + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

/// A key and the modifiers that must be held with it, ignoring other bits.
public struct DesktopShortcutChord: Hashable, Sendable {
    public let keyCode: UInt16
    public let modifiers: DesktopShortcutModifiers

    public init(keyCode: UInt16, modifiers: DesktopShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(.recorded)
    }
}

/// One stored binding. Coding keys and value shapes are the Mac's, so the
/// preference written here decodes on the Mac and the other way round.
public struct DesktopShortcutBinding: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: DesktopShortcutModifiers
    public var isGlobal: Bool
    public var isEnabled: Bool

    public init(keyCode: UInt16, modifiers: DesktopShortcutModifiers, isGlobal: Bool = true, isEnabled: Bool = true) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isGlobal = isGlobal
        self.isEnabled = isEnabled
    }

    public var chord: DesktopShortcutChord { DesktopShortcutChord(keyCode: keyCode, modifiers: modifiers) }

    enum CodingKeys: String, CodingKey {
        case keyCode, modifiersRaw, isGlobal, isEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        modifiers = DesktopShortcutModifiers(rawValue: try container.decode(UInt.self, forKey: .modifiersRaw))
        isGlobal = try container.decodeIfPresent(Bool.self, forKey: .isGlobal) ?? false
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifiers.rawValue, forKey: .modifiersRaw)
        try container.encode(isGlobal, forKey: .isGlobal)
        try container.encode(isEnabled, forKey: .isEnabled)
    }

    var jsonValue: AnyCodable.JSONValue {
        .object([
            "keyCode": .int(Int(keyCode)),
            "modifiersRaw": .int(Int(clamping: modifiers.rawValue)),
            "isGlobal": .bool(isGlobal),
            "isEnabled": .bool(isEnabled)
        ])
    }

    init?(jsonValue: AnyCodable.JSONValue) {
        guard case .object(let object) = jsonValue,
              let keyCode = Self.integer(object["keyCode"]).flatMap(UInt16.init(exactly:)),
              let raw = Self.integer(object["modifiersRaw"]).flatMap(UInt.init(exactly:)) else { return nil }
        var isGlobal = false, isEnabled = true
        switch object["isGlobal"] {
        case .bool(let value)?: isGlobal = value
        case nil, .null?: break
        default: return nil
        }
        switch object["isEnabled"] {
        case .bool(let value)?: isEnabled = value
        case nil, .null?: break
        default: return nil
        }
        self.init(keyCode: keyCode, modifiers: DesktopShortcutModifiers(rawValue: raw), isGlobal: isGlobal,
                  isEnabled: isEnabled)
    }

    private static func integer(_ value: AnyCodable.JSONValue?) -> Int? {
        switch value {
        case .int(let number)?: return number
        case .double(let number)? where number.isFinite && number.rounded() == number: return Int(exactly: number)
        default: return nil
        }
    }
}

/// Why a binding cannot be used as stored.
public struct DesktopShortcutConflict: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Another action in the same set uses the same chord.
        case duplicate(DesktopShortcutAction)
        /// A system or host shortcut uses the chord; the description names it.
        case reserved(String)
    }

    public let action: DesktopShortcutAction
    public let kind: Kind

    public init(action: DesktopShortcutAction, kind: Kind) {
        self.action = action
        self.kind = kind
    }

    /// Duplicates make the second action unreachable; reserved chords only warn,
    /// as on the Mac.
    public var isBlocking: Bool {
        if case .duplicate = kind { return true }
        return false
    }

    public var message: String {
        switch kind {
        case .duplicate(let other): "\(action.displayName) uses the same shortcut as \(other.displayName)."
        case .reserved(let owner): "\(action.displayName) uses a shortcut reserved by \(owner)."
        }
    }
}

/// Built-in starting points. Applying one replaces the bindings of every
/// catalogue action; preserved entries for actions this build does not know
/// stay as they are.
public enum DesktopShortcutPreset: String, CaseIterable, Codable, Sendable {
    /// The Mac's current defaults. Reset to defaults applies this preset.
    case standard
    /// Recording and speech actions only; navigation shortcuts are switched off.
    case essentials
    /// Every action shortcut switched off. The separate dictation shortcut is unaffected.
    case off

    public var displayName: String {
        switch self {
        case .standard: "Standard (defaults)"
        case .essentials: "Recording and speech only"
        case .off: "All action shortcuts off"
        }
    }

    public func binding(for action: DesktopShortcutAction) -> DesktopShortcutBinding {
        var binding = action.defaultBinding
        switch self {
        case .standard: break
        case .essentials: binding.isEnabled = binding.isEnabled && Self.essentialActions.contains(action)
        case .off: binding.isEnabled = false
        }
        return binding
    }

    public static let essentialActions: Set<DesktopShortcutAction> = [
        .startStopRecording, .speakSelectedText, .speakClipboard, .pauseResumeTTS, .stopTTS,
        .pasteLastHistoryItem, .editSelectionByVoice
    ]
}

/// The whole `customShortcutBindings` preference. Reads the Mac's encoding (a
/// flat array alternating action identifier and binding, because the Mac's
/// dictionary key is not `CodingKeyRepresentable`) and tolerates an object
/// keyed by identifier. Missing actions get their defaults, legacy defaults
/// migrate, malformed bindings fall back to the default, and entries for
/// actions this build does not know survive unchanged.
public struct DesktopShortcutBindings: Equatable, Sendable {
    public static let preferenceKey = "customShortcutBindings"
    static let maximumPreservedEntries = 64
    static let maximumIdentifierLength = 128

    public private(set) var bindings: [DesktopShortcutAction: DesktopShortcutBinding]
    public private(set) var preservedEntries: [String: AnyCodable.JSONValue]

    public static let defaults = DesktopShortcutBindings(preset: .standard)

    public init(preset: DesktopShortcutPreset = .standard) {
        bindings = Dictionary(uniqueKeysWithValues: DesktopShortcutAction.allCases.map { ($0, preset.binding(for: $0)) })
        preservedEntries = [:]
    }

    public init(_ bindings: [DesktopShortcutAction: DesktopShortcutBinding],
                preservedEntries: [String: AnyCodable.JSONValue] = [:]) {
        self.init()
        for (action, binding) in bindings { self.bindings[action] = binding }
        self.preservedEntries = preservedEntries
    }

    public init(preference: AnyCodable?) {
        self.init()
        var pairs: [(String, AnyCodable.JSONValue)] = []
        switch preference?.storage {
        case .array(let items)?:
            var index = 0
            while index + 1 < items.count {
                if case .string(let identifier) = items[index] { pairs.append((identifier, items[index + 1])) }
                index += 2
            }
        case .object(let object)?:
            pairs = object.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        default: break
        }
        for (identifier, value) in pairs {
            guard let action = DesktopShortcutAction(rawValue: identifier) else {
                if preservedEntries.count < Self.maximumPreservedEntries,
                   identifier.utf8.count <= Self.maximumIdentifierLength, !identifier.isEmpty {
                    preservedEntries[identifier] = value
                }
                continue
            }
            guard let binding = DesktopShortcutBinding(jsonValue: value) else { continue }
            bindings[action] = action.legacyDefaultBindings.contains(binding) ? action.defaultBinding : binding
        }
    }

    public init(configuration: DesktopConfiguration?) {
        self.init(preference: configuration?.values[Self.preferenceKey])
    }

    public subscript(action: DesktopShortcutAction) -> DesktopShortcutBinding {
        get { bindings[action] ?? action.defaultBinding }
        set { bindings[action] = newValue }
    }

    /// The Mac's array form: catalogue actions in order, then preserved entries
    /// by identifier, so the same bindings always encode identically.
    public var preferenceValue: AnyCodable {
        var items: [AnyCodable.JSONValue] = []
        for action in DesktopShortcutAction.allCases {
            items.append(.string(action.rawValue))
            items.append(self[action].jsonValue)
        }
        for identifier in preservedEntries.keys.sorted() {
            guard let value = preservedEntries[identifier] else { continue }
            items.append(.string(identifier))
            items.append(value)
        }
        return AnyCodable(.array(items))
    }

    public func applying(_ preset: DesktopShortcutPreset) -> Self {
        var applied = Self(preset: preset)
        applied.preservedEntries = preservedEntries
        return applied
    }

    public func resettingToDefaults() -> Self { applying(.standard) }

    /// The preset these bindings match exactly, if any.
    public var matchingPreset: DesktopShortcutPreset? {
        DesktopShortcutPreset.allCases.first { preset in
            DesktopShortcutAction.allCases.allSatisfy { self[$0] == preset.binding(for: $0) }
        }
    }

    /// The Mac's system shortcuts. Using one only warns, as on the Mac.
    public static let systemReservedChords: [DesktopShortcutChord: String] = [
        DesktopShortcutChord(keyCode: 1, modifiers: .command): "Save (System)",
        DesktopShortcutChord(keyCode: 1, modifiers: [.command, .shift]): "Save As (System)",
        DesktopShortcutChord(keyCode: 9, modifiers: .command): "Paste (System)",
        DesktopShortcutChord(keyCode: 8, modifiers: .command): "Copy (System)",
        DesktopShortcutChord(keyCode: 0, modifiers: .command): "Select All (System)",
        DesktopShortcutChord(keyCode: 6, modifiers: .command): "Undo (System)",
        DesktopShortcutChord(keyCode: 4, modifiers: .command): "Hide App (System)",
        DesktopShortcutChord(keyCode: 12, modifiers: .command): "Quit (System)",
        DesktopShortcutChord(keyCode: 13, modifiers: .command): "Close Window (System)",
        DesktopShortcutChord(keyCode: 45, modifiers: .command): "Minimize (System)"
    ]

    /// Enabled bindings among `actions` that share a chord with an earlier
    /// action in catalogue order, or use a reserved chord. A host passes the
    /// actions it implements and adds its own reserved chords, such as the
    /// separate dictation shortcut.
    public func conflicts(
        among actions: [DesktopShortcutAction] = DesktopShortcutAction.allCases,
        reserved: [DesktopShortcutChord: String] = Self.systemReservedChords
    ) -> [DesktopShortcutConflict] {
        let included = Set(actions)
        var owners: [DesktopShortcutChord: DesktopShortcutAction] = [:]
        var conflicts: [DesktopShortcutConflict] = []
        for action in DesktopShortcutAction.allCases where included.contains(action) {
            let binding = self[action]
            guard binding.isEnabled else { continue }
            if let owner = owners[binding.chord] {
                conflicts.append(DesktopShortcutConflict(action: action, kind: .duplicate(owner)))
            } else {
                owners[binding.chord] = action
            }
            if let description = reserved[binding.chord] {
                conflicts.append(DesktopShortcutConflict(action: action, kind: .reserved(description)))
            }
        }
        return conflicts
    }
}

extension DesktopConfiguration {
    public var shortcutBindings: DesktopShortcutBindings { DesktopShortcutBindings(configuration: self) }

    /// A copy whose `customShortcutBindings` holds `bindings`; every other key is unchanged.
    public func replacingShortcutBindings(_ bindings: DesktopShortcutBindings) throws -> DesktopConfiguration {
        var changed = values
        changed[DesktopShortcutBindings.preferenceKey] = bindings.preferenceValue
        return try DesktopConfiguration(values: changed)
    }
}
