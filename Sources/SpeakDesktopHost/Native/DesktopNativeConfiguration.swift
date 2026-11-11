import Foundation
import SpeakCore
import SpeakDesktop

/// The C callback both windows register for Dictation preferences:
/// action, values, value count, context, error buffer, error capacity.
package typealias DesktopNativeConfigurationCallback = @convention(c) (
    Int32, UnsafePointer<UnsafePointer<CChar>?>?, Int, UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>?, Int
) -> Int32

/// One Dictation preferences row, with strings owned by the caller's
/// `DesktopNativeStrings`. Each host copies it into its C module's
/// `JSTIConfigurationField`.
package struct DesktopNativeConfigurationRow {
    package typealias CString = UnsafePointer<CChar>?
    package var title: CString
    package var value: CString
    package var group: CString
    package var isBoolean: Int32
    package var requiresHUDOverlay: Int32
    package var choices: CString
    package var requiresHandsFreeGuard: Int32
    /// Zero: independent. Otherwise the 1-based index of a boolean enabling field.
    package var enabledByField: Int32
}

/// The Dictation preferences editor's native calls, from one host's C module.
package struct DesktopNativeConfigurationCalls<Field>: Sendable {
    package typealias CString = UnsafePointer<CChar>?
    /// fields, count, recovered keywords, count, callback, context, revision.
    package typealias SetRevision = @Sendable (
        UnsafePointer<Field>?, Int, UnsafePointer<CString>?, Int,
        DesktopNativeConfigurationCallback?, UnsafeMutableRawPointer?, CString
    ) -> Int32

    package var makeField: @Sendable (DesktopNativeConfigurationRow) -> Field
    package var setRevision: SetRevision
    package var setFieldTitle: @Sendable (Int, CString) -> Int32
    package var setFieldEnabled: @Sendable (Int, Int32) -> Int32
    package var setEscapeCancellation: @Sendable (Int32) -> Int32

    package init(
        makeField: @escaping @Sendable (DesktopNativeConfigurationRow) -> Field,
        setRevision: @escaping SetRevision,
        setFieldTitle: @escaping @Sendable (Int, CString) -> Int32,
        setFieldEnabled: @escaping @Sendable (Int, Int32) -> Int32,
        setEscapeCancellation: @escaping @Sendable (Int32) -> Int32
    ) {
        self.makeField = makeField
        self.setRevision = setRevision
        self.setFieldTitle = setFieldTitle
        self.setFieldEnabled = setFieldEnabled
        self.setEscapeCancellation = setEscapeCancellation
    }
}

/// The layout density and sidebar shortcut calls, from one host's C module.
package struct DesktopNativeLayoutCalls<Density, Shortcut>: Sendable {
    package typealias CString = UnsafePointer<CChar>?
    package var makeDensity: @Sendable (AppVisualDensity) -> Density
    package var setDensity: @Sendable (Density) -> Int32
    /// destination, digit, hint.
    package var makeShortcut: @Sendable (CString, Int32, CString) -> Shortcut
    package var setSidebarShortcuts: @Sendable (UnsafePointer<Shortcut>?, Int, Int32) -> Int32

    package init(
        makeDensity: @escaping @Sendable (AppVisualDensity) -> Density,
        setDensity: @escaping @Sendable (Density) -> Int32,
        makeShortcut: @escaping @Sendable (CString, Int32, CString) -> Shortcut,
        setSidebarShortcuts: @escaping @Sendable (UnsafePointer<Shortcut>?, Int, Int32) -> Int32
    ) {
        self.makeDensity = makeDensity
        self.setDensity = setDensity
        self.makeShortcut = makeShortcut
        self.setSidebarShortcuts = setSidebarShortcuts
    }
}

