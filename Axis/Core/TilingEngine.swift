//
//  TilingEngine.swift
//  Axis
//
//  Created on 2026/01/27.
//

import AppKit
import Combine

/// The tiling operations: focus moves, column moves and resizes as commands on the tracking state,
/// whose plans put the windows in their slots
class TilingEngine: ObservableObject {
    static let shared = TilingEngine()
    
    // MARK: - Configuration
    
    /// The gap between windows (in pixels)
    @Published var windowGap: CGFloat = 12 {
        didSet { applyLayoutConfig() }
    }
    
    /// The padding from the screen edge (in pixels)
    @Published var screenPadding: CGFloat = 12 {
        didSet { applyLayoutConfig() }
    }

    /// The gap and padding as the tracking state lays them out
    var layoutConfig: LayoutConfig {
        LayoutConfig(gap: windowGap, padding: screenPadding)
    }
    
    // MARK: - State

    /// Record the monitor when the mouse moves to an empty one
    /// Used for focus movement and Space switching when there's no focused window
    /// Automatically reset to nil once focus moves to the window
    var cursorScreen: NSScreen?

    private let accessibilityManager = AccessibilityManager.shared
    private var coordinator: TrackingCoordinator { TrackingCoordinator.shared }

    private init() {}

    /// The tiled windows of the workspace shown on `screen`, per column (top to bottom), from the
    /// tracking state. Windows out of the layout this moment (on another Space, say) are left out.
    func tiledColumns(on screen: NSScreen) -> [[WindowInfo]] {
        let state = coordinator.state
        guard let key = WorkspaceManager.shared.monitorKey(for: screen), let active = state.activeWorkspace(key) else { return [] }
        return state.layoutColumns(active)
            .map { column in column.compactMap { coordinator.windowInfo($0) } }
            .filter { !$0.isEmpty }
    }

    /// The new gap and padding apply from the next layout on (Settings has a re-tile button)
    private func applyLayoutConfig() {
        let config = layoutConfig
        guard coordinator.isRunning, coordinator.state.config != config else { return }
        coordinator.note { state in
            state.config = config
        }
    }
    
    // MARK: - Public Methods
    
    /// Lay the windows out again where they are off their slots or out of sight where they should be
    /// parked, and bring floating windows on the given screen back over the tiles
    /// - Parameter reason: what triggered this pass (defaults to the caller's function name)
    func tile(on screen: NSScreen, reason: String = #function) {
        coordinator.perform("retile") { _ in }
        raiseFloatingWindows(on: screen)
    }

