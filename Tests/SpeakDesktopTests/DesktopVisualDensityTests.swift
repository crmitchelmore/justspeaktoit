import Foundation
import SpeakCore
import XCTest

final class DesktopVisualDensityTests: XCTestCase {
    func testCanonicalMetrics_PreserveNormalAndCompactValues() {
        XCTAssertEqual(AppVisualDensity.allCases.map(\.rawValue), ["normal", "compact"])
        XCTAssertEqual(AppVisualDensity.allCases.map(\.displayName), ["Normal", "Compact"])
        let expected: [[CGFloat]] = [
            [20, 24, 24, 18, 12, 16, 4, 24, 28, 340, 200],
            [6, 8, 8, 6, 6, 8, 0, 4, 12, 240, 132]
        ]
        for (density, metrics) in zip(AppVisualDensity.allCases, expected) {
            XCTAssertEqual([
                density.sectionSpacing, density.pagePadding, density.cardPadding, density.cardContentSpacing,
                density.inlineSpacing, density.groupSpacing, density.listRowVerticalPadding, density.listSectionSpacing,
                density.cardCornerRadius, density.gridMinimumWidth, density.chartHeight
            ], metrics)
        }
        XCTAssertEqual(AppVisualDensity.normal.minimumListRowHeight, 44)
        #if os(iOS)
        XCTAssertEqual(AppVisualDensity.compact.minimumListRowHeight, 44)
        #else
        XCTAssertEqual(AppVisualDensity.compact.minimumListRowHeight, 30)
        #endif
        XCTAssertEqual(AppVisualDensity.normal.adaptiveColumnCount(availableWidth: 1_100), 1)
        XCTAssertEqual(AppVisualDensity.compact.adaptiveColumnCount(availableWidth: 700), 2)
        XCTAssertEqual(AppVisualDensity.compact.adaptiveColumnCount(availableWidth: .nan), 1)
        XCTAssertEqual(AppVisualDensity.compact.adaptiveColumnCount(availableWidth: .infinity), 3)
        XCTAssertEqual(AppVisualDensity.compact.adaptiveColumnCount(availableWidth: -20), 1)
    }

    func testSchema_UsesCanonicalChoicesAndDistinguishesAbsentFromExplicitNormal() throws {
        let key = ApplicationPreferenceKey.visualDensity.rawValue
        let field = try XCTUnwrap(DesktopConfiguration.fields.first { $0.key == key })
        XCTAssertEqual(DesktopConfiguration.fields.filter { $0.key == key }.count, 1)
        XCTAssertEqual(field.group, "General")
        guard case .choice(let choices) = field.kind else { return XCTFail("Missing native density choices") }
        XCTAssertEqual(choices.map(\.value), AppVisualDensity.allCases.map(\.rawValue))
        XCTAssertEqual(choices.map(\.title), AppVisualDensity.allCases.map(\.displayName))
        XCTAssertEqual(field.defaultValue, AnyCodable(.string(AppVisualDensity.normal.rawValue)))
        let defaults = try DesktopConfiguration()
        XCTAssertEqual(defaults.visualDensity, .normal)
        XCTAssertNil(defaults.values[key])
        for density in AppVisualDensity.allCases {
            let configured = try DesktopConfiguration(values: [key: AnyCodable(.string(density.rawValue))])
            let decoded = try JSONDecoder().decode(
                DesktopConfiguration.self, from: JSONEncoder().encode(configured)
            )
            XCTAssertEqual(decoded.visualDensity, density)
            XCTAssertEqual(decoded.values[key], AnyCodable(.string(density.rawValue)))
        }
    }

