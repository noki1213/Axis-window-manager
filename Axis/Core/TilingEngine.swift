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
    
    /// The currently tiled windows (per screen)
    @Published var tiledWindows: [NSScreen: [WindowInfo]] = [:]
    
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
        
        // Compute and apply the tiling layout
        applyVerticalTiling(windows: windowsOnScreen, on: screen)
        
        // Update the state
        tiledWindows[screen] = windowsOnScreen
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
        
        let windowsOnScreen = tiledWindows[screen] ?? []
        guard let currentIndex = windowsOnScreen.firstIndex(of: focusedWindow) else {
            print("[Axis] Current window not in tiled windows")
            return
        }
        
        var targetWindow: WindowInfo?
        
        switch direction {
        case .left:
            if currentIndex > 0 {
                targetWindow = windowsOnScreen[currentIndex - 1]
                print("[Axis] Moving focus LEFT to: \(targetWindow?.title ?? "unknown")")
            } else {
                // If at the left edge, go to the monitor on the left
                targetWindow = getWindowOnAdjacentScreen(from: focusedWindow, direction: .left)
                print("[Axis] Moving focus to LEFT MONITOR")
            }
        case .right:
            if currentIndex < windowsOnScreen.count - 1 {
                targetWindow = windowsOnScreen[currentIndex + 1]
                print("[Axis] Moving focus RIGHT to: \(targetWindow?.title ?? "unknown")")
            } else {
                // If at the right edge, go to the monitor on the right
                targetWindow = getWindowOnAdjacentScreen(from: focusedWindow, direction: .right)
                print("[Axis] Moving focus to RIGHT MONITOR")
            }
        case .up, .down:
            // No vertical split in Phase 1, so only monitor movement
            targetWindow = getWindowOnAdjacentScreen(from: focusedWindow, direction: direction)
            print("[Axis] Moving focus \(direction == .up ? "UP" : "DOWN")")
        }
        
        if let target = targetWindow {
            target.focus()
            print("[Axis] Focused window: \(target.title)")
        } else {
            print("[Axis] No target window found")
        }
    }
    
    /// Move the window in the given direction (rearrange its placement)
    func moveWindow(direction: Direction) {
        guard let currentWindow = accessibilityManager.getFocusedWindow(),
              let screen = getScreen(for: currentWindow) else {
            return
        }
        
        var windowsOnScreen = tiledWindows[screen] ?? []
        guard let currentIndex = windowsOnScreen.firstIndex(of: currentWindow) else {
            return
        }
        
        switch direction {
        case .left:
            if currentIndex > 0 {
                windowsOnScreen.swapAt(currentIndex, currentIndex - 1)
            }
        case .right:
            if currentIndex < windowsOnScreen.count - 1 {
                windowsOnScreen.swapAt(currentIndex, currentIndex + 1)
            }
        case .up, .down:
            // Not supported in Phase 1
            break
        }
        
        tiledWindows[screen] = windowsOnScreen
        applyVerticalTiling(windows: windowsOnScreen, on: screen)
        
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
        
        var windowsOnScreen = tiledWindows[screen] ?? []
        print("[Axis] moveWindows: windowsOnScreen count = \(windowsOnScreen.count)")
        
        // Get the indices of the selected windows (sorted)
        let selectedIndices = windowsOnScreen.enumerated()
            .filter { windowIDs.contains($0.element.id) }
            .map { $0.offset }
            .sorted()
        
        print("[Axis] moveWindows: selectedIndices = \(selectedIndices)")
        
        guard !selectedIndices.isEmpty else {
            print("[Axis] moveWindows: No selected windows found in tiledWindows")
            return
        }
        
        switch direction {
        case .left:
            // Move left: process from the leftmost one in order
            for index in selectedIndices {
                if index > 0 && !windowIDs.contains(windowsOnScreen[index - 1].id) {
                    windowsOnScreen.swapAt(index, index - 1)
                    print("[Axis] moveWindows: Swapped index \(index) with \(index - 1)")
                }
            }
        case .right:
            // Move right: process from the rightmost one in order
            for index in selectedIndices.reversed() {
                if index < windowsOnScreen.count - 1 && !windowIDs.contains(windowsOnScreen[index + 1].id) {
                    windowsOnScreen.swapAt(index, index + 1)
                    print("[Axis] moveWindows: Swapped index \(index) with \(index + 1)")
                }
            }
        case .up, .down:
            // Only columns exist for now, so up/down movement isn't supported yet
            print("[Axis] moveWindows: up/down not supported yet")
            break
        }
        
        tiledWindows[screen] = windowsOnScreen
        applyVerticalTiling(windows: windowsOnScreen, on: screen)
        
        // Keep focus as is
        focusedWindow.focus()
        print("[Axis] moveWindows: completed")
    }
    
    // MARK: - Private Methods
    
    /// Apply vertical (column) tiling
    /// Takes minimum size into account, and allows windows to overlap if they don't all fit (AeroSpace's approach)
    private func applyVerticalTiling(windows: [WindowInfo], on screen: NSScreen) {
        guard !windows.isEmpty else { return }
        
        let visibleFrame = screen.visibleFrame
        let count = CGFloat(windows.count)
        
        // Available width (accounting for padding and gaps)
        let totalGaps = windowGap * (count - 1)
        let availableWidth = visibleFrame.width - (screenPadding * 2) - totalGaps
        let idealWindowWidth = availableWidth / count
        
        // Available height
        let availableHeight = visibleFrame.height - (screenPadding * 2)
        
        // Calculate each window's width (taking the minimum size into account)
        let windowWidths = calculateWindowWidths(
            windows: windows,
            availableWidth: availableWidth,
            idealWidth: idealWindowWidth
        )
        
        // The Accessibility API's coordinate system has a top-left origin (relative to the main screen)
        // macOS NSScreen's coordinate system has its origin at the bottom-left
        // Conversion formula: AX.y = mainScreenHeight - (NSScreen.minY + NSScreen.height)
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        
        // Convert the top edge of visibleFrame to AX coordinates and add padding
        let screenTopInAX = mainScreenHeight - (visibleFrame.minY + visibleFrame.height)
        let yCoordinateForAX = screenTopInAX + screenPadding
        
        var currentX = visibleFrame.minX + screenPadding
        
        for (index, window) in windows.enumerated() {
            let windowWidth = windowWidths[index]
            // Also factor the minimum size into the height (but never shrink it below the available height)
            let windowHeight = max(window.minSize.height, availableHeight)
            
            var newFrame = CGRect(
                x: currentX,
                y: yCoordinateForAX,
                width: windowWidth,
                height: windowHeight
            )
            
            // Adjust the position if it would go off-screen (based on Rectangle's BestEffortWindowMover)
            newFrame = adjustFrameToFitScreen(frame: newFrame, visibleFrame: visibleFrame, mainScreenHeight: mainScreenHeight)
            
            window.setFrame(newFrame)
            
            currentX += windowWidth + windowGap
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
        
        let windowsOnTargetScreen = tiledWindows[targetScreen] ?? []
        
        switch direction {
        case .left:
            // If it's the monitor on the left, use the rightmost window
            return windowsOnTargetScreen.last
        case .right:
            // If it's the monitor on the right, use the leftmost window
            return windowsOnTargetScreen.first
        case .up, .down:
            // For a monitor above or below, the window with the closest X coordinate
            let windowCenterX = window.frame.midX
            return windowsOnTargetScreen.min { w1, w2 in
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
