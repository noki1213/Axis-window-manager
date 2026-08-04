//
//  TilingEngine.swift
//  Axis
//
//  Created on 2026/01/27.
//

import AppKit
import Combine

/// Handles computing and applying the tiling layout
class TilingEngine: ObservableObject {
    static let shared = TilingEngine()
    
    // MARK: - Configuration
    
    /// The gap between windows (in pixels)
    @Published var windowGap: CGFloat = 12
    
    /// The padding from the screen edge (in pixels)
    @Published var screenPadding: CGFloat = 12
    
    /// The menu bar's height (normally 25pt)
    var menuBarHeight: CGFloat = 25
    
    // MARK: - State

    /// The windows currently tiled (per screen, per column)
    /// The outer array is "columns," the inner array is "the windows within a column (top to bottom)"
    @Published var tiledWindows: [ScreenIdentifier: [[WindowInfo]]] = [:]

    /// Record the monitor when the mouse moves to an empty one
    /// Used for focus movement and Space switching when there's no focused window
    /// Automatically reset to nil once focus moves to the window
    var cursorScreen: NSScreen?

    private let accessibilityManager = AccessibilityManager.shared

    private init() {}
    
    // MARK: - Public Methods
    
    /// Run tiling on the given screen
    func tile(on screen: NSScreen) {
        let screenID = ScreenIdentifier(from: screen)
        let allWindows = accessibilityManager.getAllWindows()

        // Get the window IDs belonging to the workspace
        let workspaceIDs = getWorkspaceWindowIDs(on: screen)


        // Filter down to managed windows
        // - shouldBeManaged(): excludes minimized, fullscreen, and non-standard windows
        // - shouldFloat(): excludes windows that should float
        // - workspaceIDs.contains(): targets only windows in the current workspace
        let managedWindows = allWindows.filter { window in
            window.shouldBeManaged() && !window.shouldFloat() && workspaceIDs.contains(window.id) && !WorkspaceManager.shared.isHovering(window.id)
        }

        // If there are no target windows, clear the column structure and return
        guard !managedWindows.isEmpty else {
            tiledWindows[screenID] = []
            return
        }

        // The set of all window IDs
        let managedWindowIDs = Set(managedWindows.map { $0.id })

        // A dictionary of all windows (ID -> WindowInfo)
        let windowDict = Dictionary(uniqueKeysWithValues: managedWindows.map { ($0.id, $0) })

        // Get the existing column structure
        var columns = tiledWindows[screenID] ?? []

        // Collect the window IDs already present in the column structure
        let existingWindowIDs = Set(columns.flatMap { $0.map { $0.id } })

        // Remove closed windows and windows from other workspaces from the column structure
        columns = columns.map { column in
            column.filter { windowInfo in
                managedWindowIDs.contains(windowInfo.id)
            }
        }.filter { !$0.isEmpty }

        // Refresh the window info to the latest
        columns = columns.map { column in
            column.compactMap { windowInfo in
                if let updated = windowDict[windowInfo.id] {
                    return updated
                }
                return nil
            }
        }.filter { !$0.isEmpty }

        // Add new windows (ones not already in a column)
        for window in managedWindows {
            if !existingWindowIDs.contains(window.id) {
                // Insert at the right position based on X coordinate (always appending to the right end would scramble the order)
                var insertIndex = columns.count
                for (i, col) in columns.enumerated() {
                    if let first = col.first, window.frame.midX < first.frame.midX {
                        insertIndex = i
                        break
                    }
                }
                columns.insert([window], at: insertIndex)
            }
        }

        // Update the state
        tiledWindows[screenID] = columns

        // Compute and apply the tiling layout
        applyColumnTiling(columns: columns, on: screen)

        // Re-raise floating windows to the front on every tiling pass (keeps them from getting hidden behind tiles)
        raiseFloatingWindows(on: screen)
    }

    /// Raise floating windows (hover-designated or shouldFloat) on the given screen to the front
    /// Calling this on every tiling pass prevents dialogs and the like from staying stuck behind the tiles.
    /// Doesn't steal focus.
    func raiseFloatingWindows(on screen: NSScreen) {
        let accessibilityManager = AccessibilityManager.shared
        let onScreenIDs = accessibilityManager.getOnScreenWindowIDs()
        let zenHiddenIDs = ZenModeManager.shared.hiddenWindowIDs
        let myPID = ProcessInfo.processInfo.processIdentifier

        // For converting AX coordinates (top-left origin) to NSScreen coordinates (bottom-left origin)
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0

        let targetWindows = PerfLog.measure("TilingEngine.raiseFloatingWindows/getWindowsForPIDs", threshold: 0.005) { () -> [WindowInfo] in
            let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            var targetPIDs = Set<pid_t>()
            for entry in windowList {
                guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != myPID else { continue }
                guard let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
                let bounds = CGRect(x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                                    width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0)
                let center = CGPoint(x: bounds.midX, y: mainScreenHeight - bounds.midY)
                if screen.frame.contains(center) {
                    targetPIDs.insert(pid)
                }
            }
            var windows: [WindowInfo] = []
            for pid in targetPIDs {
                windows.append(contentsOf: accessibilityManager.getWindows(forPID: pid))
            }
            return windows
        }

        for window in targetWindows {
            // Axis's own windows are excluded
            guard window.app.processIdentifier != myPID else { continue }
            // Windows not showing on screen are excluded
            guard onScreenIDs.contains(window.id) else { continue }
            // Windows currently evacuated (another workspace, the palette, Zen) are excluded
            guard !WorkspaceManager.shared.isWindowHidden(window.id) else { continue }
            guard !WindowPaletteManager.shared.isWindowHidden(window.id) else { continue }
            guard !zenHiddenIDs.contains(window.id) else { continue }
            // Floating windows only (hover-designated or float targets)
            guard WorkspaceManager.shared.isHovering(window.id) || window.shouldFloat() else { continue }
            // Only raise genuine windows (standard windows or dialogs)
            // (so we don't raise invisible helper windows, like Arc's, on every pass)
            guard window.shouldBeManaged()
                || window.subrole == kAXDialogSubrole as String
                || window.subrole == kAXSystemDialogSubrole as String else { continue }
            // Only the ones on this screen (judged by window center)
            let center = CGPoint(x: window.frame.midX, y: mainScreenHeight - window.frame.midY)
            guard screen.frame.contains(center) else { continue }

            window.raise()
        }
    }

    /// Run tiling across all screens
    func tileAllScreens() {
        for screen in NSScreen.screens {
            tile(on: screen)
        }
    }
    