    func testStrictChoices_RejectInvalidTypesValuesAndEditorEntriesWithoutCoercion() throws {
        let key = ApplicationPreferenceKey.visualDensity.rawValue
        let invalid: [AnyCodable.JSONValue] = [
            .null, .bool(false), .int(0), .array([]), .object([:]),
            .string(""), .string("Normal"), .string(" compact "), .string("future-density")
        ]
        for value in invalid {
            XCTAssertThrowsError(try DesktopConfiguration(values: [key: AnyCodable(value)]))
            let encoded = try JSONEncoder().encode([key: AnyCodable(value)])
            XCTAssertThrowsError(try JSONDecoder().decode(DesktopConfiguration.self, from: encoded))
        }
        let original = try DesktopConfiguration(values: [key: AnyCodable(.string("compact"))])
        var entries = original.entries
        let index = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == key })
        for value in ["tight", "0", "1", "true", "Compact", ""] {
            entries[index] = value
            XCTAssertThrowsError(try DesktopConfiguration.validateEntries(entries))
            XCTAssertThrowsError(try original.applying(entries))
            XCTAssertEqual(original.visualDensity, .compact)
        }
    }

    func testEditingAndJSONTransfer_PreserveUnsupportedAppleValuesAndSidebarHints() throws {
        let opaque = AnyCodable(.object(["version": .int(2), "future": .array([.bool(false), .string("retained")])]))
        let original = try DesktopConfiguration(values: [
            "visualDensity": AnyCodable(.string("compact")),
            "showStatusBarIconInDockOnly": AnyCodable(.bool(false)),
            "futureAppearance": opaque, "showSidebarShortcutHints": AnyCodable(.bool(false))
        ])
        let edited = try original.applying(original.entries)
        let restored = try JSONDecoder().decode(
            DesktopConfiguration.self, from: JSONEncoder().encode(edited)
        )
        XCTAssertEqual(restored.visualDensity, .compact)
        XCTAssertEqual(
            restored.values["showStatusBarIconInDockOnly"], original.values["showStatusBarIconInDockOnly"]
        )
        XCTAssertEqual(restored.values["futureAppearance"], opaque)
        XCTAssertFalse(restored.enabled("showSidebarShortcutHints"))
        XCTAssertFalse(DesktopConfiguration.supportedKeys.contains("showStatusBarIconInDockOnly"))
    }

    func testShellFields_UseMacValuesAndKeepAppleOnlyShellValuesOpaque() throws {
        let fields = DesktopConfiguration.fields.filter { ShellPreference.keys.contains($0.key) }
        XCTAssertEqual(fields.map(\.key), ["appVisibility", "compactStatusBarIcon", "analyticsEnabled"])
        XCTAssertTrue(fields.allSatisfy { $0.group == "General" })
        guard case .choice(let choices) = fields[0].kind else { return XCTFail("App visibility is not a choice") }
        XCTAssertEqual(choices.map(\.value), ["dockAndMenuBar", "menuBarOnly", "dockOnly"])
        let defaults = try DesktopConfiguration()
        XCTAssertEqual(defaults.shellPreferences, DesktopShellPreferences(visibility: .dockAndMenuBar, compactIcon: false))
        XCTAssertFalse(defaults.enabled("analyticsEnabled"))
        XCTAssertTrue(ShellPreference.appleOnlyKeys.isDisjoint(with: DesktopConfiguration.supportedKeys))

        let opaque: [String: AnyCodable] = [
            "showStatusBarIconInDockOnly": AnyCodable(.bool(false)),
            "paidAccessRoutingEnabled": AnyCodable(.bool(true)),
            "recordingsDirectory": AnyCodable(.string("/Users/someone/Recordings"))
        ]
        let imported = try DesktopConfiguration(values: opaque.merging([
            "appVisibility": AnyCodable(.string("menuBarOnly")), "compactStatusBarIcon": AnyCodable(.bool(true)),
            "analyticsEnabled": AnyCodable(.bool(true))
        ]) { $1 })
        XCTAssertEqual(imported.shellPreferences, DesktopShellPreferences(visibility: .menuBarOnly, compactIcon: true))
        let restored = try JSONDecoder().decode(
            DesktopConfiguration.self, from: JSONEncoder().encode(imported.applying(imported.entries))
        )
        XCTAssertEqual(restored.shellPreferences, imported.shellPreferences)
        XCTAssertTrue(restored.enabled("analyticsEnabled"))
        for (key, value) in opaque { XCTAssertEqual(restored.values[key], value, key) }

        XCTAssertThrowsError(try DesktopConfiguration(values: ["appVisibility": AnyCodable(.string("taskbar"))]))
        XCTAssertThrowsError(try DesktopConfiguration(values: ["compactStatusBarIcon": AnyCodable(.string("true"))]))
    }

    func testCanonicalPreferenceTransfer_PreservesUncoveredValueAndExecutesCoveredClearAsNormal() throws {
        let key = ApplicationPreferenceKey.visualDensity.rawValue
        let density = DataMigrationRecord(id: key, kind: "default", value: AnyCodable(.string("compact")))
        let opaque = DataMigrationRecord(
            id: "showStatusBarIconInDockOnly", kind: "default", value: AnyCodable(.bool(false))
        )
        try DataMigrationPreferenceCatalog.validate(density, category: .settings, validateJSON: { _ in
            XCTFail("Density is a scalar preference")
        })
        let current = DataMigrationSnapshot(
            manifest: .init(categories: [.settings], scopes: [:]), records: [.settings: [density, opaque]]
        )
        for covered in [false, true] {
            let incoming = DataMigrationSnapshot(
                manifest: .init(categories: [.settings], scopes: [
                    "settings": .init(selectedIDs: [covered ? key : "showHUD"], selectedKinds: ["default"])
                ]), records: [.settings: []]
            )
            let result = try DataMigrationPlanner.plan(
                current: current, incoming: incoming, modes: [.settings: .replace], useImported: [],
                digest: { _ in String(repeating: "a", count: 64) }
            )
            let preferences = try DesktopConfiguration(values: Dictionary(uniqueKeysWithValues:
                (result.records[.settings] ?? []).filter { $0.kind == "default" }.map { ($0.id, $0.value) }
            ))
            XCTAssertEqual(preferences.visualDensity, covered ? .normal : .compact)
            XCTAssertEqual(preferences.values[key], covered ? nil : density.value)
            XCTAssertEqual(preferences.values["showStatusBarIconInDockOnly"], opaque.value)
        }
    }

    func testAPIKeyQueryHelpers_RemainPortableAndDeterministic() {
        let entries = [
            APIKeyListEntry(id: "b", title: "Equal", category: "Speech", isStored: false),
            APIKeyListEntry(id: "a", title: "Equal", category: "Speech", isStored: true)
        ]
        XCTAssertEqual(APIKeyListQuery.apply(
            to: entries, searchText: " speech ", status: .all, sortOrder: .name
        ).map(\.id), ["a", "b"])
        XCTAssertEqual(APIKeyListQuery.apply(
            to: entries, searchText: "", status: .missing, sortOrder: .status
        ).map(\.id), ["b"])
        XCTAssertEqual(APIKeyListQuery.apply(
            to: entries, searchText: "", status: .stored, sortOrder: .category
        ).map(\.id), ["a"])
    }
}
