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

    /// The window width fraction while in Zen mode (default 75%)
    private var widthRatio: CGFloat = 0.75

    /// Save the original position of a window moved off-screen
    private var hiddenWindowFrames: [CGWindowID: CGRect] = [:]

    /// Save the WindowInfo of a window moved off-screen (so restoring doesn't depend on getAllWindows)
    private var hiddenWindowList: [WindowInfo] = []

    private init() {}

    func toggle() {
        if isActive {
            exit()
        } else {
            enter()
        }
    }

    /// Reset the state without restoring windows, and return every window's original position
    /// Used when switching directly to another mode, such as the palette
    func exitAndHandOffHiddenFrames() -> [CGWindowID: CGRect] {
        guard isActive else { return [:] }
        isActive = false
        focusedWindowID = nil
        widthRatio = 0.75
        let frames = hiddenWindowFrames
        hiddenWindowFrames.removeAll()
        hiddenWindowList.removeAll()
        return frames
    }

    private func enter() {
        guard let focusedWindow = AccessibilityManager.shared.getFocusedWindow() else {
            return
        }
        
        // Get the primary (main) monitor
        // Don't use NSScreen.main since it returns the monitor with the focused window
        guard let screen = NSScreen.screens.first else {
            return
        }
        
        
        // Save the state
        focusedWindowID = focusedWindow.id
        isActive = true
        
        // Hide the border
        BorderManager.shared.hideBorder()
        
        // Move the other windows on all monitors off-screen
        hideOtherWindows(exceptWindowID: focusedWindow.id, on: screen)

        // Also save the focused window's original position (before centering it)
        hiddenWindowFrames[focusedWindow.id] = focusedWindow.frame

        // Move the focused window to the center
        centerWindow(focusedWindow, on: screen)
        
        // Focus the window
        focusedWindow.focus()
    }
    
    func exit() {

        // Reset state (reset first to prevent re-entrancy)
        isActive = false
        focusedWindowID = nil
        widthRatio = 0.75
        
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

    private func hideOtherWindows(exceptWindowID: CGWindowID, on mainScreen: NSScreen) {
        hiddenWindowFrames.removeAll()
        hiddenWindowList.removeAll()

        // Gather the window IDs belonging to the current workspace across all monitors
        var allWorkspaceIDs = Set<CGWindowID>()
        for screen in NSScreen.screens {
            let ids = WorkspaceManager.shared.windowIDsForCurrentWorkspace(on: screen)
            allWorkspaceIDs.formUnion(ids)
        }

        // Decide which corner of the main screen to hide it in
        let corner = optimalHideCorner(for: mainScreen)

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
            if !allWorkspaceIDs.contains(window.id) {
                continue
            }

            // Save the original position and WindowInfo (so restoring doesn't depend on getAllWindows)
            hiddenWindowFrames[window.id] = window.frame
            hiddenWindowList.append(window)

            // Move to a corner of the main screen (position only, size unchanged)
            let hidePos = hidePosition(for: window, corner: corner, on: mainScreen)
            window.setPosition(hidePos)

        }

    }
    
    private func restoreHiddenWindows() {
        // Restore using the saved WindowInfo directly
        // (because getAllWindows can fail to pick up off-screen windows like Excel's)
        for window in hiddenWindowList {
            if let originalFrame = hiddenWindowFrames[window.id] {
                window.setFrame(originalFrame)
            }
        }

        hiddenWindowFrames.removeAll()
        hiddenWindowList.removeAll()
    }
    
    private func centerWindow(_ window: WindowInfo, on screen: NSScreen) {
        let visibleFrame = screen.visibleFrame
        let padding: CGFloat = 12

        // Target size (width determined by widthRatio, height fills the screen)
        let targetWidth = visibleFrame.width * widthRatio
        let targetHeight = visibleFrame.height - (padding * 2)

        // Reference value for the AX coordinate system
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let screenTopInAX = mainScreenHeight - (visibleFrame.minY + visibleFrame.height)

        // Compute the centered position at the target size and place it in one shot
        let originX = visibleFrame.minX + (visibleFrame.width - targetWidth) / 2
        let originY = screenTopInAX + (visibleFrame.height - targetHeight) / 2
        let targetFrame = CGRect(x: originX, y: originY, width: targetWidth, height: targetHeight)


        // Move it to the main monitor first, then change its size
        // (while it's on a secondary monitor, macOS constrains it to that monitor's size)
        window.setPosition(targetFrame.origin)

        let axElement = window.axElement
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            window.setFrame(targetFrame)

            // Only re-center windows that rejected the resize (fixed-size windows, etc.) afterward
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                var sizeRef: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(axElement, kAXSizeAttribute as CFString, &sizeRef)
                guard result == .success, let sizeValue = sizeRef else { return }
                var actualSize = CGSize.zero
                AXValueGetValue(sizeValue as! AXValue, .cgSize, &actualSize)

                // Only re-center it if the actual size differs significantly from the target
                let widthDiff = abs(actualSize.width - targetWidth)
                let heightDiff = abs(actualSize.height - targetHeight)
                if widthDiff > 10 || heightDiff > 10 {
                    let correctedX = visibleFrame.minX + (visibleFrame.width - actualSize.width) / 2
                    let correctedY = screenTopInAX + (visibleFrame.height - actualSize.height) / 2
                    window.setPosition(CGPoint(x: correctedX, y: correctedY))
                }
            }
        }
    }

    /// Adjusts the window width in 5% steps while in Zen mode
    func adjustWidth(increase: Bool) {
        guard isActive else { return }
        guard let focusedWindow = AccessibilityManager.shared.getFocusedWindow() else { return }
        guard let screen = NSScreen.screens.first else { return }

        let step: CGFloat = 0.05
        widthRatio = max(0.1, min(1.0, widthRatio + (increase ? step : -step)))

        centerWindow(focusedWindow, on: screen)
    }
}