    /// Move window focus in the given direction (returns the destination window's ID)
    @discardableResult
    func moveFocus(direction: Direction) -> CGWindowID? {

        // cursorScreen being set means the mouse is on an empty monitor
        // Use cursorScreen as the reference for finding the destination, instead of the focused window
        if let cursorScr = cursorScreen {
            if let target = getWindowOnScreen(cursorScr, direction: direction) {
                cursorScreen = nil
                target.focus()
                moveCursorToWindow(target)
                return target.id
            } else {
                // If it's still not found, move the cursor to the next monitor over
                moveCursorToAdjacentScreen(from: cursorScr, direction: direction)
            }
            return nil
        }

        guard let focusedWindow = accessibilityManager.getFocusedWindow() else {
            return nil
        }


        guard let screen = getScreen(for: focusedWindow) else {
            // The focused window is off-screen (e.g. hidden by a workspace switch)
            // Fall back to the monitor the mouse cursor is on and try moving there
            let mouseLocation = NSEvent.mouseLocation
            if let cursorScr = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
                if let target = getWindowOnScreen(cursorScr, direction: direction) {
                    cursorScreen = nil
                    target.focus()
                    moveCursorToWindow(target)
                    return target.id
                } else {
                    moveCursorToAdjacentScreen(from: cursorScr, direction: direction)
                }
            }
            return nil
        }
        let screenID = ScreenIdentifier(from: screen)


        // Target only windows belonging to the current workspace
        let workspaceIDs = getWorkspaceWindowIDs(on: screen)
        let allColumns = tiledWindows[screenID] ?? []
        var columns = allColumns.map { column in
            column.filter { workspaceIDs.contains($0.id) }
        }.filter { !$0.isEmpty }

        // Insert hovering windows into a column based on X coordinate too, so they're eligible for focus movement
        let hoverIDs = WorkspaceManager.shared.hoverWindowIDs
        if !hoverIDs.isEmpty {
            let allWins = accessibilityManager.getAllWindows()
            let hoverWindows = allWins.filter { hoverIDs.contains($0.id) && workspaceIDs.contains($0.id) }
                .sorted { $0.frame.midX < $1.frame.midX }
            for hw in hoverWindows {
                // Look at the X coordinate and insert at the right spot in the tiling columns
                var insertIndex = columns.count
                for (i, col) in columns.enumerated() {
                    if let first = col.first, hw.frame.midX < first.frame.midX {
                        insertIndex = i
                        break
                    }
                }
                columns.insert([hw], at: insertIndex)
            }
        }

        guard let (columnIndex, rowIndex) = findWindowPosition(window: focusedWindow, in: columns) else {
            return nil
        }

        var targetWindow: WindowInfo?

        switch direction {
        case .left:
            if columnIndex > 0 {
                // The same row (or the last row) of the column to the left
                let leftColumn = columns[columnIndex - 1]
                let targetRow = min(rowIndex, leftColumn.count - 1)
                targetWindow = leftColumn[targetRow]
            } else {
                // If at the left edge, go to the monitor on the left
                targetWindow = getWindowOnAdjacentScreen(from: focusedWindow, direction: .left)
                // Move the cursor if there's a monitor, even with no windows
                if targetWindow == nil {
                    moveCursorToAdjacentScreen(from: screen, direction: .left)
                }
            }
        case .right:
            if columnIndex < columns.count - 1 {
                // The same row (or the last row) of the column to the right
                let rightColumn = columns[columnIndex + 1]
                let targetRow = min(rowIndex, rightColumn.count - 1)
                targetWindow = rightColumn[targetRow]
            } else {
                // If at the right edge, go to the monitor on the right
                targetWindow = getWindowOnAdjacentScreen(from: focusedWindow, direction: .right)
                if targetWindow == nil {
                    moveCursorToAdjacentScreen(from: screen, direction: .right)
                }
            }
        case .up:
            if rowIndex > 0 {
                // The window above in the same column
                targetWindow = columns[columnIndex][rowIndex - 1]
            } else {
                // If at the top of the column, go to the monitor above
                targetWindow = getWindowOnAdjacentScreen(from: focusedWindow, direction: .up)
                if targetWindow == nil {
                    moveCursorToAdjacentScreen(from: screen, direction: .up)
                }
            }
        case .down:
            if rowIndex < columns[columnIndex].count - 1 {
                // The window below in the same column
                targetWindow = columns[columnIndex][rowIndex + 1]
            } else {
                // If at the bottom of the column, go to the monitor below
                targetWindow = getWindowOnAdjacentScreen(from: focusedWindow, direction: .down)
                if targetWindow == nil {
                    moveCursorToAdjacentScreen(from: screen, direction: .down)
                }
            }
        }

