import AppKit
import TelemetryDeck

extension AppState {

    // MARK: - Reset / Update / Move

    func resetLayoutPresetsToDefault() {
        layoutPresets = LayoutPreset.defaultPresets(rows: rows, columns: columns)
        selectedLayoutPresetID = layoutPresets.first?.id
        saveLayoutPresets()
        registerPresetHotKeys()
    }

    func updateLayoutPreset(_ id: UUID, mutate: (inout LayoutPreset) -> Void) {
        guard let index = layoutPresets.firstIndex(where: { $0.id == id }) else { return }
        let shortcutsBefore = layoutPresets[index].shortcuts
        mutate(&layoutPresets[index])
        sanitizeShortcutGlobalFlags(for: &layoutPresets[index])
        selectedLayoutPresetID = id
        saveLayoutPresets()
        // Re-registering tears down and re-creates every Carbon hotkey;
        // it's only needed when this edit actually touched the shortcuts
        // (renames, app assignments, rectangle edits, etc. don't).
        // `HotKeyShortcut.==` ignores `isGlobal`, so compare it explicitly:
        // switching a shortcut between local and global must re-register.
        let shortcutsAfter = layoutPresets[index].shortcuts
        if shortcutsAfter != shortcutsBefore
            || shortcutsAfter.map(\.isGlobal) != shortcutsBefore.map(\.isGlobal) {
            registerPresetHotKeys()
        }
    }

    /// Creates a new blank layout preset, appends it to `layoutPresets`, and returns its ID.
    /// The caller is responsible for entering edit mode on the returned preset.
    @discardableResult
    func createNewLayoutPreset() -> UUID {
        let preset = LayoutPreset(
            id: UUID(),
            name: NSLocalizedString("New Layout Preset", comment: "Default name for a newly created layout preset"),
            selection: LayoutPreset.emptySelection,
            baseRows: rows,
            baseColumns: columns,
            shortcuts: []
        )
        layoutPresets.append(preset)
        selectedLayoutPresetID = preset.id
        saveLayoutPresets()
        // A brand-new preset has no shortcuts — no hotkey re-registration needed.
        return preset.id
    }

    func moveLayoutPreset(from sourceID: UUID?, to targetID: UUID) {
        guard let sourceID else { return }
        guard sourceID != targetID else { return }
        guard let sourceIndex = layoutPresets.firstIndex(where: { $0.id == sourceID }) else { return }
        let preset = layoutPresets.remove(at: sourceIndex)
        let targetIndex = layoutPresets.firstIndex(where: { $0.id == targetID }) ?? layoutPresets.count
        let insertIndex = min(max(0, targetIndex), layoutPresets.count)
        layoutPresets.insert(preset, at: insertIndex)
        selectedLayoutPresetID = preset.id
        saveLayoutPresets()
        // Reordering doesn't change any shortcut — hotkey registrations map
        // IDs to preset UUIDs directly and are order-independent.
    }

    func moveLayoutPreset(from sourceID: UUID?, toIndex targetIndex: Int) {
        guard let sourceID else { return }
        guard let sourceIndex = layoutPresets.firstIndex(where: { $0.id == sourceID }) else { return }

        let preset = layoutPresets.remove(at: sourceIndex)
        var insertIndex = targetIndex
        if sourceIndex < targetIndex {
            insertIndex = max(0, insertIndex - 1)
        }
        insertIndex = min(max(0, insertIndex), layoutPresets.count)

        guard insertIndex != sourceIndex else {
            layoutPresets.insert(preset, at: sourceIndex)
            return
        }

        layoutPresets.insert(preset, at: insertIndex)
        selectedLayoutPresetID = preset.id
        saveLayoutPresets()
        // See moveLayoutPreset(from:to:) — order-independent registrations.
    }

    // MARK: - Query / Select / Apply

    func selectLayoutPreset(_ id: UUID) {
        // Skip no-op writes: `@Observable` invalidates observers on every
        // set regardless of value, and every display's view reads this.
        if selectedLayoutPresetID != id {
            selectedLayoutPresetID = id
        }
    }

