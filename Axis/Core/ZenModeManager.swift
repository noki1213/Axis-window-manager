//
//  ZenModeManager.swift
//  Axis
//
//  Created on 2026/01/29.
//

import AppKit
import Combine

/// Zen Mode: display the focused window centered
class ZenModeManager: ObservableObject {
    static let shared = ZenModeManager()

    @Published var isActive: Bool = false
    
    private var focusedWindowID: CGWindowID?
    
    /// Save the original position of a window moved off-screen
    private var hiddenWindowFrames: [CGWindowID: CGRect] = [:]

    private init() {}

    func toggle() {
        if isActive {
            exit()
        } else {
            enter()
        }
    }

    private func enter() {
        guard let focusedWindow = AccessibilityManager.shared.getFocusedWindow() else {
            print("[Axis] ZenMode: No focused window")
            return
        }
        
        guard let screen = NSScreen.main else {
            print("[Axis] ZenMode: No screen")
            return
        }
        
        print("[Axis] ZenMode: Entering with window '\(focusedWindow.title)'")
        
        // Save the state
        focusedWindowID = focusedWindow.id
        isActive = true
        
        // Hide the border
        BorderManager.shared.hideBorder()
        
        // Move other windows off-screen (same screen only)
        hideOtherWindows(exceptWindowID: focusedWindow.id, on: screen)
        
        // Move the focused window to the center
        centerWindow(focusedWindow, on: screen)
        
        // Focus the window
        focusedWindow.focus()
    }
    
    private func exit() {
        print("[Axis] ZenMode: Exiting, will restore \(hiddenWindowFrames.count) windows")
        
        // Reset state (reset first to prevent re-entrancy)
        isActive = false
        focusedWindowID = nil
        
        // Move a window that ended up off-screen back to its original position
        restoreHiddenWindows()
        
        // Retile after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Retiling puts it back in its original position
            TilingEngine.shared.tileAllScreens()
            
            // Update the border
            BorderManager.shared.updateBorder()
        }
    }
    
    // MARK: - Hide Corner (the AeroSpace approach)

    /// The corner used to hide a window
    private enum HideCorner {
        case bottomLeft
        case bottomRight
    }

    /// Determine the best hidden corner for the given monitor
    /// Avoid the side that has a neighboring monitor
    private func optimalHideCorner(for screen: NSScreen) -> HideCorner {
        let screenFrame = screen.frame

        // Check whether there's another monitor to the right
        var hasMonitorOnRight = false
        for otherScreen in NSScreen.screens {
            if otherScreen == screen { continue }

            // If another monitor's left edge is near this monitor's right edge, treat it as being "to the right"
            if otherScreen.frame.minX >= screenFrame.maxX - 10 {
                hasMonitorOnRight = true
                break
            }
        }

        // Bottom-left if there's a monitor to the right, otherwise bottom-right (default)
        return hasMonitorOnRight ? .bottomLeft : .bottomRight
    }

    /// Compute the position for hiding a window (AX coordinates: top-left origin, Y increases downward)
    /// Position it at the monitor's corner, leaving just 1 pixel inside the monitor
    private func hidePosition(for window: WindowInfo, corner: HideCorner, on screen: NSScreen) -> CGPoint {
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let visibleFrame = screen.visibleFrame

        // Convert visibleFrame to AX coordinates
        let axVisibleBottom = mainScreenHeight - visibleFrame.minY

        switch corner {
        case .bottomLeft:
            // Position it so the window's right edge sits 1px inside visibleFrame's left edge
            let x = visibleFrame.minX - window.frame.width + 1
            // Position it so the window's top edge sits 1px inside visibleFrame's bottom edge
            let y = axVisibleBottom - 1
            return CGPoint(x: x, y: y)

        case .bottomRight:
            // Position it so the window's left edge sits 1px inside visibleFrame's right edge
            let x = visibleFrame.maxX - 1
            // Position it so the window's top edge sits 1px inside visibleFrame's bottom edge
            let y = axVisibleBottom - 1
            return CGPoint(x: x, y: y)
        }
    }

    private func hideOtherWindows(exceptWindowID: CGWindowID, on targetScreen: NSScreen) {
        hiddenWindowFrames.removeAll()

        // Get the window IDs that belong to the current workspace
        let workspaceIDs = WorkspaceManager.shared.windowIDsForCurrentWorkspace(on: targetScreen)

        // Decide the best corner to hide it in
        let corner = optimalHideCorner(for: targetScreen)

        // Get all windows
        let allWindows = AccessibilityManager.shared.getAllWindows()

        for window in allWindows {
            // Skip the focused window
            if window.id == exceptWindowID {
                continue
            }

            // Skip minimized windows
            if window.isMinimized {
                continue
            }

            // Skip windows that don't belong to the current workspace
            if !workspaceIDs.contains(window.id) {
                continue
            }

            // Save the original position
            hiddenWindowFrames[window.id] = window.frame

            // Move to the corner (position only, size unchanged)
            let hidePos = hidePosition(for: window, corner: corner, on: targetScreen)
            window.setPosition(hidePos)

            print("[Axis] ZenMode: Moved window '\(window.title)' to corner")
        }

        print("[Axis] ZenMode: Hidden \(hiddenWindowFrames.count) windows using corner: \(corner)")
    }
    
    private func restoreHiddenWindows() {
        // Get all windows
        let allWindows = AccessibilityManager.shared.getAllWindows()
        
        for window in allWindows {
            // Restore the saved frame if there is one
            if let originalFrame = hiddenWindowFrames[window.id] {
                window.setFrame(originalFrame)
                print("[Axis] ZenMode: Restored window '\(window.title)' to \(originalFrame)")
            }
        }
        
        print("[Axis] ZenMode: Restored \(hiddenWindowFrames.count) windows")
        hiddenWindowFrames.removeAll()
    }
    
    private func centerWindow(_ window: WindowInfo, on screen: NSScreen) {
        let visibleFrame = screen.visibleFrame
        let padding: CGFloat = 12
        
        // Size: 75% width, full screen height
        let targetWidth = visibleFrame.width * 0.75
        let targetHeight = visibleFrame.height - (padding * 2)
        
        // Center it
        let originX = visibleFrame.minX + (visibleFrame.width - targetWidth) / 2
        
        // Convert to AX coordinates
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let screenTopInAX = mainScreenHeight - (visibleFrame.minY + visibleFrame.height)
        let originY = screenTopInAX + padding
        
        let targetFrame = CGRect(x: originX, y: originY, width: targetWidth, height: targetHeight)
        
        print("[Axis] ZenMode: Moving window to \(targetFrame)")
        window.setFrame(targetFrame)
    }
}
