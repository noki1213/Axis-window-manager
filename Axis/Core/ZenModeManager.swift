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

    /// The monitor Zen mode is active on (used so a workspace switch on another monitor doesn't cancel it)
    private(set) var activeMonitor: MonitorKey?

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

    /// Windows admitted while Zen mode is on, checked once all the changes of that moment are in
    private var admittedSinceCheck: Set<CGWindowID> = []

    private init() {}

    func toggle() {
        if isActive {
            exit()
        } else {
            enter()
        }
    }

    // MARK: - Windows coming and going

    /// A window was admitted. A tiled window joining the Zen workspace would be laid out under the
    /// centred window, so it ends Zen mode; floating windows and windows launched aside (which go
    /// to a workspace of their own) leave it on. Checked once the changes of that moment are all
    /// in, so a window that only took over from one with the same app and title does not count.
    func noteAdmitted(_ windowID: CGWindowID) {
        guard isActive else { return }
        if admittedSinceCheck.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.checkAdmittedWindows()
            }
        }
        admittedSinceCheck.insert(windowID)
    }

    /// The window took over from a closed one with the same app and title
    func noteRekeyed(to windowID: CGWindowID) {
        admittedSinceCheck.remove(windowID)
    }

    /// A window closed: losing the centred window or one Zen mode put out of sight ends it
    func noteRetired(_ windowID: CGWindowID) {
        guard isActive else { return }
        admittedSinceCheck.remove(windowID)
        let reason: ZenExitReason
        if windowID == focusedWindowID {
            reason = .focusClosed
        } else if hiddenWindowIDs.contains(windowID) {
            reason = .hiddenClosed
        } else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.exit(reason: reason)
        }
    }

    private func checkAdmittedWindows() {
        let admitted = admittedSinceCheck
        admittedSinceCheck.removeAll()
        let state = TrackingCoordinator.shared.state
        guard isActive, let monitor = activeMonitor, let zenWorkspace = state.activeWorkspace(monitor) else { return }
        let joined = admitted.contains { id in
            guard let record = state.record(id) else { return false }
            return record.placement == .tiled && record.workspace == zenWorkspace
        }
        if joined {
            exit(reason: .tiledAdmitted)
        }
    }

    /// Reset the state without restoring windows, and return every window's original position
    /// Used when switching directly to another mode, such as the palette
    func exitAndHandOffHiddenFrames() -> [CGWindowID: CGRect] {
        guard isActive else { return [:] }
        isActive = false
        admittedSinceCheck.removeAll()
        focusedWindowID = nil
        activeMonitor = nil
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
        activeMonitor = WorkspaceManager.shared.monitorKey(for: screen)
        isActive = true
        PerfLog.event("zen: enter \(PerfLog.describe(focusedWindow)) on \(PerfLog.describe(screen))")

        // Move only the other windows on the same monitor off-screen
        hideOtherWindows(exceptWindowID: focusedWindow.id, on: screen)

        // Also save the focused window's original position (before centering it)
        hiddenWindowFrames[focusedWindow.id] = focusedWindow.frame

        // Move the focused window to the center
        centerWindow(focusedWindow, on: screen)

        // Focus the window
        focusedWindow.focus()

        // Have the border smoothly grow to follow the window right from the start of a resize
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            BorderManager.shared.updateBorder()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            BorderManager.shared.updateBorder()
        }
    }
    
    func exit(reason: ZenExitReason = .user) {
        guard isActive else { return }
        PerfLog.event("zen: exit (\(reason.logText); was #\(focusedWindowID.map(String.init) ?? "-"))")

        // Reset state (reset first to prevent re-entrancy)
        isActive = false
        admittedSinceCheck.removeAll()
        focusedWindowID = nil
        activeMonitor = nil
        widthRatio = 0.75
        
        // Move a window that ended up off-screen back to its original position
        restoreHiddenWindows()
        
        // Retile and update the border after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            TilingEngine.shared.tileAllScreens()
            BorderManager.shared.updateBorder()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            BorderManager.shared.updateBorder()
        }
    }
    
    // MARK: - Screen Detection

    /// Return the monitor the window belongs to
    /// Find the NSScreen containing the window's center point. Returns the primary monitor if none is found
    private func screenContaining(_ window: WindowInfo) -> NSScreen? {
        window.screen ?? NSScreen.screens.first
    }

    // MARK: - Hide Corner (the AeroSpace approach)

    /// The corner used to hide a window
    private func optimalHideCorner(for screen: NSScreen) -> HideCorner {
        HideCorner.best(for: screen)
    }

    private func hidePosition(for window: WindowInfo, corner: HideCorner, on screen: NSScreen) -> CGPoint {
        corner.position(forWindowWidth: window.frame.width, on: screen)
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

        // Immediately start a slide animation of the border toward the large central frame (a springy expand)
        BorderManager.shared.updateBorder(withExplicitTarget: targetFrame)

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