    func applyLayoutPreset(id: UUID) {
        guard let preset = layoutPreset(for: id) else { return }
        guard accessibilityGranted || accessibilityService.checkAccess(prompt: false) else {
            requestAccessibilityAccess()
            return
        }
        // Wait for the authoritative window list before picking targets.
        if deferUntilWindowListReady({ [weak self] in self?.applyLayoutPreset(id: id) }) { return }
        let target: WindowTarget
        if let existing = activeLayoutTarget {
            target = existing
        } else {
            guard let resolved = resolveWindowTarget() else { return }
            target = resolved
        }

        activeLayoutTarget = target
        lastTargetPID = target.processIdentifier
        selectedLayoutPresetID = id

        if handleTogglePresetIfApplicable(preset: preset, target: target) {
            return
        }

        if let next = targetScreenForPreset(id: id, currentTarget: target) {
            applyLayoutPresetOnScreen(id: id, visibleFrame: next.visibleFrame, screenFrame: next.frame)
            return
        }

        executePresetLayout(preset: preset, target: target)
        TelemetryDeck.signal("presetApplied", parameters: ["presetName": preset.name])
    }

    func executePresetLayout(preset: LayoutPreset, target: WindowTarget) {
        guard !preset.isEmpty else {
            if let win = target.windowElement {
                accessibilityService.minimizeWindow(win)
            }
            presetMinimizedWindows[preset.id] = [PresetWindowRecord(cgWindowID: target.cgWindowID, pid: target.processIdentifier, windowElement: target.windowElement)]
            finalizeLayoutApplication()
            return
        }

        let allSelections = preset.allScaledSelections(toRows: rows, columns: columns)
        let rectangleApps = preset.normalizedRectangleApps
        let hasAnyAssignment = rectangleApps.contains(where: { $0 != nil })

        if hasAnyAssignment {
            Task { @MainActor [self] in
                await applyPresetWithAppAssignments(
                    presetID: preset.id,
                    allSelections: allSelections,
                    rectangleApps: rectangleApps,
                    groupedPairs: preset.groupedPairs,
                    anchorTarget: target,
                    presetName: preset.name
                )
            }
            return
        }

        if selectedWindowIndices.count > 1 {
            if selectedWindowIndices.count >= allSelections.count {
                // Enough selected windows — use explicit selection order.
                let selection = allSelections[0]
                let secondarySelections = Array(allSelections.dropFirst())
                applyToMultipleWindows(selection: selection, secondarySelections: secondarySelections, groupedPairs: preset.groupedPairs)
            } else {
                // Not enough selected windows — selected first, fill from z-order.
                applyPresetToZOrderedWindows(selections: allSelections, groupedPairs: preset.groupedPairs)
            }
        } else if allSelections.count > 1 {
            // Single window but multi-layout preset — fill from z-order.
            applyPresetToZOrderedWindows(selections: allSelections, groupedPairs: preset.groupedPairs)
        } else {
            apply(selection: allSelections.first ?? preset.scaledSelection(toRows: rows, columns: columns), to: target)
        }
    }

    // MARK: - Toggle to Minimize / Restore

