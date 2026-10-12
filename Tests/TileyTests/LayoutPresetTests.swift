import Testing
import Carbon
@testable import Tiley

@Suite("LayoutPreset")
struct LayoutPresetTests {

    // MARK: - defaultPresets

    @Test("defaultPresets returns 6 presets")
    func defaultPresetsCount() {
        let presets = LayoutPreset.defaultPresets(rows: 6, columns: 6)
        #expect(presets.count == 6)
    }

    @Test("default presets all have local shortcuts")
    func defaultPresetsLocalShortcuts() {
        let presets = LayoutPreset.defaultPresets(rows: 6, columns: 6)
        for preset in presets {
            #expect(!preset.shortcuts.isEmpty)
            #expect(preset.shortcuts.allSatisfy { !$0.isGlobal })
            #expect(preset.shortcuts.allSatisfy { $0.modifiers == 0 })
        }
    }

    @Test("default presets store base grid dimensions")
    func defaultPresetsBaseDimensions() {
        let presets = LayoutPreset.defaultPresets(rows: 8, columns: 10)
        for preset in presets {
            if preset.name == NSLocalizedString("Center", comment: "Default layout preset name") {
                #expect(preset.baseRows == 4)
                #expect(preset.baseColumns == 4)
            } else {
                #expect(preset.baseRows == 8)
                #expect(preset.baseColumns == 10)
            }
        }
    }