/// Shows Dictation preferences in a native window. Both hosts present the
/// same canonical fields in the same order; each maps a failed step to its
/// own status text.
package enum DesktopNativeConfiguration {
    /// The step that the window refused.
    package enum Step: Equatable, Sendable {
        case escapeCancellation
        case preferences
        case qualityAvailability
        case layoutDensity
        case sidebarShortcuts
    }

    package static var languageFieldIndex: Int? {
        DesktopConfiguration.fields.firstIndex { $0.key == VoiceOutputLanguagePreference.key }
    }

    package static var qualityFieldIndex: Int? {
        DesktopConfiguration.fields.firstIndex { $0.key == VoiceSynthesisPreference.quality.key.rawValue }
    }

    /// The canonical rows for `snapshot`, with the Voice language and quality
    /// titles the snapshot resolved for the selected voice.
    package static func rows(
        _ snapshot: DesktopHostConfigurationEditorSnapshot, strings: DesktopNativeStrings
    ) -> [DesktopNativeConfigurationRow] {
        let preferences = snapshot.preferences
        return zip(DesktopConfiguration.fields, snapshot.entries).map { field, value in
            let title = field.key == VoiceOutputLanguagePreference.key ? snapshot.languageTitle
                : field.key == VoiceSynthesisPreference.quality.key.rawValue ? snapshot.qualityTitle : field.title
            let isBoolean: Int32 = { if case .boolean = field.kind { return 1 }; return 0 }()
            return DesktopNativeConfigurationRow(
                title: strings.add(title), value: strings.add(value), group: strings.add(field.group),
                isBoolean: isBoolean, requiresHUDOverlay: field.requiresHUDOverlay ? 1 : 0,
                choices: preferences.serializedChoices(for: field).map { strings.add($0) },
                requiresHandsFreeGuard: field.requiresHandsFreeGuard ? 1 : 0,
                enabledByField: field.enabledBy.flatMap { key in
                    DesktopConfiguration.fields.firstIndex { $0.key == key }.map { Int32($0 + 1) }
                } ?? 0
            )
        }
    }

    /// Applies Escape cancellation, then `applyTiming`, then shows the
    /// editor revision and its Voice quality availability. Returns the step
    /// the window refused, or nil when every step was shown.
    package static func present<Field>(
        _ snapshot: DesktopHostConfigurationEditorSnapshot, calls: DesktopNativeConfigurationCalls<Field>,
        callback: DesktopNativeConfigurationCallback, context: UnsafeMutableRawPointer?,
        applyTiming: (DesktopConfiguration) -> Void
    ) -> Step? {
        let preferences = snapshot.preferences
        guard calls.setEscapeCancellation(preferences.cancelRecordingOnEscape ? 1 : 0) == 0 else {
            return .escapeCancellation
        }
        applyTiming(preferences)
        let strings = DesktopNativeStrings()
        let fields = rows(snapshot, strings: strings).map(calls.makeField)
        let recovered: [UnsafePointer<CChar>?] = preferences.recoveredKeywords.map { strings.add($0) }
        let result = withExtendedLifetime(strings) {
            fields.withUnsafeBufferPointer { fields in
                recovered.withUnsafeBufferPointer { recovery in
                    calls.setRevision(
                        fields.baseAddress, fields.count, recovery.baseAddress, recovery.count,
                        callback, context, snapshot.id
                    )
                }
            }
        }
        guard result == 0 else { return .preferences }
        guard let qualityIndex = qualityFieldIndex,
              calls.setFieldEnabled(qualityIndex, snapshot.qualityEnabled ? 1 : 0) >= 0 else {
            return .qualityAvailability
        }
        return nil
    }

    /// Applies the layout density and sidebar shortcut hints. Returns the
    /// step the window refused, or nil.
    package static func presentLayout<Density, Shortcut>(
        _ preferences: DesktopConfiguration, calls: DesktopNativeLayoutCalls<Density, Shortcut>
    ) -> Step? {
        guard calls.setDensity(calls.makeDensity(preferences.visualDensity)) == 0 else { return .layoutDensity }
        let strings = DesktopNativeStrings()
        let bindings = DesktopSidebarShortcut.allCases.map {
            calls.makeShortcut(strings.add($0.rawValue), Int32($0.digit), strings.add($0.chord))
        }
        let shown = withExtendedLifetime(strings) {
            bindings.withUnsafeBufferPointer {
                calls.setSidebarShortcuts(
                    $0.baseAddress, $0.count, preferences.enabled("showSidebarShortcutHints") ? 1 : 0
                )
            }
        }
        return shown == 0 ? nil : .sidebarShortcuts
    }
}
