//
//  FocusModeManager.swift
//  Axis
//
//  Created on 2026/01/29.
//

import AppKit
import Combine

/// Focus Mode: show the focused window centered
class FocusModeManager: ObservableObject {
    static let shared = FocusModeManager()

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
            print("[Axis] FocusMode: No focused window")
            return
        }
        
        guard let screen = NSScreen.main else {
            print("[Axis] FocusMode: No screen")
            return
        }
        
        print("[Axis] FocusMode: Entering with window '\(focusedWindow.title)'")
        
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
        print("[Axis] FocusMode: Exiting, will restore \(hiddenWindowFrames.count) windows")
        
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
    
    private func hideOtherWindows(exceptWindowID: CGWindowID, on targetScreen: NSScreen) {
        hiddenWindowFrames.removeAll()
        
        // Get all windows
        let allWindows = AccessibilityManager.shared.getAllWindows()
        
        // The target screen's frame (converted to AX coordinates)
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        
        for window in allWindows {
            // Skip the focused window
            if window.id == exceptWindowID {
                continue
            }
            
            // Skip minimized windows
            if window.isMinimized {
                continue
            }
            
            // Calculate the window's center point (AX coordinate system)
            let windowCenterX = window.frame.midX
            let windowCenterY = window.frame.midY
            
            // Convert from AX coordinates to NS coordinates to determine the screen
            let windowCenterNS = CGPoint(x: windowCenterX, y: mainScreenHeight - windowCenterY)
            
            // Skip windows that aren't on the target screen
            if !targetScreen.frame.contains(windowCenterNS) {
                continue
            }
            
            // Save the original position
            hiddenWindowFrames[window.id] = window.frame
            
            // Move off-screen (a large offset to the right)
            let offscreenX: CGFloat = 10000
            let newFrame = CGRect(x: offscreenX, y: window.frame.origin.y, 
                                  width: window.frame.width, height: window.frame.height)
            window.setFrame(newFrame)
            
            print("[Axis] FocusMode: Moved window '\(window.title)' offscreen")
        }
        
        print("[Axis] FocusMode: Hidden \(hiddenWindowFrames.count) windows on current screen")
    }
    
    private func restoreHiddenWindows() {
        // Get all windows
        let allWindows = AccessibilityManager.shared.getAllWindows()
        
        for window in allWindows {
            // Restore the saved frame if there is one
            if let originalFrame = hiddenWindowFrames[window.id] {
                window.setFrame(originalFrame)
                print("[Axis] FocusMode: Restored window '\(window.title)' to \(originalFrame)")
            }
        }
        
        print("[Axis] FocusMode: Restored \(hiddenWindowFrames.count) windows")
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
        
        print("[Axis] FocusMode: Moving window to \(targetFrame)")
        window.setFrame(targetFrame)
    }
}
