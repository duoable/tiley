import AppKit
import Testing
@testable import Tiley

@Suite("DisplayCycle")
struct DisplayCycleTests {

    // MARK: - Frame Approximation

    @Test("isWindowFrame matches identical frames")
    func identicalFramesMatch() {
        let frame = CGRect(x: 100, y: 150, width: 800, height: 600)
        #expect(AppState.isWindowFrame(frame, approximatelyMatching: frame))
    }

    @Test("isWindowFrame tolerates sub-threshold point differences")
    func frameSlightDifferenceMatches() {
        let frameA = CGRect(x: 100, y: 150, width: 800, height: 600)
        let frameB = CGRect(x: 101.5, y: 149.0, width: 802.0, height: 598.5)
        #expect(AppState.isWindowFrame(frameA, approximatelyMatching: frameB, tolerance: 3.0))
    }

    @Test("isWindowFrame rejects frames exceeding position tolerance")
    func positionExceedingToleranceFails() {
        let frameA = CGRect(x: 100, y: 150, width: 800, height: 600)
        let frameB = CGRect(x: 105, y: 150, width: 800, height: 600)
        #expect(!AppState.isWindowFrame(frameA, approximatelyMatching: frameB, tolerance: 3.0))
    }

    @Test("isWindowFrame rejects frames exceeding size tolerance")
    func sizeExceedingToleranceFails() {
        let frameA = CGRect(x: 100, y: 150, width: 800, height: 600)
        let frameB = CGRect(x: 100, y: 150, width: 850, height: 600)
        #expect(!AppState.isWindowFrame(frameA, approximatelyMatching: frameB, tolerance: 3.0))
    }

    // MARK: - SettingsSnapshot

    @Test("SettingsSnapshot includes cycleDisplaysOnRepeatedShortcut")
    func settingsSnapshotProperty() {
        var snapshot = AppState.SettingsSnapshot(
            columns: 6,
            rows: 6,
            gap: 0,
            hotKeyShortcut: .default,
            launchAtLoginEnabled: false,
            menuIconVisible: true,
            dockIconVisible: false,
            quitAppOnLastWindowClose: true,
            showNearIcon: true,
            enableDebugLog: false,
            debugSimulateUpdate: false,
            displayShortcutSettings: .default,
            cycleDisplaysOnRepeatedShortcut: false
        )
        #expect(!snapshot.cycleDisplaysOnRepeatedShortcut)

        snapshot.cycleDisplaysOnRepeatedShortcut = true
        #expect(snapshot.cycleDisplaysOnRepeatedShortcut)
    }

    @Test("SettingsSnapshot inequality when cycleDisplaysOnRepeatedShortcut differs")
    func settingsSnapshotEquality() {
        let s1 = AppState.SettingsSnapshot(
            columns: 6,
            rows: 6,
            gap: 0,
            hotKeyShortcut: .default,
            launchAtLoginEnabled: false,
            menuIconVisible: true,
            dockIconVisible: false,
            quitAppOnLastWindowClose: true,
            showNearIcon: true,
            enableDebugLog: false,
            debugSimulateUpdate: false,
            displayShortcutSettings: .default,
            cycleDisplaysOnRepeatedShortcut: false
        )
        var s2 = s1
        s2.cycleDisplaysOnRepeatedShortcut = true

        #expect(s1 != s2)
    }

    // MARK: - Cycling Condition Guards

    @Test("targetScreenForPreset returns nil when cycleDisplaysOnRepeatedShortcut is disabled")
    @MainActor
    func targetScreenReturnsNilWhenDisabled() {
        let appState = AppState()
        appState.cycleDisplaysOnRepeatedShortcut = false

        let dummyApp = AXUIElementCreateSystemWide()
        let dummyTarget = WindowTarget(
            appElement: dummyApp,
            windowElement: nil,
            processIdentifier: 1234,
            appName: "TestApp",
            windowTitle: "TestWindow",
            frame: CGRect(x: 0, y: 0, width: 500, height: 500),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            isHidden: false
        )

        let presetID = UUID()
        let result = appState.targetScreenForPreset(id: presetID, currentTarget: dummyTarget)
        #expect(result == nil)
    }
}