    // MARK: - Codable

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let original = LayoutPreset(
            id: UUID(),
            name: "Test",
            selection: GridSelection(startColumn: 0, startRow: 0, endColumn: 2, endRow: 3),
            baseRows: 6,
            baseColumns: 6,
            shortcuts: [HotKeyShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey), isGlobal: true)]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LayoutPreset.self, from: data)
        #expect(decoded == original)
        #expect(decoded.shortcuts.first?.isGlobal == true)
    }

    @Test("Codable round-trip with empty shortcuts")
    func codableEmptyShortcuts() throws {
        let original = LayoutPreset(
            id: UUID(),
            name: "No Shortcut",
            selection: GridSelection(startColumn: 0, startRow: 0, endColumn: 1, endRow: 1),
            baseRows: 4,
            baseColumns: 4,
            shortcuts: []
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LayoutPreset.self, from: data)
        #expect(decoded == original)
    }

    @Test("decoding legacy globalShortcut key migrates correctly")
    func codableLegacyGlobalShortcut() throws {
        let id = UUID()
        let json = """
        {
            "id": "\(id.uuidString)",
            "name": "Legacy",
            "selection": {"startColumn": 0, "startRow": 0, "endColumn": 5, "endRow": 5},
            "baseRows": 6,
            "baseColumns": 6,
            "globalShortcut": {"keyCode": 49, "modifiers": 256}
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(LayoutPreset.self, from: data)
        #expect(!decoded.shortcuts.isEmpty)
        #expect(decoded.shortcuts.first?.keyCode == 49)
        #expect(decoded.shortcuts.first?.modifiers == 256)
        #expect(decoded.shortcuts.first?.isGlobal == true)
    }

    @Test("decoding legacy preset-level isGlobalShortcut migrates to per-shortcut")
    func codableLegacyPresetLevelGlobal() throws {
        let id = UUID()
        let json = """
        {
            "id": "\(id.uuidString)",
            "name": "LegacyGlobal",
            "selection": {"startColumn": 0, "startRow": 0, "endColumn": 5, "endRow": 5},
            "baseRows": 6,
            "baseColumns": 6,
            "shortcuts": [{"keyCode": 0, "modifiers": 256}, {"keyCode": 1, "modifiers": 512}],
            "isGlobalShortcut": true
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(LayoutPreset.self, from: data)
        #expect(decoded.shortcuts.count == 2)
        #expect(decoded.shortcuts.allSatisfy { $0.isGlobal })
    }

    // MARK: - scaledSelection

    @Test("scaledSelection delegates to GridSelection.scaled")
    func scaledSelectionDelegates() {
        let preset = LayoutPreset(
            id: UUID(),
            name: "Full",
            selection: GridSelection(startColumn: 0, startRow: 0, endColumn: 5, endRow: 5),
            baseRows: 6,
            baseColumns: 6,
            shortcuts: []
        )
        let scaled = preset.scaledSelection(toRows: 4, columns: 4)
        #expect(scaled == GridSelection(startColumn: 0, startRow: 0, endColumn: 3, endRow: 3))
    }

    @Test("scaledSelection with same dimensions returns original")
    func scaledSelectionIdentity() {
        let selection = GridSelection(startColumn: 1, startRow: 1, endColumn: 3, endRow: 4)
        let preset = LayoutPreset(
            id: UUID(),
            name: "Partial",
            selection: selection,
            baseRows: 6,
            baseColumns: 6,
            shortcuts: []
        )
        let scaled = preset.scaledSelection(toRows: 6, columns: 6)
        #expect(scaled == selection.normalized)
    }

    // MARK: - Reset Default Layouts Confirmation

    @Test("makeResetLayoutPresetsAlert creates a warning alert with Restore Defaults and Cancel")
    @MainActor
    func resetLayoutPresetsAlertConfiguration() {
        let alert = SettingsView.makeResetLayoutPresetsAlert()
        #expect(alert.messageText == NSLocalizedString("Restore Default Layouts", comment: "Alert title for restoring default layout presets"))
        #expect(alert.informativeText == NSLocalizedString("Are you sure you want to reset all layout presets to the defaults? Any custom layouts will be removed.", comment: "Alert message for restoring default layout presets"))
        #expect(alert.alertStyle == .warning)
        #expect(alert.buttons.count == 2)
        #expect(alert.buttons[0].title == NSLocalizedString("Restore Defaults", comment: "Restore defaults button title"))
        #expect(alert.buttons[1].title == NSLocalizedString("Cancel", comment: "Cancel button title"))
    }

    @Test("confirmResetLayoutPresets cancels when alert returns cancel")
    @MainActor
    func confirmResetLayoutPresetsCancellation() {
        let appState = AppState()
        let customPreset = LayoutPreset(
            id: UUID(),
            name: "Custom User Layout",
            selection: GridSelection(startColumn: 0, startRow: 0, endColumn: 1, endRow: 1),
            baseRows: appState.rows,
            baseColumns: appState.columns,
            shortcuts: []
        )
        appState.layoutPresets.append(customPreset)
        let countBefore = appState.layoutPresets.count

        let settingsView = SettingsView(appState: appState)
        settingsView.confirmResetLayoutPresets(alertRunner: { _ in .alertSecondButtonReturn })

        #expect(appState.layoutPresets.count == countBefore)
        #expect(appState.layoutPresets.contains(where: { $0.id == customPreset.id }))
    }

    @Test("confirmResetLayoutPresets resets presets when alert returns first button")
    @MainActor
    func confirmResetLayoutPresetsConfirmation() {
        let appState = AppState()
        let customPreset = LayoutPreset(
            id: UUID(),
            name: "Custom User Layout",
            selection: GridSelection(startColumn: 0, startRow: 0, endColumn: 1, endRow: 1),
            baseRows: appState.rows,
            baseColumns: appState.columns,
            shortcuts: []
        )
        appState.layoutPresets.append(customPreset)

        let settingsView = SettingsView(appState: appState)
        settingsView.confirmResetLayoutPresets(alertRunner: { _ in .alertFirstButtonReturn })

        let defaults = LayoutPreset.defaultPresets(rows: appState.rows, columns: appState.columns)
        #expect(appState.layoutPresets.count == defaults.count)
        #expect(!appState.layoutPresets.contains(where: { $0.id == customPreset.id }))
    }
}

