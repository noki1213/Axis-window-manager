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
    
    // MARK: - Private Methods
    
    /// Apply vertical (column) tiling
    private func applyVerticalTiling(windows: [WindowInfo], on screen: NSScreen) {
        guard !windows.isEmpty else { return }
        
        let visibleFrame = screen.visibleFrame
        let count = CGFloat(windows.count)
        
        // Available width (accounting for padding and gaps)
        let totalGaps = windowGap * (count - 1)
        let availableWidth = visibleFrame.width - (screenPadding * 2) - totalGaps
        let windowWidth = availableWidth / count
        
        // Available height
        let windowHeight = visibleFrame.height - (screenPadding * 2)
        
        // The Accessibility API's coordinate system has a top-left origin (relative to the main screen)
        // macOS NSScreen's coordinate system has its origin at the bottom-left
        // Conversion formula: AX.y = mainScreenHeight - (NSScreen.minY + NSScreen.height)
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        
        // Convert the top edge of visibleFrame to AX coordinates and add padding
        let screenTopInAX = mainScreenHeight - (visibleFrame.minY + visibleFrame.height)
        let yCoordinateForAX = screenTopInAX + screenPadding
        
        for (index, window) in windows.enumerated() {
            let x = visibleFrame.minX + screenPadding + (windowWidth + windowGap) * CGFloat(index)
            
            let newFrame = CGRect(
                x: x,
                y: yCoordinateForAX,
                width: windowWidth,
                height: windowHeight
            )
            
            window.setFrame(newFrame)
        }
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
