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
    
    private(set) var focusedWindowID: CGWindowID?

    /// The screen Zen mode is active on (used so a Space switch on another monitor doesn't cancel it)
    private(set) var activeScreen: NSScreen?

    /// The window width fraction while in Zen mode (default 75%)
    private var widthRatio: CGFloat = 0.75

    /// Save the original position of a window moved off-screen
    private var hiddenWindowFrames: [CGWindowID: CGRect] = [:]

    /// The set of window IDs hidden off-screen by Zen mode (used by TilingEngine to exclude them from focus candidates)
    /// Doesn't include the focused window itself (it's saved in hiddenWindowFrames for restoration, but is actually visible)
    var hiddenWindowIDs: Set<CGWindowID> {
        var ids = Set(hiddenWindowFrames.keys)
        if let focusedID = focusedWindowID {
            ids.remove(focusedID)
        }
        return ids
    }

    /// Save the WindowInfo of a window moved off-screen (so restoring doesn't depend on getAllWindows)
    private var hiddenWindowList: [WindowInfo] = []

    private init() {}

    // MARK: - Diagnostics (pinning down what unintentionally cancels Zen mode)

    /// Return the hidden window's "app name / title" (for logging)
    func hiddenWindowDescription(for id: CGWindowID) -> String? {
        guard let window = hiddenWindowList.first(where: { $0.id == id }) else { return nil }
        return "\(window.app.localizedName ?? "?") / \(window.title)"
    }

    /// Read the hidden window's current position back from AX and return it (for logging)
    /// Used to check whether the 1px-left-in-the-corner placement is being maintained
    func hiddenWindowCurrentFrame(for id: CGWindowID) -> CGRect? {
        guard let window = hiddenWindowList.first(where: { $0.id == id }) else { return nil }
        guard let refreshed = WindowInfo(axElement: window.axElement, app: window.app) else {
            return window.frame
        }
        return refreshed.frame
    }

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
        activeScreen = nil
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

        // Get the monitor the focused window is on
        guard let screen = screenContaining(focusedWindow) else {
            return
        }

        // Save the state
        focusedWindowID = focusedWindow.id
        activeScreen = screen
        isActive = true

        // Move only the other windows on the same monitor off-screen
        hideOtherWindows(exceptWindowID: focusedWindow.id, on: screen)

        // Also save the focused window's original position (before centering it)
        hiddenWindowFrames[focusedWindow.id] = focusedWindow.frame

        // Move the focused window to the center
        centerWindow(focusedWindow, on: screen)

        // Focus the window
        focusedWindow.focus()

        // Update the border after centering finishes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            BorderManager.shared.updateBorder()
        }
    }
    
    func exit() {

        // Reset state (reset first to prevent re-entrancy)
        isActive = false
        focusedWindowID = nil
        activeScreen = nil
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
    
    // MARK: - Screen Detection

    /// Return the monitor the window belongs to
    /// Find the NSScreen containing the window's center point. Returns the primary monitor if none is found
    private func screenContaining(_ window: WindowInfo) -> NSScreen? {
        // The window's center point in the AX coordinate system
        let windowCenter = CGPoint(
            x: window.frame.midX,
            y: window.frame.midY
        )

        // Convert from the AX coordinate system to NSScreen's Cocoa coordinate system before deciding
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0

        for screen in NSScreen.screens {
            // Convert NSScreen's frame into the AX coordinate system
            let axFrame = CGRect(
                x: screen.frame.minX,
                y: mainScreenHeight - screen.frame.maxY,
                width: screen.frame.width,
                height: screen.frame.height
            )
            if axFrame.contains(windowCenter) {
                return screen
            }
        }

        // Return the primary monitor if none is found
        return NSScreen.screens.first
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

    private func hideOtherWindows(exceptWindowID: CGWindowID, on screen: NSScreen) {
        hiddenWindowFrames.removeAll()
        hiddenWindowList.removeAll()

        // Collect only the window IDs belonging to the workspace of the monitor that started Zen mode
        let workspaceIDs = Set(WorkspaceManager.shared.windowIDsForCurrentWorkspace(on: screen))

        // Determine the hidden corner
        let corner = optimalHideCorner(for: screen)

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

            // Skip windows outside the workspace of the monitor that started Zen mode
            // (don't touch windows on other monitors)
            if !workspaceIDs.contains(window.id) {
                continue
            }

            // Save the original position and WindowInfo (so restoring doesn't depend on getAllWindows)
            hiddenWindowFrames[window.id] = window.frame
            hiddenWindowList.append(window)

            // Move to the corner (position only, size unchanged)
            let hidePos = hidePosition(for: window, corner: corner, on: screen)
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
        guard let screen = screenContaining(focusedWindow) else { return }

        let step: CGFloat = 0.05
        widthRatio = max(0.1, min(1.0, widthRatio + (increase ? step : -step)))

        centerWindow(focusedWindow, on: screen)
    }
}