    /// Checks whether the preset should toggle (minimize or unminimize) instead of performing standard layout.
    /// Returns `true` if a toggle action was executed.
    @discardableResult
    func handleTogglePresetIfApplicable(preset: LayoutPreset, target: WindowTarget) -> Bool {
        // If toggleToMinimize is false AND the preset is not empty, do not toggle.
        guard preset.toggleToMinimize || preset.isEmpty else { return false }

        let presetID = preset.id

        // Phase 1: Unminimize check.
        // If we previously minimized windows for this preset and any of them are still minimized, restore them.
        if let recorded = presetMinimizedWindows[presetID], !recorded.isEmpty {
            var anyStillMinimized = false
            for rec in recorded {
                if let element = rec.windowElement, accessibilityService.isWindowMinimized(element) {
                    anyStillMinimized = true
                    break
                }
                if !accessibilityService.minimizedWindows(for: rec.pid).isEmpty {
                    anyStillMinimized = true
                    break
                }
            }

            if anyStillMinimized {
                for rec in recorded {
                    if let element = rec.windowElement {
                        accessibilityService.unminimizeWindow(element)
                        accessibilityService.raiseWindow(element)
                    } else {
                        for win in accessibilityService.minimizedWindows(for: rec.pid) {
                            accessibilityService.unminimizeWindow(win)
                            accessibilityService.raiseWindow(win)
                        }
                    }
                    NSRunningApplication(processIdentifier: rec.pid)?.activate()
                }

                presetMinimizedWindows[presetID] = nil
                dismissOverlayImmediately()
                orderOutAllMainWindows()

                if !preset.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        guard let self else { return }
                        self.activeLayoutTarget = target
                        self.executePresetLayout(preset: preset, target: target)
                    }
                } else {
                    finalizeLayoutApplication()
                }
                return true
            }
        }

        // Phase 2: Minimize check.
        // If the preset is completely empty (no tiles selected):
        if preset.isEmpty {
            let targetsToMinimize: [WindowTarget]
            if selectedWindowIndices.count > 1 {
                targetsToMinimize = selectedWindowIndices.compactMap { idx in
                    idx < availableWindowTargets.count ? availableWindowTargets[idx] : nil
                }
            } else {
                targetsToMinimize = [target]
            }

            guard !targetsToMinimize.isEmpty else { return true }

            var records: [PresetWindowRecord] = []
            for t in targetsToMinimize {
                if let win = t.windowElement {
                    accessibilityService.minimizeWindow(win)
                }
                records.append(PresetWindowRecord(cgWindowID: t.cgWindowID, pid: t.processIdentifier, windowElement: t.windowElement))
            }

            presetMinimizedWindows[presetID] = records
            presetPlacedWindows[presetID] = nil
            dismissOverlayImmediately()
            orderOutAllMainWindows()
            finalizeLayoutApplication()
            return true
        }

        // For non-empty presets with toggleToMinimize == true:
        // Check if the preset's target windows are currently in their layout positions and active.
        let isAlreadyArranged: Bool

        let rectangleApps = preset.normalizedRectangleApps
        let hasAnyAssignment = rectangleApps.contains(where: { $0 != nil })

        let currentVisibleFrame: CGRect = {
            if let screen = NSScreen.screens.first(where: { $0.frame == target.screenFrame }) {
                return screen.visibleFrame
            }
            return target.visibleFrame
        }()

        if hasAnyAssignment {
            var allMatch = true
            var foundAny = false
            let allSelections = preset.allScaledSelections(toRows: rows, columns: columns)

            for (idx, maybeBID) in rectangleApps.enumerated() {
                guard let bid = maybeBID, idx < allSelections.count else { continue }
                guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bid }) else {
                    allMatch = false
                    break
                }
                guard let winTarget = availableWindowTargets.first(where: { $0.processIdentifier == app.processIdentifier }) else {
                    allMatch = false
                    break
                }
                let expected = GridCalculator.frame(for: allSelections[idx], in: currentVisibleFrame, rows: rows, columns: columns, gap: gap)
                if !Self.isWindowFrame(winTarget.frame, approximatelyMatching: expected, tolerance: 5.0) {
                    allMatch = false
                    break
                }
                foundAny = true
            }
            isAlreadyArranged = foundAny && allMatch
        } else {
            let allSelections = preset.allScaledSelections(toRows: rows, columns: columns)

            if allSelections.count <= 1 {
                let expected = GridCalculator.frame(
                    for: allSelections.first ?? preset.scaledSelection(toRows: rows, columns: columns),
                    in: currentVisibleFrame,
                    rows: rows,
                    columns: columns,
                    gap: gap
                )
                let matchesExpected = Self.isWindowFrame(target.frame, approximatelyMatching: expected, tolerance: 5.0)
                let matchesRecorded = (lastPresetPlacement?.windowID == target.cgWindowID
                    && lastPresetPlacement?.presetID == presetID
                    && Self.isWindowFrame(target.frame, approximatelyMatching: lastPresetPlacement!.frame, tolerance: 5.0))
                isAlreadyArranged = matchesExpected || matchesRecorded
            } else {
                if let placedIDs = presetPlacedWindows[presetID], placedIDs.count >= allSelections.count {
                    var allMatch = true
                    for (i, wid) in placedIDs.prefix(allSelections.count).enumerated() {
                        guard let current = availableWindowTargets.first(where: { $0.cgWindowID == wid }) else {
                            allMatch = false
                            break
                        }
                        let expected = GridCalculator.frame(for: allSelections[i], in: currentVisibleFrame, rows: rows, columns: columns, gap: gap)
                        if !Self.isWindowFrame(current.frame, approximatelyMatching: expected, tolerance: 5.0) {
                            allMatch = false
                            break
                        }
                    }
                    isAlreadyArranged = allMatch
                } else {
                    isAlreadyArranged = false
                }
            }
        }

        if isAlreadyArranged {
            var records: [PresetWindowRecord] = []
            let windowsToMinimize: [WindowTarget]

            if hasAnyAssignment {
                windowsToMinimize = rectangleApps.compactMap { maybeBID in
                    guard let bid = maybeBID else { return nil }
                    guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bid }) else { return nil }
                    return availableWindowTargets.first(where: { $0.processIdentifier == app.processIdentifier })
                }
            } else if let placedIDs = presetPlacedWindows[presetID], !placedIDs.isEmpty {
                windowsToMinimize = placedIDs.compactMap { wid in
                    availableWindowTargets.first(where: { $0.cgWindowID == wid })
                }
            } else {
                windowsToMinimize = [target]
            }

            for t in windowsToMinimize {
                if let win = t.windowElement {
                    accessibilityService.minimizeWindow(win)
                }
                records.append(PresetWindowRecord(cgWindowID: t.cgWindowID, pid: t.processIdentifier, windowElement: t.windowElement))
            }

            presetMinimizedWindows[presetID] = records
            presetPlacedWindows[presetID] = nil
            dismissOverlayImmediately()
            orderOutAllMainWindows()
            finalizeLayoutApplication()
            return true
        }

        return false
    }

    /// Applies a layout preset on the screen where the mouse cursor is located.
    /// Falls back to the target window's screen when the cursor screen cannot be determined.
    func applyPresetOnMouseScreen(id: UUID) {
        let mouseLocation = NSEvent.mouseLocation
        let baseScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
        guard let baseScreen else {
            applyLayoutPreset(id: id)
            return
        }

        let target: WindowTarget
        if let existing = activeLayoutTarget {
            target = existing
        } else if let resolved = resolveWindowTarget() {
            target = resolved
        } else {
            applyLayoutPresetOnScreen(id: id, visibleFrame: baseScreen.visibleFrame, screenFrame: baseScreen.frame)
            return
        }

        activeLayoutTarget = target
        lastTargetPID = target.processIdentifier
        selectedLayoutPresetID = id

        if let next = targetScreenForPreset(id: id, currentTarget: target, on: baseScreen) {
            applyLayoutPresetOnScreen(id: id, visibleFrame: next.visibleFrame, screenFrame: next.frame)
        } else {
            applyLayoutPresetOnScreen(id: id, visibleFrame: baseScreen.visibleFrame, screenFrame: baseScreen.frame)
        }
    }

    // MARK: - Display Cycling on Repeated Shortcut

    /// Returns true if two window frames match within a small point tolerance.
    nonisolated static func isWindowFrame(_ current: CGRect, approximatelyMatching target: CGRect, tolerance: CGFloat = 3.0) -> Bool {
        abs(current.minX - target.minX) <= tolerance &&
        abs(current.minY - target.minY) <= tolerance &&
        abs(current.width - target.width) <= tolerance &&
        abs(current.height - target.height) <= tolerance
    }

    /// Returns the next display in physical arrangement order (or connected displays order).
    func nextScreen(after currentScreen: NSScreen) -> NSScreen? {
        let resolver = displayFingerprintResolverForHotKeys()
        let sortedScreens = resolver.displays.map(\.screen)
        let screens = !sortedScreens.isEmpty ? sortedScreens : NSScreen.screens
        guard screens.count > 1 else { return nil }

        let currentIndex = screens.firstIndex(where: { $0.displayID == currentScreen.displayID }) ?? 0
        let nextIndex = (currentIndex + 1) % screens.count
        return screens[nextIndex]
    }

    /// When `cycleDisplaysOnRepeatedShortcut` is enabled and the target window is already in the layout preset's position
    /// on its current screen, returns the next display to cycle to. Otherwise returns nil.
    func targetScreenForPreset(id: UUID, currentTarget: WindowTarget, on preferredScreen: NSScreen? = nil) -> NSScreen? {
        guard cycleDisplaysOnRepeatedShortcut else { return nil }
        guard NSScreen.screens.count > 1 else { return nil }
        guard let preset = layoutPreset(for: id) else { return nil }

        let currentScreen: NSScreen
        if let preferred = preferredScreen {
            currentScreen = preferred
        } else if let matching = NSScreen.screens.first(where: { $0.frame == currentTarget.screenFrame }) {
            currentScreen = matching
        } else {
            currentScreen = NSScreen.screens.max(by: { a, b in
                a.frame.intersection(currentTarget.frame).area < b.frame.intersection(currentTarget.frame).area
            }) ?? NSScreen.screens[0]
        }

        let primarySelection = preset.allScaledSelections(toRows: rows, columns: columns).first
            ?? preset.scaledSelection(toRows: rows, columns: columns)
        let expectedFrame = GridCalculator.frame(
            for: primarySelection,
            in: currentScreen.visibleFrame,
            rows: rows,
            columns: columns,
            gap: gap
        )

        let isAtExpected = Self.isWindowFrame(currentTarget.frame, approximatelyMatching: expectedFrame)
        let isAtRecordedConstrained = lastPresetPlacement?.windowID == currentTarget.cgWindowID
            && lastPresetPlacement?.presetID == id
            && lastPresetPlacement?.displayID == currentScreen.displayID
            && Self.isWindowFrame(currentTarget.frame, approximatelyMatching: lastPresetPlacement!.frame)

        if isAtExpected || isAtRecordedConstrained {
            return nextScreen(after: currentScreen)
        }
        return nil
    }

    func handleLocalShortcut(_ shortcut: HotKeyShortcut) -> Bool {
        guard isShowingLayoutGrid, !isEditingSettings else { return false }

        // When in modifier-held mode, also try matching with the toggle
        // modifiers stripped (e.g. Shift+Cmd+M → M).
        let candidates = [shortcut, strippedShortcut(shortcut)].compactMap { $0 }

        for s in candidates {
            if let preset = layoutPresets.first(where: { $0.localShortcuts.contains(s) }) {
                removeModifierReleaseMonitor()
                applyPresetOnMouseScreen(id: preset.id)
                return true
            }
            if let action = displayShortcutLocalAction(for: s) {
                removeModifierReleaseMonitor()
                executeDisplayShortcutLocal(action)
                return true
            }
        }
        return false
    }

    // MARK: - Remove

    func removeLayoutPreset(id: UUID) {
        guard let index = layoutPresets.firstIndex(where: { $0.id == id }) else { return }
        layoutPresets.remove(at: index)
        if selectedLayoutPresetID == id {
            selectedLayoutPresetID = layoutPresets.first?.id
        }
        saveLayoutPresets()
        registerPresetHotKeys()
    }

    // MARK: - Lookup

    func layoutPreset(for id: UUID) -> LayoutPreset? {
        layoutPresets.first(where: { $0.id == id })
    }

    // MARK: - Edge alignment after multi-rectangle preset application

    /// After a multi-rectangle preset has been applied, walk the grid-level
    /// adjacencies and — when one window of an adjacent pair was forced
    /// larger than its target by its app's minimum-size constraint — adjust
    /// the *other* window's width/height so the shared edge stays aligned
    /// (preserving the preset gap). Best-effort: if both windows are
    /// constrained on the relevant axis the pair is left as-is.
    ///
    /// `placements` is in apply order; only the first placement per
    /// `selectionIndex` participates (extras piled on the last selection are
    /// ignored).
    func alignAdjacentEdgesAfterPreset(
        placements: [(selectionIndex: Int, target: WindowTarget, targetFrame: CGRect)],
        selections: [GridSelection],
        screenFrame: CGRect
    ) {
        guard placements.count >= 2, selections.count >= 2 else { return }
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0

        var windowBySel: [Int: AXUIElement] = [:]
        var targetFrameBySel: [Int: CGRect] = [:]
        var actualFrameBySel: [Int: CGRect] = [:]
        for placement in placements {
            let sel = placement.selectionIndex
            guard windowBySel[sel] == nil else { continue }
            guard let window = placement.target.windowElement else { continue }
            let (pos, size) = accessibilityService.readPositionAndSize(of: window)
            guard size.width > 0, size.height > 0 else { continue }
            let appkitMinY = primaryMaxY - (pos.y + size.height)
            windowBySel[sel] = window
            targetFrameBySel[sel] = placement.targetFrame
            actualFrameBySel[sel] = CGRect(x: pos.x, y: appkitMinY, width: size.width, height: size.height)
        }

        let adjacencies = SelectionAdjacencyDetector.detect(selections: selections)
        let epsilon: CGFloat = 2
        let minDim: CGFloat = 40

        for adj in adjacencies {
            guard let winA = windowBySel[adj.indexA],
                  let winB = windowBySel[adj.indexB],
                  winA != winB,
                  let actualA = actualFrameBySel[adj.indexA],
                  let actualB = actualFrameBySel[adj.indexB],
                  let targetA = targetFrameBySel[adj.indexA],
                  let targetB = targetFrameBySel[adj.indexB] else { continue }

            let horizontal = (adj.edgeOfA == .left || adj.edgeOfA == .right)
            let dimA = horizontal ? actualA.width : actualA.height
            let dimB = horizontal ? actualB.width : actualB.height
            let tDimA = horizontal ? targetA.width : targetA.height
            let tDimB = horizontal ? targetB.width : targetB.height
            let aOversized = dimA > tDimA + epsilon
            let bOversized = dimB > tDimB + epsilon
            if !aOversized && !bOversized { continue }
            if aOversized && bOversized { continue }

            // The oversized window is the anchor; its actual edge sets the
            // alignment target. The other window is reshaped to match.
            let anchorIsA = aOversized
            let anchorActual = anchorIsA ? actualA : actualB
            let anchorTarget = anchorIsA ? targetA : targetB
            let adjustableTarget = anchorIsA ? targetB : targetA
            let adjustableWindow: AXUIElement = anchorIsA ? winB : winA

            // The adjustable window's edge that faces the anchor.
            let nearEdge: WindowAdjacency.Edge
            switch adj.edgeOfA {
            case .right: nearEdge = anchorIsA ? .left  : .right
            case .left:  nearEdge = anchorIsA ? .right : .left
            case .bottom: nearEdge = anchorIsA ? .top    : .bottom
            case .top:    nearEdge = anchorIsA ? .bottom : .top
            }

            var newFrame = adjustableTarget
            let farEdge: WindowAdjacency.Edge
            let farValue: CGFloat
            switch nearEdge {
            case .left:
                // Adjustable is right of anchor.
                let gapValue = adjustableTarget.minX - anchorTarget.maxX
                let newMinX = anchorActual.maxX + gapValue
                farEdge = .right
                farValue = adjustableTarget.maxX
                newFrame.origin.x = newMinX
                newFrame.size.width = farValue - newMinX
            case .right:
                // Adjustable is left of anchor.
                let gapValue = anchorTarget.minX - adjustableTarget.maxX
                let newMaxX = anchorActual.minX - gapValue
                farEdge = .left
                farValue = adjustableTarget.minX
                newFrame.origin.x = farValue
                newFrame.size.width = newMaxX - farValue
            case .bottom:
                // Adjustable sits below anchor in screen layout (anchor.minY > adjustable.maxY).
                let gapValue = anchorTarget.minY - adjustableTarget.maxY
                let newMaxY = anchorActual.minY - gapValue
                farEdge = .bottom
                farValue = adjustableTarget.minY
                newFrame.origin.y = farValue
                newFrame.size.height = newMaxY - farValue
            case .top:
                // Adjustable sits above anchor.
                let gapValue = adjustableTarget.minY - anchorTarget.maxY
                let newMinY = anchorActual.maxY + gapValue
                farEdge = .top
                farValue = adjustableTarget.maxY
                newFrame.origin.y = newMinY
                newFrame.size.height = farValue - newMinY
            }

            if newFrame.width < minDim || newFrame.height < minDim { continue }
            if abs(newFrame.minX - adjustableTarget.minX) < epsilon &&
               abs(newFrame.minY - adjustableTarget.minY) < epsilon &&
               abs(newFrame.width - adjustableTarget.width) < epsilon &&
               abs(newFrame.height - adjustableTarget.height) < epsilon {
                continue
            }

            _ = accessibilityService.setFrameLightweightPreservingEdge(
                newFrame,
                preservingEdge: farEdge,
                edgeValue: farValue,
                on: screenFrame,
                for: adjustableWindow
            )
        }
    }
}