        if let target = targetWindow {
            target.focus()
            moveCursorToWindow(target)
            return target.id
        }
        return nil
    }

    /// When the neighboring monitor is empty, move the mouse cursor to its center
    /// Update cursorScreen and hide the focus border
    private func moveCursorToAdjacentScreen(from screen: NSScreen, direction: Direction) {
        guard let adjacentScreen = getAdjacentScreen(from: screen, direction: direction) else { return }
        cursorScreen = adjacentScreen
        let centerX = adjacentScreen.frame.midX
        let centerY = adjacentScreen.frame.midY
        // Convert since CGWarpMouseCursorPosition uses a top-left origin
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let warpY = mainScreenHeight - centerY
        CGWarpMouseCursorPosition(CGPoint(x: centerX, y: warpY))
        // Hide the border since focus is leaving
        BorderManager.shared.hideBorder()
    }

    /// Get the windows on the given screen, or on the neighboring screen in the given direction
    /// Used for focus movement in cursorScreen mode
    private func getWindowOnScreen(_ screen: NSScreen, direction: Direction) -> WindowInfo? {
        let screenID = ScreenIdentifier(from: screen)
        let workspaceIDs = getWorkspaceWindowIDs(on: screen)
        let zenHiddenIDs = ZenModeManager.shared.hiddenWindowIDs
        let localColumns = (tiledWindows[screenID] ?? []).map { col in
            col.filter { workspaceIDs.contains($0.id) && !zenHiddenIDs.contains($0.id) }
        }.filter { !$0.isEmpty }

        // If the screen itself has windows, pick from among them
        if !localColumns.isEmpty {
            switch direction {
            case .right: return localColumns.first?.first
            case .left:  return localColumns.last?.first
            case .up, .down: return localColumns.first?.first
            }
        }

        // If the screen is empty, go to the neighboring screen
        return getWindowOnAdjacentScreen(from: screen, direction: direction)
    }

    /// Get the windows on the screen neighboring the given screen (NSScreen version)
    private func getWindowOnAdjacentScreen(from screen: NSScreen, direction: Direction) -> WindowInfo? {
        guard let targetScreen = getAdjacentScreen(from: screen, direction: direction) else { return nil }
        let targetID = ScreenIdentifier(from: targetScreen)
        let workspaceIDs = getWorkspaceWindowIDs(on: targetScreen)
        let zenHiddenIDs = ZenModeManager.shared.hiddenWindowIDs
        let columns = (tiledWindows[targetID] ?? []).map { col in
            col.filter { workspaceIDs.contains($0.id) && !zenHiddenIDs.contains($0.id) }
        }.filter { !$0.isEmpty }
        guard !columns.isEmpty else { return nil }
        switch direction {
        case .left:  return columns.last?.first
        case .right: return columns.first?.first
        case .up, .down: return columns.first?.first
        }
    }

    /// Move the mouse cursor to the window's center
    func moveCursorToWindow(_ window: WindowInfo) {
        // Move after a short delay (waiting for the window's position change to take effect)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Get the window's current position
            var windowCopy = window
            windowCopy.refreshFrame()

            let centerX = windowCopy.frame.midX
            let centerY = windowCopy.frame.midY

            // CGWarpMouseCursorPosition uses a top-left origin, so it can be used as-is
            CGWarpMouseCursorPosition(CGPoint(x: centerX, y: centerY))
        }
    }

    /// Look up a window's position (column index, row index) within the column structure
    func findWindowPosition(window: WindowInfo, in columns: [[WindowInfo]]) -> (columnIndex: Int, rowIndex: Int)? {
        for (columnIndex, column) in columns.enumerated() {
            if let rowIndex = column.firstIndex(of: window) {
                return (columnIndex, rowIndex)
            }
        }
        return nil
    }
    
    /// Move the window in the given direction (rearrange its placement)
    func moveWindow(direction: Direction) {
        guard let currentWindow = accessibilityManager.getFocusedWindow(),
              let screen = getScreen(for: currentWindow) else {
            return
        }
        let screenID = ScreenIdentifier(from: screen)

        // Get the window IDs of the current workspace
        let workspaceIDs = getWorkspaceWindowIDs(on: screen)

        // Get all columns and filter down to just the workspace's windows
        let allColumns = tiledWindows[screenID] ?? []
        var columns = allColumns.map { column in
            column.filter { workspaceIDs.contains($0.id) }
        }.filter { !$0.isEmpty }

        guard let (columnIndex, rowIndex) = findWindowPosition(window: currentWindow, in: columns) else {
            return
        }

        switch direction {
        case .left:
            if columnIndex > 0 {
                // Swap the whole columns
                columns.swapAt(columnIndex, columnIndex - 1)

                // Swap the size ratio info along with it
                if var ratios = columnWidthRatios[screenID], ratios.count == columns.count {
                    ratios.swapAt(columnIndex, columnIndex - 1)
                    columnWidthRatios[screenID] = ratios
                }
                if var allRowRatios = rowHeightRatios[screenID] {
                    let temp = allRowRatios[columnIndex]
                    allRowRatios[columnIndex] = allRowRatios[columnIndex - 1]
                    allRowRatios[columnIndex - 1] = temp
                    rowHeightRatios[screenID] = allRowRatios
                }

                // Only store on-screen windows in tiledWindows
                tiledWindows[screenID] = columns
                applyColumnTiling(columns: columns, on: screen)
            } else {
                // If at the left edge, move to the monitor on the left
                if let leftScreen = getAdjacentScreen(from: screen, direction: .left) {
                    moveWindowToScreen(currentWindow, from: screen, to: leftScreen, position: .right)
                }
            }
        case .right:
            if columnIndex < columns.count - 1 {
                // Swap the whole columns
                columns.swapAt(columnIndex, columnIndex + 1)

                // Swap the size ratio info along with it
                if var ratios = columnWidthRatios[screenID], ratios.count == columns.count {
                    ratios.swapAt(columnIndex, columnIndex + 1)
                    columnWidthRatios[screenID] = ratios
                }
                if var allRowRatios = rowHeightRatios[screenID] {
                    let temp = allRowRatios[columnIndex]
                    allRowRatios[columnIndex] = allRowRatios[columnIndex + 1]
                    allRowRatios[columnIndex + 1] = temp
                    rowHeightRatios[screenID] = allRowRatios
                }

                tiledWindows[screenID] = columns
                applyColumnTiling(columns: columns, on: screen)
            } else {
                // If at the right edge, move to the monitor on the right
                if let rightScreen = getAdjacentScreen(from: screen, direction: .right) {
                    moveWindowToScreen(currentWindow, from: screen, to: rightScreen, position: .left)
                }
            }
        case .up:
            if rowIndex > 0 {
                // Move up within the same column
                columns[columnIndex].swapAt(rowIndex, rowIndex - 1)

                // Swap the row height ratio info along with it
                if var allRowRatios = rowHeightRatios[screenID],
                   var ratios = allRowRatios[columnIndex],
                   ratios.count == columns[columnIndex].count {
                    ratios.swapAt(rowIndex, rowIndex - 1)
                    allRowRatios[columnIndex] = ratios
                    rowHeightRatios[screenID] = allRowRatios
                }

                tiledWindows[screenID] = columns
                applyColumnTiling(columns: columns, on: screen)
            } else {
                // If at the top of the column, move to the monitor above (added at the far left)
                if let upScreen = getAdjacentScreen(from: screen, direction: .up) {
                    moveWindowToScreen(currentWindow, from: screen, to: upScreen, position: .left)
                } else {
                }
            }
        case .down:
            if rowIndex < columns[columnIndex].count - 1 {
                // Move down within the same column
                columns[columnIndex].swapAt(rowIndex, rowIndex + 1)

                // Swap the row height ratio info along with it
                if var allRowRatios = rowHeightRatios[screenID],
                   var ratios = allRowRatios[columnIndex],
                   ratios.count == columns[columnIndex].count {
                    ratios.swapAt(rowIndex, rowIndex + 1)
                    allRowRatios[columnIndex] = ratios
                    rowHeightRatios[screenID] = allRowRatios
                }

                tiledWindows[screenID] = columns
                applyColumnTiling(columns: columns, on: screen)
            } else {
                // If at the bottom of the column, move to the monitor below (added at the far left)
                if let downScreen = getAdjacentScreen(from: screen, direction: .down) {
                    moveWindowToScreen(currentWindow, from: screen, to: downScreen, position: .left)
                } else {
                }
            }
        }

        // Keep focus as is, and move the cursor too
        currentWindow.focus()
        moveCursorToWindow(currentWindow)
    }

    /// Move the window to another screen
    private func moveWindowToScreen(_ window: WindowInfo, from sourceScreen: NSScreen, to targetScreen: NSScreen, position: HorizontalPosition) {
        let sourceID = ScreenIdentifier(from: sourceScreen)
        let targetID = ScreenIdentifier(from: targetScreen)

        // Also update the workspace registration to the destination
        WorkspaceManager.shared.moveWindowBetweenScreens(window.id, from: sourceScreen, to: targetScreen)

        // Remove the window from its original screen
        var sourceColumns = tiledWindows[sourceID] ?? []
        for colIdx in 0..<sourceColumns.count {
            if let rowIdx = sourceColumns[colIdx].firstIndex(of: window) {
                sourceColumns[colIdx].remove(at: rowIdx)
                break
            }
        }
        // Remove empty columns
        sourceColumns = sourceColumns.filter { !$0.isEmpty }
        tiledWindows[sourceID] = sourceColumns
        applyColumnTiling(columns: sourceColumns, on: sourceScreen)

        // Add the window to the target screen
        var targetColumns = tiledWindows[targetID] ?? []
        switch position {
        case .left:
            // Append to the far left
            targetColumns.insert([window], at: 0)
        case .right:
            // Append to the far right
            targetColumns.append([window])
        }
        tiledWindows[targetID] = targetColumns
        applyColumnTiling(columns: targetColumns, on: targetScreen)

        // Reapply tiling after a short delay (to fit the monitor size)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            if let columns = self.tiledWindows[targetID] {
                self.applyColumnTiling(columns: columns, on: targetScreen)
            }
        }
    }

    /// Horizontal position
    private enum HorizontalPosition {
        case left
        case right
    }

    /// Move multiple windows in the given direction (for window-selection mode)
    func moveWindows(windowIDs: Set<CGWindowID>, direction: Direction) {

        guard let focusedWindow = accessibilityManager.getFocusedWindow(),
              let screen = getScreen(for: focusedWindow) else {
            return
        }
        let screenID = ScreenIdentifier(from: screen)

        var columns = tiledWindows[screenID] ?? []

        // Get the position of the selected window
        var selectedPositions: [(columnIndex: Int, rowIndex: Int, window: WindowInfo)] = []
        for (colIdx, column) in columns.enumerated() {
            for (rowIdx, window) in column.enumerated() {
                if windowIDs.contains(window.id) {
                    selectedPositions.append((colIdx, rowIdx, window))
                }
            }
        }


        guard !selectedPositions.isEmpty else {
            return
        }

        // Get the indices of the columns containing the selected windows (deduplicated, sorted)
        let selectedColumnIndices = Array(Set(selectedPositions.map { $0.columnIndex })).sorted()

        switch direction {
        case .left:
            // Move left: swap the selected column with the unselected column to its left
            guard let firstSelectedIdx = selectedColumnIndices.first, firstSelectedIdx > 0 else {
                return
            }

            // Find the unselected column to the left
            var swapTargetIdx = firstSelectedIdx - 1
            while swapTargetIdx >= 0 && selectedColumnIndices.contains(swapTargetIdx) {
                swapTargetIdx -= 1
            }

            if swapTargetIdx >= 0 {
                // Move the selected column to the left (swap column order)
                // Example: with [1,2,3,4], selecting 3,4 (index 2,3) → swapTargetIdx=1
                // Result: [1,3,4,2]
                let targetColumn = columns[swapTargetIdx]
                columns.remove(at: swapTargetIdx)
                // Insert at the last position of the selected column
                let insertIdx = selectedColumnIndices.last!
                columns.insert(targetColumn, at: insertIdx)
            }

        case .right:
            // Move right: swap the selected column with the unselected column to its right
            guard let lastSelectedIdx = selectedColumnIndices.last, lastSelectedIdx < columns.count - 1 else {
                return
            }

            // Find the unselected column to the right
            var swapTargetIdx = lastSelectedIdx + 1
            while swapTargetIdx < columns.count && selectedColumnIndices.contains(swapTargetIdx) {
                swapTargetIdx += 1
            }

            if swapTargetIdx < columns.count {
                // Move the selected column to the right (swap column order)
                // Example: with [1,2,3,4], selecting 1,2 (index 0,1) → swapTargetIdx=2
                // Result: [3,1,2,4]
                let targetColumn = columns[swapTargetIdx]
                columns.remove(at: swapTargetIdx)
                // Insert at the first position of the selected column
                let insertIdx = selectedColumnIndices.first!
                columns.insert(targetColumn, at: insertIdx)
            }
        case .up:
            // Move up: up within the same column
            for pos in selectedPositions {
                if pos.rowIndex > 0 {
                    if let rowIdx = columns[pos.columnIndex].firstIndex(of: pos.window),
                       rowIdx > 0 && !windowIDs.contains(columns[pos.columnIndex][rowIdx - 1].id) {
                        columns[pos.columnIndex].swapAt(rowIdx, rowIdx - 1)
                    }
                }
            }
        case .down:
            // Move down: down within the same column
            selectedPositions.sort { $0.rowIndex > $1.rowIndex }
            for pos in selectedPositions {
                if let rowIdx = columns[pos.columnIndex].firstIndex(of: pos.window),
                   rowIdx < columns[pos.columnIndex].count - 1 && !windowIDs.contains(columns[pos.columnIndex][rowIdx + 1].id) {
                    columns[pos.columnIndex].swapAt(rowIdx, rowIdx + 1)
                }
            }
        }

        // Remove empty columns
        columns = columns.filter { !$0.isEmpty }

        tiledWindows[screenID] = columns
        applyColumnTiling(columns: columns, on: screen)

        // Keep focus as is
        focusedWindow.focus()
    }

    /// Put every window back into its own column (reset the vertical split)
    func resetToSingleWindowColumns() {

        guard let focusedWindow = accessibilityManager.getFocusedWindow(),
              let screen = getScreen(for: focusedWindow) else {
            return
        }
        let screenID = ScreenIdentifier(from: screen)

        let columns = tiledWindows[screenID] ?? []

        // Take out all the windows and make each one its own column
        let allWindows = columns.flatMap { $0 }
        let newColumns = allWindows.map { [$0] }


        tiledWindows[screenID] = newColumns
        applyColumnTiling(columns: newColumns, on: screen)

        // Keep focus as is
        focusedWindow.focus()
    }

    /// Merge the selected windows into a single column (stack them vertically)
    func mergeWindowsIntoColumn(windowIDs: Set<CGWindowID>) {

        guard let focusedWindow = accessibilityManager.getFocusedWindow(),
              let screen = getScreen(for: focusedWindow) else {
            return
        }
        let screenID = ScreenIdentifier(from: screen)

        var columns = tiledWindows[screenID] ?? []

        // Collect the selected windows (preserving their original order)
        var selectedWindows: [WindowInfo] = []
        var targetColumnIndex: Int? = nil

        for (colIdx, column) in columns.enumerated() {
            for window in column {
                if windowIDs.contains(window.id) {
                    selectedWindows.append(window)
                    // Use the column of the first selected window as the merge target
                    if targetColumnIndex == nil {
                        targetColumnIndex = colIdx
                    }
                }
            }
        }

        guard !selectedWindows.isEmpty, let targetCol = targetColumnIndex else {
            return
        }


        // Remove the selected windows from all columns
        for colIdx in 0..<columns.count {
            columns[colIdx] = columns[colIdx].filter { !windowIDs.contains($0.id) }
        }

        // Remove empty columns (though targetCol needs to be adjusted)
        var newTargetCol = targetCol
        var newColumns: [[WindowInfo]] = []
        for (idx, column) in columns.enumerated() {
            if !column.isEmpty {
                newColumns.append(column)
            } else if idx < targetCol {
                newTargetCol -= 1
            }
        }
        columns = newColumns

        // Insert the new column at the merge target's position
        let insertIndex = min(newTargetCol, columns.count)
        columns.insert(selectedWindows, at: insertIndex)

        tiledWindows[screenID] = columns
        applyColumnTiling(columns: columns, on: screen)

        // Keep focus as is
        focusedWindow.focus()
    }

    /// Split the selected windows into individual columns (undo the vertical split)
    func splitWindowsToColumns(windowIDs: Set<CGWindowID>) {

        guard let focusedWindow = accessibilityManager.getFocusedWindow(),
              let screen = getScreen(for: focusedWindow) else {
            return
        }
        let screenID = ScreenIdentifier(from: screen)

        var columns = tiledWindows[screenID] ?? []

        // Collect the selected windows (preserving their original order)
        var selectedWindows: [WindowInfo] = []
        var firstColumnIndex: Int? = nil

        for (colIdx, column) in columns.enumerated() {
            for window in column {
                if windowIDs.contains(window.id) {
                    selectedWindows.append(window)
                    // Record the column of the first selected window we find
                    if firstColumnIndex == nil {
                        firstColumnIndex = colIdx
                    }
                }
            }
        }

        guard !selectedWindows.isEmpty, let insertIndex = firstColumnIndex else {
            return
        }


        // Remove the selected windows from all columns
        for colIdx in 0..<columns.count {
            columns[colIdx] = columns[colIdx].filter { !windowIDs.contains($0.id) }
        }

        // Remove empty columns (the insertion index needs adjusting too)
        var adjustedInsertIndex = insertIndex
        var newColumns: [[WindowInfo]] = []
        for (idx, column) in columns.enumerated() {
            if !column.isEmpty {
                newColumns.append(column)
            } else if idx < insertIndex {
                adjustedInsertIndex -= 1
            }
        }
        columns = newColumns

        // Insert each selected window as its own column
        for (offset, window) in selectedWindows.enumerated() {
            let newInsertIndex = min(adjustedInsertIndex + offset, columns.count)
            columns.insert([window], at: newInsertIndex)
        }

        tiledWindows[screenID] = columns
        applyColumnTiling(columns: columns, on: screen)

        // Keep focus as is
        focusedWindow.focus()
    }
    
    // MARK: - Private Methods

    /// Apply tiling using the column structure
    /// Windows within a column are arranged top to bottom
    /// Use the existing ratio if there is one; otherwise split evenly
    private func applyColumnTiling(columns: [[WindowInfo]], on screen: NSScreen) {
        guard !columns.isEmpty else { return }
        logIfSingleWindowLayout(columns: columns, on: screen, via: "applyColumnTiling")
        let screenID = ScreenIdentifier(from: screen)

        // Use the existing ratio if there is one
        if let existingRatios = columnWidthRatios[screenID], existingRatios.count == columns.count {
            // Also check the row ratios and reset them if the window count changed
            var needsRowRatioReset = false
            if let allRowRatios = rowHeightRatios[screenID] {
                for (colIndex, column) in columns.enumerated() {
                    if let ratios = allRowRatios[colIndex], ratios.count != column.count {
                        needsRowRatioReset = true
                        break
                    }
                }
            }
            if needsRowRatioReset {
                rowHeightRatios[screenID] = nil
            }
            applyColumnTilingWithRatios(columns: columns, ratios: existingRatios, on: screen)
            return
        }

        // Reset the ratios if the number of columns changed
        columnWidthRatios[screenID] = nil
        rowHeightRatios[screenID] = nil

        let visibleFrame = screen.visibleFrame
        let columnCount = CGFloat(columns.count)

        // Available width (accounting for padding and gaps)
        let totalColumnGaps = windowGap * (columnCount - 1)
        let availableWidth = visibleFrame.width - (screenPadding * 2) - totalColumnGaps
        let columnWidth = availableWidth / columnCount

        // The Accessibility API's coordinate system has a top-left origin (relative to the main screen)
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let screenTopInAX = mainScreenHeight - (visibleFrame.minY + visibleFrame.height)

        var currentX = visibleFrame.minX + screenPadding

        for (colIndex, column) in columns.enumerated() {
            guard !column.isEmpty else { continue }

            // Get the row height ratio
            let rowRatios = rowHeightRatios[screenID]?[colIndex]

            let rowCount = CGFloat(column.count)
            let totalRowGaps = windowGap * (rowCount - 1)
            let availableHeight = visibleFrame.height - (screenPadding * 2) - totalRowGaps

            var currentY = screenTopInAX + screenPadding

            for (rowIndex, window) in column.enumerated() {
                // Row height (use the ratio if one exists, otherwise split evenly)
                let rowHeight: CGFloat
                if let ratios = rowRatios, rowIndex < ratios.count, ratios.count == column.count {
                    rowHeight = availableHeight * ratios[rowIndex]
                } else {
                    rowHeight = availableHeight / rowCount
                }

                var newFrame = CGRect(
                    x: currentX,
                    y: currentY,
                    width: columnWidth,
                    height: rowHeight
                )

                // Adjust the position if it would overflow the screen
                newFrame = adjustFrameToFitScreen(frame: newFrame, visibleFrame: visibleFrame, mainScreenHeight: mainScreenHeight)

                window.setFrame(newFrame)
                // Also update the frame held by the column structure (so stale coordinates don't linger)
                updateCachedFrame(windowID: window.id, to: newFrame, on: screenID)

                currentY += rowHeight + windowGap
            }

            currentX += columnWidth + windowGap
        }
    }

    /// Update the frame held by the column structure with the frame that was actually applied
    /// The column structure's WindowInfo holds the frame measured "before" tiling was applied, and
    /// Without updating this, the stale coordinates would linger until the next window addition or removal.
    /// causes the logic that inserts new or hovering windows into a column by X coordinate to pick the wrong spot
    /// Logs when tiling results in a layout where a single window occupies the whole screen.
    /// Diagnostic logging to pin down when the "an unexpected window goes fullscreen" bug occurs.
    /// Cross-referenced with the line above (a window miss/disappearance) to narrow down the cause
    private func logIfSingleWindowLayout(columns: [[WindowInfo]], on screen: NSScreen, via caller: String) {
        guard PerfLog.enabled else { return }
        let total = columns.reduce(0) { $0 + $1.count }
        guard total == 1, let window = columns.first?.first else { return }
        PerfLog.logf("★全画面割当: %@ / %@ (経路: %@, 画面幅: %.0f)",
                     window.app.localizedName ?? "?", window.title, caller, screen.visibleFrame.width)
    }

    private func updateCachedFrame(windowID: CGWindowID, to frame: CGRect, on screenID: ScreenIdentifier) {
        guard var columns = tiledWindows[screenID] else { return }
        for (columnIndex, column) in columns.enumerated() {
            guard let rowIndex = column.firstIndex(where: { $0.id == windowID }) else { continue }
            columns[columnIndex][rowIndex].frame = frame
            tiledWindows[screenID] = columns
            return
        }
    }

    /// Compute each window's width (accounting for the minimum size)
    private func calculateWindowWidths(windows: [WindowInfo], availableWidth: CGFloat, idealWidth: CGFloat) -> [CGFloat] {
        var widths = [CGFloat](repeating: idealWidth, count: windows.count)
        
        // Apply the minimum width if it's smaller than that
        var totalMinWidthExcess: CGFloat = 0
        var flexibleCount = 0
        
        for (index, window) in windows.enumerated() {
            if idealWidth < window.minSize.width {
                widths[index] = window.minSize.width
                totalMinWidthExcess += (window.minSize.width - idealWidth)
            } else {
                flexibleCount += 1
            }
        }
        
        // If a window had the minimum width applied, shrink the other windows to compensate
        if totalMinWidthExcess > 0 && flexibleCount > 0 {
            let reductionPerWindow = totalMinWidthExcess / CGFloat(flexibleCount)
            for (index, window) in windows.enumerated() {
                if widths[index] == idealWidth && idealWidth >= window.minSize.width {
                    let newWidth = idealWidth - reductionPerWindow
                    // Don't let it shrink below the minimum size
                    widths[index] = max(newWidth, window.minSize.width)
                }
            }
        }
        
        return widths
    }
    
    /// Adjust so the frame fits within the screen (modeled on Rectangle's BestEffortWindowMover)
    private func adjustFrameToFitScreen(frame: CGRect, visibleFrame: CGRect, mainScreenHeight: CGFloat) -> CGRect {
        var adjusted = frame
        
        // Check the left edge
        if adjusted.minX < visibleFrame.minX + screenPadding {
            adjusted.origin.x = visibleFrame.minX + screenPadding
        }
        
        // Check the right edge (move left if it overflows)
        let rightEdge = visibleFrame.maxX - screenPadding
        if adjusted.maxX > rightEdge {
            adjusted.origin.x = rightEdge - adjusted.width
            // If it still overflows to the left, pin it to the left edge (the window is too large)
            if adjusted.minX < visibleFrame.minX + screenPadding {
                adjusted.origin.x = visibleFrame.minX + screenPadding
            }
        }
        
        // Adjustment of the Y coordinate (AX coordinate system)
        // Check for overflow past the bottom edge
        let screenBottomInAX = mainScreenHeight - visibleFrame.minY
        let frameBottomInAX = adjusted.origin.y + adjusted.height
        
        if frameBottomInAX > screenBottomInAX - screenPadding {
            adjusted.origin.y = screenBottomInAX - screenPadding - adjusted.height
        }
        
        // Check for overflow past the top edge
        let screenTopInAX = mainScreenHeight - (visibleFrame.minY + visibleFrame.height) + screenPadding
        if adjusted.origin.y < screenTopInAX {
            adjusted.origin.y = screenTopInAX
        }
        
        return adjusted
    }
    
    /// Get the screen the window belongs to
    private func getScreen(for window: WindowInfo) -> NSScreen? {
        // Convert from the Accessibility API's coordinate system (top-left origin) to NSScreen's (bottom-left origin)
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0

        // Convert the window's center point to NSScreen coordinates
        let windowCenterX = window.frame.midX
        let windowCenterY = mainScreenHeight - window.frame.midY

        let windowCenterInNSScreen = CGPoint(x: windowCenterX, y: windowCenterY)


        return NSScreen.screens.first { screen in
            screen.frame.contains(windowCenterInNSScreen)
        }
    }
    
    /// Get the windows on the neighboring screen
    private func getWindowOnAdjacentScreen(from window: WindowInfo, direction: Direction) -> WindowInfo? {
        guard let currentScreen = getScreen(for: window) else { return nil }

        let adjacentScreen = getAdjacentScreen(from: currentScreen, direction: direction)
        guard let targetScreen = adjacentScreen else { return nil }
        let targetID = ScreenIdentifier(from: targetScreen)

        // Target only the current workspace's windows
        let workspaceIDs = getWorkspaceWindowIDs(on: targetScreen)
        // Also exclude windows off-screen because Zen mode hid them
        let zenHiddenIDs = ZenModeManager.shared.hiddenWindowIDs
        let allColumns = tiledWindows[targetID] ?? []
        let columns = allColumns.map { column in
            column.filter { workspaceIDs.contains($0.id) && !zenHiddenIDs.contains($0.id) }
        }.filter { !$0.isEmpty }
        guard !columns.isEmpty else { return nil }

        switch direction {
        case .left:
            // For the monitor on the left, the first window of the rightmost column
            return columns.last?.first
        case .right:
            // For the monitor on the right, the first window of the leftmost column
            return columns.first?.first
        case .up, .down:
            // For a monitor above or below, the window with the closest X coordinate
            let windowCenterX = window.frame.midX
            let allWindows = columns.flatMap { $0 }
            return allWindows.min { w1, w2 in
                abs(w1.frame.midX - windowCenterX) < abs(w2.frame.midX - windowCenterX)
            }
        }
    }
    
    /// Get the neighboring screen
    private func getAdjacentScreen(from screen: NSScreen, direction: Direction) -> NSScreen? {
        let currentFrame = screen.frame

        return NSScreen.screens.first { otherScreen in
            guard otherScreen != screen else { return false }
            let otherFrame = otherScreen.frame

            switch direction {
            case .left:
                // Whether it's to the left of the current screen
                return otherFrame.maxX <= currentFrame.minX + 1 &&
                       otherFrame.minY < currentFrame.maxY &&
                       otherFrame.maxY > currentFrame.minY
            case .right:
                // Whether it's to the right of the current screen
                return otherFrame.minX >= currentFrame.maxX - 1 &&
                       otherFrame.minY < currentFrame.maxY &&
                       otherFrame.maxY > currentFrame.minY
            case .up:
                // Whether it's above the current screen (NSScreen's origin is bottom-left, Y increases upward)
                let isAbove = otherFrame.minY >= currentFrame.maxY - 1
                let hasXOverlap = otherFrame.minX < currentFrame.maxX && otherFrame.maxX > currentFrame.minX
                return isAbove && hasXOverlap
            case .down:
                // Whether it's below the current screen
                let isBelow = otherFrame.maxY <= currentFrame.minY + 1
                let hasXOverlap = otherFrame.minX < currentFrame.maxX && otherFrame.maxX > currentFrame.minX
                return isBelow && hasXOverlap
            }
        }
    }

    // MARK: - Gap Resizing

    /// Column width ratios (per screen)
    /// Key: screen, value: array of each column's width ratio (sums to 1.0)
    private var columnWidthRatios: [ScreenIdentifier: [CGFloat]] = [:]

    /// Row height ratios (per screen, per column)
    /// Key: screen, value: [column index: array of each row's height ratio]
    private var rowHeightRatios: [ScreenIdentifier: [Int: [CGFloat]]] = [:]

    /// Resize the gap between columns
    /// - Parameters:
    ///   - columnIndex: the index of the column on the left
    ///   - delta: the amount to move (positive: rightward, negative: leftward)
    ///   - screen: the target screen
    func resizeColumnGap(at columnIndex: Int, delta: CGFloat, on screen: NSScreen) {
        let screenID = ScreenIdentifier(from: screen)
        let columns = tiledWindows[screenID] ?? []
        guard columns.count > 1 else { return }
        guard columnIndex >= 0 && columnIndex < columns.count - 1 else { return }


        // Get or initialize the current ratio
        var ratios = columnWidthRatios[screenID] ?? Array(repeating: 1.0 / CGFloat(columns.count), count: columns.count)

        // Reinitialize if the number of ratios doesn't match the number of columns
        if ratios.count != columns.count {
            ratios = Array(repeating: 1.0 / CGFloat(columns.count), count: columns.count)
        }

        // Compute the available width
        let visibleFrame = screen.visibleFrame
        let totalColumnGaps = windowGap * CGFloat(columns.count - 1)
        let availableWidth = visibleFrame.width - (screenPadding * 2) - totalColumnGaps

        // Convert delta to a ratio
        let deltaRatio = delta / availableWidth

        // Minimum ratio (the minimum width each column must have)
        let minRatio: CGFloat = 0.1

        // Adjust the ratios of the left and right columns
        let newLeftRatio = ratios[columnIndex] + deltaRatio
        let newRightRatio = ratios[columnIndex + 1] - deltaRatio

        // Check that it doesn't fall below the minimum ratio
        guard newLeftRatio >= minRatio && newRightRatio >= minRatio else {
            return
        }

        ratios[columnIndex] = newLeftRatio
        ratios[columnIndex + 1] = newRightRatio

        // Save the ratios
        columnWidthRatios[screenID] = ratios

        // Reapply tiling
        applyColumnTilingWithRatios(columns: columns, ratios: ratios, on: screen)
    }

    /// Resize the gap between rows
    /// - Parameters:
    ///   - columnIndex: the column's index
    ///   - rowIndex: the row index of the window above
    ///   - delta: the amount to move (positive: downward, negative: upward)
    ///   - screen: the target screen
    func resizeRowGap(columnIndex: Int, rowIndex: Int, delta: CGFloat, on screen: NSScreen) {
        let screenID = ScreenIdentifier(from: screen)
        let columns = tiledWindows[screenID] ?? []
        guard columnIndex >= 0 && columnIndex < columns.count else { return }

        let column = columns[columnIndex]
        guard column.count > 1 else { return }
        guard rowIndex >= 0 && rowIndex < column.count - 1 else { return }


        // Get or initialize the current row height ratio
        var allRowRatios = rowHeightRatios[screenID] ?? [:]
        var ratios = allRowRatios[columnIndex] ?? Array(repeating: 1.0 / CGFloat(column.count), count: column.count)

        // Reinitialize if the number of ratios doesn't match the number of rows
        if ratios.count != column.count {
            ratios = Array(repeating: 1.0 / CGFloat(column.count), count: column.count)
        }

        // Compute the available height
        let visibleFrame = screen.visibleFrame
        let totalRowGaps = windowGap * CGFloat(column.count - 1)
        let availableHeight = visibleFrame.height - (screenPadding * 2) - totalRowGaps

        // Convert delta to a ratio
        let deltaRatio = delta / availableHeight

        // Minimum ratio
        let minRatio: CGFloat = 0.1

        // Adjust the ratios of the row above and the row below
        let newUpperRatio = ratios[rowIndex] + deltaRatio
        let newLowerRatio = ratios[rowIndex + 1] - deltaRatio

        // Check that it doesn't fall below the minimum ratio
        guard newUpperRatio >= minRatio && newLowerRatio >= minRatio else {
            return
        }

        ratios[rowIndex] = newUpperRatio
        ratios[rowIndex + 1] = newLowerRatio

        // Save the ratios
        allRowRatios[columnIndex] = ratios
        rowHeightRatios[screenID] = allRowRatios

        // Reapply tiling
        let columnRatios = columnWidthRatios[screenID] ?? Array(repeating: 1.0 / CGFloat(columns.count), count: columns.count)
        applyColumnTilingWithRatios(columns: columns, ratios: columnRatios, on: screen)
    }

    /// Apply tiling with the given ratios
    private func applyColumnTilingWithRatios(columns: [[WindowInfo]], ratios: [CGFloat], on screen: NSScreen) {
        let screenID = ScreenIdentifier(from: screen)
        guard !columns.isEmpty else { return }
        logIfSingleWindowLayout(columns: columns, on: screen, via: "applyColumnTilingWithRatios")
        guard columns.count == ratios.count else {
            // Fall back to normal tiling if the ratios don't match
            columnWidthRatios[screenID] = nil
            rowHeightRatios[screenID] = nil
            applyColumnTiling(columns: columns, on: screen)
            return
        }

        // Check the row ratios and clear that column's ratio if the window count changed
        if var allRowRatios = rowHeightRatios[screenID] {
            for (colIndex, column) in columns.enumerated() {
                if let colRatios = allRowRatios[colIndex], colRatios.count != column.count {
                    allRowRatios[colIndex] = nil
                }
            }
            rowHeightRatios[screenID] = allRowRatios
        }

        let visibleFrame = screen.visibleFrame
        let columnCount = CGFloat(columns.count)

        // Available width
        let totalColumnGaps = windowGap * (columnCount - 1)
        let availableWidth = visibleFrame.width - (screenPadding * 2) - totalColumnGaps

        // The Accessibility API's coordinate system has a top-left origin (relative to the main screen)
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let screenTopInAX = mainScreenHeight - (visibleFrame.minY + visibleFrame.height)

        var currentX = visibleFrame.minX + screenPadding

        for (colIndex, column) in columns.enumerated() {
            guard !column.isEmpty else { continue }

            // Compute this column's width from its ratio
            let columnWidth = availableWidth * ratios[colIndex]

            // Get the row height ratio
            let rowRatios = rowHeightRatios[screenID]?[colIndex] ?? Array(repeating: 1.0 / CGFloat(column.count), count: column.count)

            let rowCount = CGFloat(column.count)
            let totalRowGaps = windowGap * (rowCount - 1)
            let availableHeight = visibleFrame.height - (screenPadding * 2) - totalRowGaps

            var currentY = screenTopInAX + screenPadding

            for (rowIndex, window) in column.enumerated() {
                // Compute this row's height from its ratio
                let rowHeight: CGFloat
                if rowIndex < rowRatios.count {
                    rowHeight = availableHeight * rowRatios[rowIndex]
                } else {
                    rowHeight = availableHeight / rowCount
                }

                var newFrame = CGRect(
                    x: currentX,
                    y: currentY,
                    width: columnWidth,
                    height: rowHeight
                )

                // Adjust the position if it would overflow the screen
                newFrame = adjustFrameToFitScreen(frame: newFrame, visibleFrame: visibleFrame, mainScreenHeight: mainScreenHeight)

                window.setFrame(newFrame)
                // Also update the frame held by the column structure (so stale coordinates don't linger)
                updateCachedFrame(windowID: window.id, to: newFrame, on: screenID)

                currentY += rowHeight + windowGap
            }

            currentX += columnWidth + windowGap
        }
    }

    /// Reset the ratios (call this when windows are added or removed)
    func resetRatios(for screen: NSScreen) {
        let screenID = ScreenIdentifier(from: screen)
        columnWidthRatios[screenID] = nil
        rowHeightRatios[screenID] = nil
    }

    // MARK: - Workspace State Management

    /// Save the current tiling state (used on workspace switches)
    func saveTilingStateForScreen(_ screen: NSScreen) -> PerScreenSnapshot {
        let screenID = ScreenIdentifier(from: screen)
        let columns = tiledWindows[screenID] ?? []
        let columnIDs = columns.map { column in
            column.map { $0.id }
        }
        return PerScreenSnapshot(
            columns: columnIDs,
            columnWidthRatios: columnWidthRatios[screenID],
            rowHeightRatios: rowHeightRatios[screenID]
        )
    }

    /// Restore the saved tiling state (used on workspace switches)
    func restoreTilingStateForScreen(_ screen: NSScreen, snapshot: PerScreenSnapshot) {
        let screenID = ScreenIdentifier(from: screen)
        // Restore the ratios
        columnWidthRatios[screenID] = snapshot.columnWidthRatios
        rowHeightRatios[screenID] = snapshot.rowHeightRatios

        // Restore the column structure (rebuild WindowInfo from window IDs)
        let allWindows = accessibilityManager.getAllWindows()
        let windowDict = Dictionary(uniqueKeysWithValues: allWindows.compactMap { w -> (CGWindowID, WindowInfo)? in
            return (w.id, w)
        })

        let restoredColumns: [[WindowInfo]] = snapshot.columns.compactMap { columnIDs in
            let column = columnIDs.compactMap { windowDict[$0] }
            return column.isEmpty ? nil : column
        }

        tiledWindows[screenID] = restoredColumns
    }

    /// Clear the tiling state (used when switching to a new workspace)
    func clearTilingStateForScreen(_ screen: NSScreen) {
        let screenID = ScreenIdentifier(from: screen)
        tiledWindows[screenID] = nil
        columnWidthRatios[screenID] = nil
        rowHeightRatios[screenID] = nil
    }

    /// Clean up data for a disconnected monitor
    func cleanupDisconnectedScreens() {
        let currentScreenIDs = Set(NSScreen.screens.map { ScreenIdentifier(from: $0) })
        for key in tiledWindows.keys {
            if !currentScreenIDs.contains(key) {
                tiledWindows.removeValue(forKey: key)
                columnWidthRatios.removeValue(forKey: key)
                rowHeightRatios.removeValue(forKey: key)
            }
        }
    }

    /// Get the window IDs belonging to the current workspace (for filtering)
    private func getWorkspaceWindowIDs(on screen: NSScreen) -> Set<CGWindowID> {
        let workspaceIDs = WorkspaceManager.shared.windowIDsForCurrentWorkspace(on: screen)
        // Use the on-screen IDs if the workspace hasn't been initialized
        if workspaceIDs.isEmpty && WorkspaceManager.shared.activeWorkspace.isEmpty {
            return accessibilityManager.getOnScreenWindowIDs()
        }
        return workspaceIDs
    }

    // MARK: - Center-Fixed Resize (Normal Mode)
    
    /// Grow/shrink the focused window while keeping it centered
    /// - Parameter increase: true to grow, false to shrink
    func resizeCurrentWindow(increase: Bool) {
        guard let focusedWindow = accessibilityManager.getFocusedWindow(),
              let screen = getScreen(for: focusedWindow) else {
            return
        }
        let screenID = ScreenIdentifier(from: screen)
        
        // Target only the current workspace's windows
        let workspaceIDs = getWorkspaceWindowIDs(on: screen)
        let allColumns = tiledWindows[screenID] ?? []
        let columns = allColumns.map { column in
            column.filter { workspaceIDs.contains($0.id) }
        }.filter { !$0.isEmpty }

        guard let (columnIndex, _) = findWindowPosition(window: focusedWindow, in: columns) else {
            return
        }
        
        // Can't resize when there's only one column
        guard columns.count > 1 else {
            return
        }
        
        // The resize amount (ratio change)
        let resizeStep: CGFloat = 0.05
        let delta = increase ? resizeStep : -resizeStep
        
        // Get or initialize the current ratio
        var ratios = columnWidthRatios[screenID] ?? Array(repeating: 1.0 / CGFloat(columns.count), count: columns.count)
        if ratios.count != columns.count {
            ratios = Array(repeating: 1.0 / CGFloat(columns.count), count: columns.count)
        }
        
        // Minimum ratio
        let minRatio: CGFloat = 0.1
        
        // Center-anchored resize: adjust evenly from the left and right neighboring columns
        let hasLeft = columnIndex > 0
        let hasRight = columnIndex < columns.count - 1
        
        if hasLeft && hasRight {
            // When there are neighboring columns on both sides: adjust evenly from left and right
            let halfDelta = delta / 2.0
            
            let newLeft = ratios[columnIndex - 1] - halfDelta
            let newRight = ratios[columnIndex + 1] - halfDelta
            let newCurrent = ratios[columnIndex] + delta
            
            // Minimum ratio check
            guard newLeft >= minRatio && newRight >= minRatio && newCurrent >= minRatio else {
                return
            }
            
            ratios[columnIndex - 1] = newLeft
            ratios[columnIndex + 1] = newRight
            ratios[columnIndex] = newCurrent
            
        } else if hasLeft {
            // If not at the left edge: adjust from the left
            let newLeft = ratios[columnIndex - 1] - delta
            let newCurrent = ratios[columnIndex] + delta
            
            guard newLeft >= minRatio && newCurrent >= minRatio else {
                return
            }
            
            ratios[columnIndex - 1] = newLeft
            ratios[columnIndex] = newCurrent
            
        } else if hasRight {
            // If not at the right edge: adjust from the right
            let newRight = ratios[columnIndex + 1] - delta
            let newCurrent = ratios[columnIndex] + delta
            
            guard newRight >= minRatio && newCurrent >= minRatio else {
                return
            }
            
            ratios[columnIndex + 1] = newRight
            ratios[columnIndex] = newCurrent
        }
        
        // Save the ratios
        columnWidthRatios[screenID] = ratios
        
        
        // Reapply tiling
        applyColumnTilingWithRatios(columns: columns, ratios: ratios, on: screen)
        
        // Update the border
        BorderManager.shared.updateBorder()
    }
}

// MARK: - Direction

enum Direction {
    case left   // J
    case right  // L
    case up     // I
    case down   // K
}