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
    @Published var tiledWindows: [NSScreen: [[WindowInfo]]] = [:]
    
    private let accessibilityManager = AccessibilityManager.shared
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Run tiling on the given screen
    func tile(on screen: NSScreen) {
        let allWindows = accessibilityManager.getAllWindows()
        
        // Filter to windows on this screen
        // Needs conversion between the Accessibility API's coordinate system (origin top-left) and NSScreen's (origin bottom-left)
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        
        let windowsOnScreen = allWindows.filter { window in
            // Windows that are managed and not floating
            guard window.shouldBeManaged() && !window.shouldFloat() else {
                return false
            }
            
            // Convert the window's position to the NSScreen coordinate system
            let windowY = mainScreenHeight - window.frame.origin.y - window.frame.height
            let windowCenter = CGPoint(
                x: window.frame.midX,
                y: windowY + window.frame.height / 2
            )
            
            return screen.frame.contains(windowCenter)
        }
        
        // Add the new window while preserving the existing column structure
        var columns = tiledWindows[screen] ?? []

        // Collect the window IDs contained in the current column
        let existingWindowIDs = Set(columns.flatMap { $0.map { $0.id } })

        // Add new windows (ones not already in a column)
        for window in windowsOnScreen {
            if !existingWindowIDs.contains(window.id) {
                // Add the new window as its own separate column
                columns.append([window])
            }
        }

        // Remove closed windows
        let currentWindowIDs = Set(windowsOnScreen.map { $0.id })
        columns = columns.map { column in
            column.filter { currentWindowIDs.contains($0.id) }
        }.filter { !$0.isEmpty }

        // Refresh the window info to the latest
        let windowDict = Dictionary(uniqueKeysWithValues: windowsOnScreen.map { ($0.id, $0) })
        columns = columns.map { column in
            column.compactMap { windowDict[$0.id] }
        }

        // Compute and apply the tiling layout
        applyColumnTiling(columns: columns, on: screen)

        // Update the state
        tiledWindows[screen] = columns
    }
    
    /// Run tiling across all screens
    func tileAllScreens() {
        for screen in NSScreen.screens {
            tile(on: screen)
        }
    }
    
    /// Move window focus in the given direction
    func moveFocus(direction: Direction) {
        guard let focusedWindow = accessibilityManager.getFocusedWindow(),
              let screen = getScreen(for: focusedWindow) else {
            print("[Axis] No focused window found")
            return
        }

        let columns = tiledWindows[screen] ?? []
        guard let (columnIndex, rowIndex) = findWindowPosition(window: focusedWindow, in: columns) else {
            print("[Axis] Current window not in tiled windows")
            return
        }

        var targetWindow: WindowInfo?

        switch direction {
        case .left:
            if columnIndex > 0 {
                // The same row (or the last row) of the column to the left
                let leftColumn = columns[columnIndex - 1]
                let targetRow = min(rowIndex, leftColumn.count - 1)
                targetWindow = leftColumn[targetRow]
                print("[Axis] Moving focus LEFT to: \(targetWindow?.title ?? "unknown")")
            } else {
                // If at the left edge, go to the monitor on the left
                targetWindow = getWindowOnAdjacentScreen(from: focusedWindow, direction: .left)
                print("[Axis] Moving focus to LEFT MONITOR")
            }
        case .right:
            if columnIndex < columns.count - 1 {
                // The same row (or the last row) of the column to the right
                let rightColumn = columns[columnIndex + 1]
                let targetRow = min(rowIndex, rightColumn.count - 1)
                targetWindow = rightColumn[targetRow]
                print("[Axis] Moving focus RIGHT to: \(targetWindow?.title ?? "unknown")")
            } else {
                // If at the right edge, go to the monitor on the right
                targetWindow = getWindowOnAdjacentScreen(from: focusedWindow, direction: .right)
                print("[Axis] Moving focus to RIGHT MONITOR")
            }
        case .up:
            if rowIndex > 0 {
                // The window above in the same column
                targetWindow = columns[columnIndex][rowIndex - 1]
                print("[Axis] Moving focus UP to: \(targetWindow?.title ?? "unknown")")
            } else {
                // If at the top of the column, go to the monitor above
                targetWindow = getWindowOnAdjacentScreen(from: focusedWindow, direction: .up)
                print("[Axis] Moving focus to UP MONITOR")
            }
        case .down:
            if rowIndex < columns[columnIndex].count - 1 {
                // The window below in the same column
                targetWindow = columns[columnIndex][rowIndex + 1]
                print("[Axis] Moving focus DOWN to: \(targetWindow?.title ?? "unknown")")
            } else {
                // If at the bottom of the column, go to the monitor below
                targetWindow = getWindowOnAdjacentScreen(from: focusedWindow, direction: .down)
                print("[Axis] Moving focus to DOWN MONITOR")
            }
        }

        if let target = targetWindow {
            target.focus()
            print("[Axis] Focused window: \(target.title)")
        } else {
            print("[Axis] No target window found")
        }
    }

    /// Look up a window's position (column index, row index) within the column structure
    private func findWindowPosition(window: WindowInfo, in columns: [[WindowInfo]]) -> (columnIndex: Int, rowIndex: Int)? {
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

        var columns = tiledWindows[screen] ?? []
        guard let (columnIndex, rowIndex) = findWindowPosition(window: currentWindow, in: columns) else {
            return
        }

        switch direction {
        case .left:
            if columnIndex > 0 {
                // Remove from the current column
                columns[columnIndex].remove(at: rowIndex)
                // Add to the column on the left
                let targetRow = min(rowIndex, columns[columnIndex - 1].count)
                columns[columnIndex - 1].insert(currentWindow, at: targetRow)
                // Remove columns that have become empty
                if columns[columnIndex].isEmpty {
                    columns.remove(at: columnIndex)
                }
            }
        case .right:
            if columnIndex < columns.count - 1 {
                // Remove from the current column
                columns[columnIndex].remove(at: rowIndex)
                // Add to the column on the right
                let targetRow = min(rowIndex, columns[columnIndex + 1].count)
                columns[columnIndex + 1].insert(currentWindow, at: targetRow)
                // Remove columns that have become empty
                if columns[columnIndex].isEmpty {
                    columns.remove(at: columnIndex)
                }
            }
        case .up:
            if rowIndex > 0 {
                // Move up within the same column
                columns[columnIndex].swapAt(rowIndex, rowIndex - 1)
            }
        case .down:
            if rowIndex < columns[columnIndex].count - 1 {
                // Move down within the same column
                columns[columnIndex].swapAt(rowIndex, rowIndex + 1)
            }
        }

        tiledWindows[screen] = columns
        applyColumnTiling(columns: columns, on: screen)

        // Keep focus as is
        currentWindow.focus()
    }
    
    /// Move multiple windows in the given direction (for window-selection mode)
    func moveWindows(windowIDs: Set<CGWindowID>, direction: Direction) {
        print("[Axis] moveWindows called, direction: \(direction), windowIDs: \(windowIDs)")

        guard let focusedWindow = accessibilityManager.getFocusedWindow(),
              let screen = getScreen(for: focusedWindow) else {
            print("[Axis] moveWindows: No focused window or screen")
            return
        }

        var columns = tiledWindows[screen] ?? []
        print("[Axis] moveWindows: columns count = \(columns.count)")

        // Get the position of the selected window
        var selectedPositions: [(columnIndex: Int, rowIndex: Int, window: WindowInfo)] = []
        for (colIdx, column) in columns.enumerated() {
            for (rowIdx, window) in column.enumerated() {
                if windowIDs.contains(window.id) {
                    selectedPositions.append((colIdx, rowIdx, window))
                }
            }
        }

        print("[Axis] moveWindows: selectedPositions count = \(selectedPositions.count)")

        guard !selectedPositions.isEmpty else {
            print("[Axis] moveWindows: No selected windows found in tiledWindows")
            return
        }

        switch direction {
        case .left:
            // Move left: process starting from the leftmost column
            selectedPositions.sort { $0.columnIndex < $1.columnIndex }
            for pos in selectedPositions {
                if pos.columnIndex > 0 {
                    // Remove from the current column
                    if let rowIdx = columns[pos.columnIndex].firstIndex(of: pos.window) {
                        columns[pos.columnIndex].remove(at: rowIdx)
                        // Add to the column on the left
                        columns[pos.columnIndex - 1].append(pos.window)
                    }
                }
            }
        case .right:
            // Move right: process starting from the rightmost column
            selectedPositions.sort { $0.columnIndex > $1.columnIndex }
            for pos in selectedPositions {
                if pos.columnIndex < columns.count - 1 {
                    // Remove from the current column
                    if let rowIdx = columns[pos.columnIndex].firstIndex(of: pos.window) {
                        columns[pos.columnIndex].remove(at: rowIdx)
                        // Add to the column on the right
                        columns[pos.columnIndex + 1].append(pos.window)
                    }
                }
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

        tiledWindows[screen] = columns
        applyColumnTiling(columns: columns, on: screen)

        // Keep focus as is
        focusedWindow.focus()
        print("[Axis] moveWindows: completed")
    }

    /// Put every window back into its own column (reset the vertical split)
    func resetToSingleWindowColumns() {
        print("[Axis] resetToSingleWindowColumns called")

        guard let focusedWindow = accessibilityManager.getFocusedWindow(),
              let screen = getScreen(for: focusedWindow) else {
            print("[Axis] resetToSingleWindowColumns: No focused window or screen")
            return
        }

        let columns = tiledWindows[screen] ?? []

        // Take out all the windows and make each one its own column
        let allWindows = columns.flatMap { $0 }
        let newColumns = allWindows.map { [$0] }

        print("[Axis] resetToSingleWindowColumns: resetting \(allWindows.count) windows to single columns")

        tiledWindows[screen] = newColumns
        applyColumnTiling(columns: newColumns, on: screen)

        // Keep focus as is
        focusedWindow.focus()
        print("[Axis] resetToSingleWindowColumns: completed")
    }

    /// Merge the selected windows into a single column (stack them vertically)
    func mergeWindowsIntoColumn(windowIDs: Set<CGWindowID>) {
        print("[Axis] mergeWindowsIntoColumn called, windowIDs: \(windowIDs)")

        guard let focusedWindow = accessibilityManager.getFocusedWindow(),
              let screen = getScreen(for: focusedWindow) else {
            print("[Axis] mergeWindowsIntoColumn: No focused window or screen")
            return
        }

        var columns = tiledWindows[screen] ?? []

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
            print("[Axis] mergeWindowsIntoColumn: No selected windows found")
            return
        }

        print("[Axis] mergeWindowsIntoColumn: merging \(selectedWindows.count) windows into column \(targetCol)")

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

        tiledWindows[screen] = columns
        applyColumnTiling(columns: columns, on: screen)

        // Keep focus as is
        focusedWindow.focus()
        print("[Axis] mergeWindowsIntoColumn: completed")
    }
    
    // MARK: - Private Methods

    /// Apply tiling using the column structure
    /// Windows within a column are arranged top to bottom
    private func applyColumnTiling(columns: [[WindowInfo]], on screen: NSScreen) {
        guard !columns.isEmpty else { return }

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

        for column in columns {
            guard !column.isEmpty else { continue }

            let rowCount = CGFloat(column.count)
            let totalRowGaps = windowGap * (rowCount - 1)
            let availableHeight = visibleFrame.height - (screenPadding * 2) - totalRowGaps
            let rowHeight = availableHeight / rowCount

            var currentY = screenTopInAX + screenPadding

            for window in column {
                var newFrame = CGRect(
                    x: currentX,
                    y: currentY,
                    width: columnWidth,
                    height: rowHeight
                )

                // Adjust the position if it would overflow the screen
                newFrame = adjustFrameToFitScreen(frame: newFrame, visibleFrame: visibleFrame, mainScreenHeight: mainScreenHeight)

                window.setFrame(newFrame)

                currentY += rowHeight + windowGap
            }

            currentX += columnWidth + windowGap
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
        let windowCenter = CGPoint(x: window.frame.midX, y: window.frame.midY)
        return NSScreen.screens.first { screen in
            screen.frame.contains(windowCenter)
        }
    }
    
    /// Get the windows on the neighboring screen
    private func getWindowOnAdjacentScreen(from window: WindowInfo, direction: Direction) -> WindowInfo? {
        guard let currentScreen = getScreen(for: window) else { return nil }

        let adjacentScreen = getAdjacentScreen(from: currentScreen, direction: direction)
        guard let targetScreen = adjacentScreen else { return nil }

        let columns = tiledWindows[targetScreen] ?? []
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
                // Whether it's on the current screen
                return otherFrame.minY >= currentFrame.maxY - 1 &&
                       otherFrame.minX < currentFrame.maxX &&
                       otherFrame.maxX > currentFrame.minX
            case .down:
                // Whether it's below the current screen
                return otherFrame.maxY <= currentFrame.minY + 1 &&
                       otherFrame.minX < currentFrame.maxX &&
                       otherFrame.maxX > currentFrame.minX
            }
        }
    }
}

// MARK: - Direction

enum Direction {
    case left   // J
    case right  // L
    case up     // I
    case down   // K
}
