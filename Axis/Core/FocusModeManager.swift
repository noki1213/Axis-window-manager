//
//  FocusModeManager.swift
//  Axis
//
//  Created on 2026/01/29.
//

import AppKit
import Combine

/// Focus Mode: show the focused window centered and dim the background
class FocusModeManager: ObservableObject {
    static let shared = FocusModeManager()

    @Published var isActive: Bool = false
    
    private var overlayWindow: NSWindow?
    private var focusedWindowID: CGWindowID?
    private var originalFrame: CGRect?

    private init() {}

    func toggle() {
        if isActive {
            exit()
        } else {
            enter()
        }
    }
    
    private func enter() {
        guard let window = AccessibilityManager.shared.getFocusedWindow() else {
            print("[Axis] FocusMode: No focused window")
            return
        }
        
        guard let screen = NSScreen.main else {
            print("[Axis] FocusMode: No screen")
            return
        }
        
        print("[Axis] FocusMode: Entering with window '\(window.title)'")
        
        // Save the state
        focusedWindowID = window.id
        originalFrame = window.frame
        isActive = true
        
        // Hide the border
        BorderManager.shared.hideBorder()
        
        // Show the overlay
        showOverlay(on: screen)
        
        // Move the window to the center
        centerWindow(window, on: screen)
        
        // Focus the window
        window.focus()
    }
    
    private func exit() {
        print("[Axis] FocusMode: Exiting")
        
        // Remove the overlay (use orderOut() rather than close())
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        
        // Reset the state
        isActive = false
        focusedWindowID = nil
        originalFrame = nil
        
        // Retiling puts it back in its original position
        TilingEngine.shared.tileAllScreens()
        
        // Update the border
        BorderManager.shared.updateBorder()
    }
    
    private func showOverlay(on screen: NSScreen) {
        let overlay = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        overlay.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        overlay.isOpaque = false
        overlay.hasShadow = false
        overlay.level = .normal
        overlay.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        overlay.ignoresMouseEvents = true
        
        overlay.orderFront(nil)
        overlayWindow = overlay
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
