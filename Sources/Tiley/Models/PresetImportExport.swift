import Foundation

struct PresetExportPayload: Codable, Equatable {
    var version: Int
    var presets: [LayoutPreset]

    init(version: Int = 1, presets: [LayoutPreset]) {
        self.version = version
        self.presets = presets
    }
}

enum PresetImportStrategy: Equatable {
    case append
    case replace
}

struct PresetImportResult: Equatable {
    let importedCount: Int
    let clearedShortcutsCount: Int

    init(importedCount: Int, clearedShortcutsCount: Int = 0) {
        self.importedCount = importedCount
        self.clearedShortcutsCount = clearedShortcutsCount
    }
}

enum PresetImportError: LocalizedError, Equatable {
    case invalidData
    case emptyPresets

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return NSLocalizedString("The selected file does not contain valid Tiley presets.", comment: "Import invalid data error")
        case .emptyPresets:
            return NSLocalizedString("The selected file contains no layout presets.", comment: "Import empty presets error")
        }
    }
}