    /// Raise the floating windows (explicitly marked Float, or shouldFloat) on the given screen to the front
    /// Calling this on every tiling pass prevents dialogs and the like from staying stuck behind the tiles.
    /// Doesn't steal focus.
    /// - Parameter allowActivation: also bring buried windows forward by activating their app. kAXRaiseAction
    ///   only reorders a window within its own app, so a floating window of an inactive app stays behind the
    ///   active app's tiles even when the action reports success. That moves focus to the floating window,
    ///   so it's reserved for the explicit hotkey; the automatic passes stay silent
    func raiseFloatingWindows(on screen: NSScreen, allowActivation: Bool = false) {
        let accessibilityManager = AccessibilityManager.shared
        let onScreenIDs = accessibilityManager.getOnScreenWindowIDs()
        let zenHiddenIDs = ZenModeManager.shared.hiddenWindowIDs
        let myPID = ProcessInfo.processInfo.processIdentifier

        // For converting AX coordinates (top-left origin) to NSScreen coordinates (bottom-left origin)
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0

        // Front-to-back list of the normal-layer windows on this screen (CGWindowList is ordered front first)
        var stackingOrder: [(id: CGWindowID, bounds: CGRect)] = []
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
                    if let id = entry[kCGWindowNumber as String] as? CGWindowID,
                       (entry[kCGWindowLayer as String] as? Int ?? 0) == 0 {
                        stackingOrder.append((id: id, bounds: bounds))
                    }
                }
            }
            return accessibilityManager.getWindows(forPIDs: targetPIDs)
        }

        /// Whether a tiled window overlaps this one from above (a window on a higher level never is)
        func isBuriedUnderTile(_ window: WindowInfo) -> Bool {
            guard let index = stackingOrder.firstIndex(where: { $0.id == window.id }) else { return false }
            let bounds = stackingOrder[index].bounds
            return stackingOrder[..<index].contains { above in
                WorkspaceManager.shared.isWindowInAnyWorkspace(above.id)
                    && !WorkspaceManager.shared.isFloating(above.id)
                    && above.bounds.intersects(bounds)
            }
        }

        // Windows that reject kAXRaiseAction
        var needsActivation: [WindowInfo] = []
        // Windows that accepted kAXRaiseAction but whose app still has to come forward
        var needsFocus: [WindowInfo] = []

        /// Log why a window was passed over, only for the explicit hotkey (automatic passes run constantly)
        func skip(_ window: WindowInfo, _ reason: String) {
            if allowActivation { PerfLog.event("raiseFloating: skip \(PerfLog.describe(window)) (\(reason))") }
        }

        for window in targetWindows {
            // Axis's own windows are excluded
            guard window.app.processIdentifier != myPID else { continue }
            // Windows not showing on screen are excluded
            guard onScreenIDs.contains(window.id) else { skip(window, "off screen"); continue }
            // Windows currently evacuated (another workspace, the palette, Zen) are excluded
            guard !WorkspaceManager.shared.isWindowHidden(window.id) else { skip(window, "workspace hidden"); continue }
            guard !WindowPaletteManager.shared.isWindowHidden(window.id) else { skip(window, "palette hidden"); continue }
            guard !zenHiddenIDs.contains(window.id) else { skip(window, "zen hidden"); continue }
            // Floating windows only (explicitly marked Float, or otherwise eligible to float).
            // The explicit hotkey also takes windows that belong to no workspace (e.g. "About This Mac"):
            // they never get tiled, yet don't qualify as floating by size or subrole
            let isUntiled = WorkspaceManager.shared.isFloating(window.id) || window.shouldFloat()
                || (allowActivation && !WorkspaceManager.shared.isWindowInAnyWorkspace(window.id))
            guard isUntiled else { skip(window, "tiled"); continue }
            // Only raise genuine windows (standard windows or dialogs)
            // (so we don't raise invisible helper windows, like Arc's, on every pass)
            guard window.shouldBeManaged()
                || window.subrole == kAXDialogSubrole as String
                || window.subrole == kAXSystemDialogSubrole as String else { skip(window, "not a real window: \(window.subrole ?? "nil")"); continue }
            // Only the ones on this screen (judged by window center)
            let center = CGPoint(x: window.frame.midX, y: mainScreenHeight - window.frame.midY)
            guard screen.frame.contains(center) else { continue }
            // Only windows that are actually under a tile. kAXRaiseAction runs makeKeyAndOrderFront in
            // the target app, and on a non-activating panel that makes it the key window without
            // activating its app: keyboard input silently goes to the panel while the focused tile
            // still looks focused. Windows already on top (or on a higher window level) are left alone
            guard isBuriedUnderTile(window) else { skip(window, "not under a tile"); continue }

            let result = AXUIElementPerformAction(window.axElement, kAXRaiseAction as CFString)
            // System Settings answers kAXRaiseAction with attributeUnsupported (-25205) rather than actionUnsupported
            if allowActivation {
                if result == .actionUnsupported || result == .attributeUnsupported {
                    needsActivation.append(window)
                } else {
                    needsFocus.append(window)
                }
            }
        }

        // Fallback for windows that can't be raised through AX: activating the app is the only
        // way to bring them forward
        for window in needsActivation {
            PerfLog.event("raiseFloating: activating \(PerfLog.describe(window)) (AXRaise unsupported)")
            _ = window.activateBringingToFront()
        }
        // Focus targets just that window, so the app's tiled windows stay where they are
        for window in needsFocus {
            PerfLog.event("raiseFloating: focusing \(PerfLog.describe(window))")
            window.focus()
        }
    }

    /// Lay out every screen again
    /// - Parameter reason: what triggered this pass (defaults to the caller's function name)
    func tileAllScreens(reason: String = #function) {
        coordinator.perform("retile") { _ in }
        for screen in NSScreen.screens {
            raiseFloatingWindows(on: screen)
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
        // The tiles of the workspace shown on this screen
        var columns = tiledColumns(on: screen)
        let workspaceIDs = WorkspaceManager.shared.windowIDsForCurrentWorkspace(on: screen)

        // Floating windows are also inserted into a column based on X coordinate (so they're reachable by focus movement)
        let floatIDs = WorkspaceManager.shared.floatWindowIDs
        if !floatIDs.isEmpty {
            let allWins = accessibilityManager.getAllWindows()
            let floatWindows = allWins.filter { floatIDs.contains($0.id) && workspaceIDs.contains($0.id) }
                .sorted { $0.frame.midX < $1.frame.midX }
            for hw in floatWindows {
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
            // The focused window isn't part of the layout (a dialog, System Settings, or anything else
            // that floats on its own without being marked Float). Rather than leaving the key dead,
            // jump to the nearest tile in the requested direction, or the nearest tile at all
            let candidates = columns.flatMap { $0 }.filter { $0.id != focusedWindow.id }
            if let target = nearestWindow(from: focusedWindow, in: direction, among: candidates) {
                target.focus()
                moveCursorToWindow(target)
                return target.id
            }
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

    /// The window closest to `origin` whose center lies in the given direction;
    /// falls back to the closest window in any direction when none lies that way
    private func nearestWindow(from origin: WindowInfo, in direction: Direction, among candidates: [WindowInfo]) -> WindowInfo? {
        let from = CGPoint(x: origin.frame.midX, y: origin.frame.midY)
        func distance(_ window: WindowInfo) -> CGFloat {
            hypot(window.frame.midX - from.x, window.frame.midY - from.y)
        }
        // AX coordinates have their origin at the top-left, so "up" means a smaller Y
        let inDirection = candidates.filter { window in
            switch direction {
            case .left:  return window.frame.midX < from.x
            case .right: return window.frame.midX > from.x
            case .up:    return window.frame.midY < from.y
            case .down:  return window.frame.midY > from.y
            }
        }
        return (inDirection.isEmpty ? candidates : inDirection).min { distance($0) < distance($1) }
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
        let zenHiddenIDs = ZenModeManager.shared.hiddenWindowIDs
        let localColumns = tiledColumns(on: screen).map { col in
            col.filter { !zenHiddenIDs.contains($0.id) }
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
        let zenHiddenIDs = ZenModeManager.shared.hiddenWindowIDs
        let columns = tiledColumns(on: targetScreen).map { col in
            col.filter { !zenHiddenIDs.contains($0.id) }
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
    
    /// Move the window in the given direction (rearrange its placement): left and right swap whole
    /// columns, up and down swap it within its column; at the edge it moves to the next monitor
    func moveWindow(direction: Direction) {
        guard let currentWindow = accessibilityManager.getFocusedWindow() else { return }
        var result = ColumnMoveResult.none
        coordinator.perform("move") { state in
            result = state.moveWindow(currentWindow.id, direction.moveDirection)
        }
        guard result != .none else { return }

        // Keep focus as is, and move the cursor too
        currentWindow.focus()
        moveCursorToWindow(currentWindow)
        BorderManager.shared.updateBorder()
    }

    /// Move the focused window one step in the given direction (merge/split, equivalent to niri's/PaperWM's consume/expel)
    /// - If it's in a column with other windows: leave that column and insert it as its own column next to the neighbor in the given direction (detach)
    /// - If it's alone in its column: merge onto the end of the neighboring column in the given direction (attach). Do nothing if there's no neighboring column
    func stepMoveWindow(direction: Direction) {
        guard direction == .left || direction == .right else { return }
        guard let currentWindow = accessibilityManager.getFocusedWindow() else { return }
        var moved = false
        coordinator.perform("step move") { state in
            moved = state.stepMove(currentWindow.id, direction.moveDirection)
        }
        guard moved else { return }

        // Keep focus as is, and move the cursor too
        currentWindow.focus()
        moveCursorToWindow(currentWindow)
        BorderManager.shared.updateBorder()
    }

    /// Given each column's slot count, compute the frame (in AX coordinates) of every slot under an even split
    func slotFrames(columnSizes: [Int], on screen: NSScreen) -> [[CGRect]] {
        guard let key = WorkspaceManager.shared.monitorKey(for: screen),
              let visibleFrame = coordinator.state.monitors[key]?.visibleFrame else { return [] }
        return ColumnLayout.slotFrames(columnSizes: columnSizes, visibleFrame: visibleFrame, config: layoutConfig)
    }

    /// Pre-place the existing windows (provisional tiling) to clear space for the reserved slot, and return the reserved slot's CGRect (AX coordinates)
    func applyReservedSlotLayout(columnIndex: Int, kind: PlacementReservationKind, on screen: NSScreen) -> CGRect? {
        guard kind != .float else { return nil }

        let columns = tiledColumns(on: screen)

        // When there are zero windows (empty columns): reserve a single slot covering the whole screen
        if columns.isEmpty || columns.allSatisfy({ $0.isEmpty }) {
            let frames = slotFrames(columnSizes: [1], on: screen)
            guard let reservedFrame = frames.first?.first else { return nil }
            return reservedFrame
        }

        var columnSizes = columns.map { $0.count }
        var reservedColIndex: Int = 0
        var reservedRowIndex: Int = 0

        switch kind {
        case .aboveInColumn:
            let clampedCol = min(max(columnIndex, 0), columns.count - 1)
            columnSizes[clampedCol] += 1
            reservedColIndex = clampedCol
            reservedRowIndex = 0

        case .belowInColumn:
            let clampedCol = min(max(columnIndex, 0), columns.count - 1)
            columnSizes[clampedCol] += 1
            reservedColIndex = clampedCol
            reservedRowIndex = columnSizes[clampedCol] - 1

        case .newColumnLeft:
            let insertCol = min(max(columnIndex, 0), columns.count)
            columnSizes.insert(1, at: insertCol)
            reservedColIndex = insertCol
            reservedRowIndex = 0

        case .newColumnRight:
            let insertCol = min(max(columnIndex + 1, 0), columns.count)
            columnSizes.insert(1, at: insertCol)
            reservedColIndex = insertCol
            reservedRowIndex = 0

        case .float:
            return nil
        }

        let frames = slotFrames(columnSizes: columnSizes, on: screen)
        guard reservedColIndex < frames.count, reservedRowIndex < frames[reservedColIndex].count else { return nil }
        let reservedFrame = frames[reservedColIndex][reservedRowIndex]

        // Place existing real windows into the non-reserved slots
        for (colIdx, column) in columns.enumerated() {
            let targetColIdx: Int
            switch kind {
            case .aboveInColumn, .belowInColumn:
                targetColIdx = colIdx
            case .newColumnLeft, .newColumnRight:
                targetColIdx = (colIdx >= reservedColIndex) ? colIdx + 1 : colIdx
            case .float:
                continue
            }

            for (rowIdx, window) in column.enumerated() {
                let targetRowIdx: Int
                if kind == .aboveInColumn && colIdx == reservedColIndex {
                    targetRowIdx = rowIdx + 1
                } else {
                    targetRowIdx = rowIdx
                }

                guard targetColIdx < frames.count, targetRowIdx < frames[targetColIdx].count else { continue }
                let newFrame = frames[targetColIdx][targetRowIdx]
                window.setFrame(newFrame)
            }
        }

        return reservedFrame
    }

    /// Put every window back into its own column (reset the vertical split)
    func resetToSingleWindowColumns() {
        guard let focusedWindow = accessibilityManager.getFocusedWindow(),
              let screen = getScreen(for: focusedWindow),
              let workspace = activeWorkspace(on: screen) else {
            return
        }
        coordinator.perform("reset layout") { state in
            state.resetToSingleColumns(workspace)
        }

        // Keep focus as is
        focusedWindow.focus()
    }

    // MARK: - Private Methods

    /// The workspace shown on `screen`
    private func activeWorkspace(on screen: NSScreen) -> WorkspaceID? {
        WorkspaceManager.shared.monitorKey(for: screen).flatMap { coordinator.state.activeWorkspace($0) }
    }

    /// Start the border's slide toward the focused window's new slot right away
    private func moveBorderToSlot(of windowID: CGWindowID?) {
        guard let windowID, let target = coordinator.state.expectedFrame(windowID) else { return }
        BorderManager.shared.updateBorder(withExplicitTarget: target)
    }
    
    /// Get the screen the window belongs to
    private func getScreen(for window: WindowInfo) -> NSScreen? {
        window.screen
    }
    
    /// Get the windows on the neighboring screen
    private func getWindowOnAdjacentScreen(from window: WindowInfo, direction: Direction) -> WindowInfo? {
        guard let currentScreen = getScreen(for: window) else { return nil }

        let adjacentScreen = getAdjacentScreen(from: currentScreen, direction: direction)
        guard let targetScreen = adjacentScreen else { return nil }
        // The current workspace's tiles, without the windows Zen mode moved off-screen
        let zenHiddenIDs = ZenModeManager.shared.hiddenWindowIDs
        let columns = tiledColumns(on: targetScreen).map { column in
            column.filter { !zenHiddenIDs.contains($0.id) }
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

    /// Resize the gap between columns
    /// - Parameters:
    ///   - columnIndex: the index of the column on the left
    ///   - delta: the amount to move (positive: rightward, negative: leftward)
    ///   - screen: the target screen
    func resizeColumnGap(at columnIndex: Int, delta: CGFloat, on screen: NSScreen) {
        guard let workspace = activeWorkspace(on: screen) else { return }
        var resized = false
        coordinator.perform("resize") { state in
            resized = state.resizeColumnGap(in: workspace, at: columnIndex, delta: delta)
        }
        if resized {
            moveBorderToSlot(of: accessibilityManager.getFocusedWindow()?.id)
        }
    }

    /// Resize the gap between rows
    /// - Parameters:
    ///   - columnIndex: the column's index
    ///   - rowIndex: the row index of the window above
    ///   - delta: the amount to move (positive: downward, negative: upward)
    ///   - screen: the target screen
    func resizeRowGap(columnIndex: Int, rowIndex: Int, delta: CGFloat, on screen: NSScreen) {
        guard let workspace = activeWorkspace(on: screen) else { return }
        var resized = false
        coordinator.perform("resize") { state in
            resized = state.resizeRowGap(in: workspace, column: columnIndex, row: rowIndex, delta: delta)
        }
        if resized {
            moveBorderToSlot(of: accessibilityManager.getFocusedWindow()?.id)
        }
    }

    // MARK: - Center-Fixed Resize (Normal Mode)
    
    /// Grow/shrink the focused window's column while keeping it centered, taking the change from
    /// the neighboring columns
    /// - Parameter increase: true to grow, false to shrink
    func resizeCurrentWindow(increase: Bool) {
        guard let focusedWindow = accessibilityManager.getFocusedWindow() else { return }
        var resized = false
        coordinator.perform("resize") { state in
            resized = state.resizeWindow(focusedWindow.id, increase: increase)
        }
        guard resized else { return }

        // Update the border
        moveBorderToSlot(of: focusedWindow.id)
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

extension Direction {
    /// The same direction for the tracking state's column operations
    var moveDirection: MoveDirection {
        switch self {
        case .left: return .left
        case .right: return .right
        case .up: return .up
        case .down: return .down
        }
    }
}
