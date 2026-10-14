import AppKit
import Carbon
import Testing
@testable import Tiley

@Suite("PresetImportExport")
struct PresetImportExportTests {

    // MARK: - Export

    @Test("exportPresetsData encodes valid PresetExportPayload JSON")
    @MainActor
    func exportPresetsDataPayload() throws {
        let appState = AppState()
        let customPreset = LayoutPreset(
            id: UUID(),
            name: "Export Test Preset",
            selection: GridSelection(startColumn: 0, startRow: 0, endColumn: 2, endRow: 2),
            baseRows: 6,
            baseColumns: 6,
            shortcuts: [HotKeyShortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: 0, isGlobal: false)]
        )
        appState.layoutPresets = [customPreset]

        let data = try appState.exportPresetsData()
        #expect(!data.isEmpty)

        let payload = try JSONDecoder().decode(PresetExportPayload.self, from: data)
        #expect(payload.version == 1)
        #expect(payload.presets.count == 1)
        #expect(payload.presets[0].id == customPreset.id)
        #expect(payload.presets[0].name == "Export Test Preset")
    }

    // MARK: - Decoding

    @Test("decodePresetsData decodes PresetExportPayload format")
    func decodePayloadFormat() throws {
        let preset = LayoutPreset(
            id: UUID(),
            name: "Payload Preset",
            selection: GridSelection(startColumn: 0, startRow: 0, endColumn: 1, endRow: 1),
            baseRows: 4,
            baseColumns: 4,
            shortcuts: []
        )
        let payload = PresetExportPayload(version: 1, presets: [preset])
        let data = try JSONEncoder().encode(payload)

        let decoded = try AppState.decodePresetsData(data)
        #expect(decoded.count == 1)
        #expect(decoded[0].id == preset.id)
        #expect(decoded[0].name == "Payload Preset")
    }

    @Test("decodePresetsData decodes raw [LayoutPreset] array format")
    func decodeRawArrayFormat() throws {
        let preset = LayoutPreset(
            id: UUID(),
            name: "Raw Array Preset",
            selection: GridSelection(startColumn: 0, startRow: 0, endColumn: 3, endRow: 3),
            baseRows: 6,
            baseColumns: 6,
            shortcuts: []
        )
        let data = try JSONEncoder().encode([preset])

        let decoded = try AppState.decodePresetsData(data)
        #expect(decoded.count == 1)
        #expect(decoded[0].id == preset.id)
        #expect(decoded[0].name == "Raw Array Preset")
    }

    @Test("decodePresetsData throws emptyPresets when preset array is empty")
    func decodeEmptyPresetsThrows() throws {
        let payload = PresetExportPayload(version: 1, presets: [])
        let data1 = try JSONEncoder().encode(payload)
        #expect(throws: PresetImportError.emptyPresets) {
            try AppState.decodePresetsData(data1)
        }

        let data2 = try JSONEncoder().encode([LayoutPreset]())
        #expect(throws: PresetImportError.emptyPresets) {
            try AppState.decodePresetsData(data2)
        }
    }

    @Test("decodePresetsData throws invalidData for non-preset JSON")
    func decodeInvalidDataThrows() {
        let invalidData = Data("{\"notAPreset\": 123}".utf8)
        #expect(throws: PresetImportError.invalidData) {
            try AppState.decodePresetsData(invalidData)
        }

        let garbageData = Data("not json at all".utf8)
        #expect(throws: PresetImportError.invalidData) {
            try AppState.decodePresetsData(garbageData)
        }
    }

    // MARK: - Import Strategy: Replace

    @Test("importPresets with replace strategy replaces all existing presets")
    @MainActor
    func importReplaceStrategy() {
        let appState = AppState()
        let oldPreset = LayoutPreset(
            id: UUID(),
            name: "Old Preset",
            selection: GridSelection(startColumn: 0, startRow: 0, endColumn: 1, endRow: 1),
            baseRows: 6,
            baseColumns: 6,
            shortcuts: []
        )
        appState.layoutPresets = [oldPreset]

        let newPreset1 = LayoutPreset(
            id: UUID(),
            name: "Imported 1",
            selection: GridSelection(startColumn: 0, startRow: 0, endColumn: 2, endRow: 2),
            baseRows: 6,
            baseColumns: 6,
            shortcuts: []
        )
        let newPreset2 = LayoutPreset(
            id: UUID(),
            name: "Imported 2",
            selection: GridSelection(startColumn: 2, startRow: 0, endColumn: 5, endRow: 5),
            baseRows: 6,
            baseColumns: 6,
            shortcuts: []
        )

        let result = appState.importPresets([newPreset1, newPreset2], strategy: .replace)
        #expect(result.importedCount == 2)
        #expect(result.clearedShortcutsCount == 0)
        #expect(appState.layoutPresets.count == 2)
        #expect(!appState.layoutPresets.contains(where: { $0.id == oldPreset.id }))
        #expect(appState.layoutPresets[0].name == "Imported 1")
        #expect(appState.layoutPresets[1].name == "Imported 2")
        #expect(appState.selectedLayoutPresetID == newPreset1.id)
    }

    @Test("importPresets with replace strategy generates new UUID for duplicate IDs in file")
    @MainActor
    func importReplaceDuplicateIDsInFile() {
        let appState = AppState()
        let duplicateID = UUID()
        let p1 = LayoutPreset(
            id: duplicateID,
            name: "Duplicate 1",
            selection: GridSelection(startColumn: 0, startRow: 0, endColumn: 1, endRow: 1),
            baseRows: 6,
            baseColumns: 6,
            shortcuts: []
        )
        let p2 = LayoutPreset(
            id: duplicateID,
            name: "Duplicate 2",
            selection: GridSelection(startColumn: 1, startRow: 1, endColumn: 2, endRow: 2),
            baseRows: 6,
            baseColumns: 6,
            shortcuts: []
        )

        let result = appState.importPresets([p1, p2], strategy: .replace)
        #expect(result.importedCount == 2)
        #expect(appState.layoutPresets.count == 2)
        #expect(appState.layoutPresets[0].id != appState.layoutPresets[1].id)
    }

    // MARK: - Import Strategy: Append

    @Test("importPresets with append strategy keeps existing and resolves ID collisions")
    @MainActor
    func importAppendResolvesCollisions() {
        let appState = AppState()
        let existingID = UUID()
        let existingPreset = LayoutPreset(
            id: existingID,
            name: "Existing Preset",
            selection: GridSelection(startColumn: 0, startRow: 0, endColumn: 1, endRow: 1),
            baseRows: 6,
            baseColumns: 6,
            shortcuts: []
        )
        appState.layoutPresets = [existingPreset]

        // Imported preset has identical ID
        let collidingPreset = LayoutPreset(
            id: existingID,
            name: "Colliding Imported",
            selection: GridSelection(startColumn: 2, startRow: 0, endColumn: 4, endRow: 4),
            baseRows: 6,
            baseColumns: 6,
            shortcuts: []
        )

        let result = appState.importPresets([collidingPreset], strategy: .append)
        #expect(result.importedCount == 1)
        #expect(appState.layoutPresets.count == 2)
        #expect(appState.layoutPresets[0].id == existingID)
        #expect(appState.layoutPresets[1].id != existingID)
        #expect(appState.layoutPresets[1].name == "Colliding Imported")
    }

    @Test("importPresets with append strategy strips conflicting shortcuts")
    @MainActor
    func importAppendStripsConflictingShortcuts() {
        let appState = AppState()
        let sharedShortcut = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: 0, isGlobal: false)
        let uniqueShortcut = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: 0, isGlobal: false)

        let existingPreset = LayoutPreset(
            id: UUID(),
            name: "Existing Preset",
            selection: GridSelection(startColumn: 0, startRow: 0, endColumn: 1, endRow: 1),
            baseRows: 6,
            baseColumns: 6,
            shortcuts: [sharedShortcut]
        )
        appState.layoutPresets = [existingPreset]

        let importedPreset = LayoutPreset(
            id: UUID(),
            name: "Imported Preset",
            selection: GridSelection(startColumn: 1, startRow: 1, endColumn: 2, endRow: 2),
            baseRows: 6,
            baseColumns: 6,
            shortcuts: [sharedShortcut, uniqueShortcut]
        )

        let result = appState.importPresets([importedPreset], strategy: .append)
        #expect(result.importedCount == 1)
        #expect(result.clearedShortcutsCount == 1)
        #expect(appState.layoutPresets.count == 2)

        let appended = appState.layoutPresets[1]
        #expect(appended.shortcuts.count == 1)
        #expect(appended.shortcuts[0] == uniqueShortcut)
    }


    // MARK: - Alerts

    @Test("makeImportOptionsAlert sets up informational alert with 3 buttons")
    @MainActor
    func importOptionsAlertConfiguration() {
        let alert = SettingsView.makeImportOptionsAlert(presetCount: 5)
        #expect(alert.alertStyle == .informational)
        #expect(alert.messageText == NSLocalizedString("Import Presets", comment: "Alert title for importing presets"))
        #expect(alert.informativeText.contains("5"))
        #expect(alert.buttons.count == 3)
        #expect(alert.buttons[0].title == NSLocalizedString("Add to Existing", comment: "Add to existing presets button"))
        #expect(alert.buttons[1].title == NSLocalizedString("Replace All", comment: "Replace all presets button"))
        #expect(alert.buttons[2].title == NSLocalizedString("Cancel", comment: "Cancel button title"))
    }

    @Test("makeImportSuccessAlert configures correct message")
    @MainActor
    func importSuccessAlertConfiguration() {
        let cleanResult = PresetImportResult(importedCount: 3, clearedShortcutsCount: 0)
        let cleanAlert = SettingsView.makeImportSuccessAlert(result: cleanResult)
        #expect(cleanAlert.messageText == NSLocalizedString("Import Succeeded", comment: "Import succeeded alert title"))
        #expect(cleanAlert.informativeText.contains("3"))
        #expect(!cleanAlert.informativeText.contains("conflicting"))

        let conflictResult = PresetImportResult(importedCount: 4, clearedShortcutsCount: 2)
        let conflictAlert = SettingsView.makeImportSuccessAlert(result: conflictResult)
        #expect(conflictAlert.informativeText.contains("4"))
        #expect(conflictAlert.informativeText.contains("2"))
    }

    @Test("makeImportErrorAlert and makeExportErrorAlert configure warning alerts")
    @MainActor
    func importExportErrorAlertsConfiguration() {
        let importAlert = SettingsView.makeImportErrorAlert(error: PresetImportError.invalidData)
        #expect(importAlert.alertStyle == .warning)
        #expect(importAlert.messageText == NSLocalizedString("Import Failed", comment: "Import failed alert title"))
        #expect(importAlert.informativeText == PresetImportError.invalidData.localizedDescription)

        let exportAlert = SettingsView.makeExportErrorAlert(error: PresetImportError.emptyPresets)
        #expect(exportAlert.alertStyle == .warning)
        #expect(exportAlert.messageText == NSLocalizedString("Export Failed", comment: "Export failed alert title"))
    }

    // MARK: - SettingsView Integration

    @Test("SettingsView exportPresets cancels when panelRunner returns cancel")
    @MainActor
    func settingsViewExportCancellation() {
        let appState = AppState()
        let settingsView = SettingsView(appState: appState)
        var errorAlertShown = false

        settingsView.exportPresets(
            panelRunner: { _ in (.cancel, nil) },
            alertRunner: { _ in errorAlertShown = true; return .alertFirstButtonReturn }
        )

        #expect(!errorAlertShown)
    }

    @Test("SettingsView exportPresets writes valid presets JSON file on OK")
    @MainActor
    func settingsViewExportSuccess() throws {
        let appState = AppState()
        let preset = LayoutPreset(
            id: UUID(),
            name: "Integration Test Preset",
            selection: GridSelection(startColumn: 0, startRow: 0, endColumn: 2, endRow: 2),
            baseRows: 6,
            baseColumns: 6,
            shortcuts: []
        )
        appState.layoutPresets = [preset]

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_export_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let settingsView = SettingsView(appState: appState)
        var errorAlertShown = false

        settingsView.exportPresets(
            panelRunner: { _ in (.OK, tempURL) },
            alertRunner: { _ in errorAlertShown = true; return .alertFirstButtonReturn }
        )

        #expect(!errorAlertShown)
        let fileData = try Data(contentsOf: tempURL)
        let decoded = try JSONDecoder().decode(PresetExportPayload.self, from: fileData)
        #expect(decoded.presets.count == 1)
        #expect(decoded.presets[0].name == "Integration Test Preset")
    }

    @Test("SettingsView importPresets shows error alert on corrupted file")
    @MainActor
    func settingsViewImportCorruptedFile() throws {
        let appState = AppState()
        let settingsView = SettingsView(appState: appState)

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("corrupted_\(UUID().uuidString).json")
        try Data("invalid json".utf8).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var errorAlertMessage: String?

        settingsView.importPresets(
            panelRunner: { _ in (.OK, tempURL) },
            optionsAlertRunner: { _ in .alertFirstButtonReturn },
            resultAlertRunner: { _ in .alertFirstButtonReturn },
            errorAlertRunner: { alert in
                errorAlertMessage = alert.messageText
                return .alertFirstButtonReturn
            }
        )

        #expect(errorAlertMessage == NSLocalizedString("Import Failed", comment: "Import failed alert title"))
    }

    @Test("SettingsView importPresets successfully imports presets on valid file")
    @MainActor
    func settingsViewImportSuccess() throws {
        let appState = AppState()
        appState.layoutPresets = []
        let settingsView = SettingsView(appState: appState)

        let preset = LayoutPreset(
            id: UUID(),
            name: "Imported via Settings",
            selection: GridSelection(startColumn: 0, startRow: 0, endColumn: 3, endRow: 3),
            baseRows: 6,
            baseColumns: 6,
            shortcuts: []
        )
        let payload = PresetExportPayload(version: 1, presets: [preset])
        let data = try JSONEncoder().encode(payload)

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("valid_\(UUID().uuidString).json")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var successAlertShown = false

        settingsView.importPresets(
            panelRunner: { _ in (.OK, tempURL) },
            optionsAlertRunner: { _ in .alertFirstButtonReturn }, // Add to Existing
            resultAlertRunner: { _ in
                successAlertShown = true
                return .alertFirstButtonReturn
            },
            errorAlertRunner: { _ in .alertFirstButtonReturn }
        )

        #expect(successAlertShown)
        #expect(appState.layoutPresets.count == 1)
        #expect(appState.layoutPresets[0].name == "Imported via Settings")
    }
}


