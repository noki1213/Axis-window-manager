

//
//  AppDelegate.swift
//  Axis
//
//  Created on 2026/01/27.
//

import AppKit
import SwiftUI

/// Manages the application's lifecycle
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    
    private let accessibilityManager = AccessibilityManager.shared
    private let hotkeyManager = HotkeyManager.shared
    private let tilingEngine = TilingEngine.shared
    private let borderManager = BorderManager.shared
    private let workspaceManager = WorkspaceManager.shared
    
    // For detecting window changes
    private var windowCheckTimer: Timer?
    private var lastWindowCount: Int = 0
    private var lastWindowIDs: Set<CGWindowID> = []

    // For detecting Space switches
    private var isSpaceSwitching = false

    // For detecting monitor changes
    private var knownScreenIDs: Set<ScreenIdentifier> = []
    private var isHandlingScreenChange = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Configure it as a menu bar app (hide the Dock icon)
        NSApp.setActivationPolicy(.accessory)
        
        // Create the status bar item
        setupStatusItem()
        
        // Check the Accessibility permission
        if !accessibilityManager.checkAccessibility() {
            showAccessibilityAlert()
        } else {
            startWindowManagement()
        }
        
        // Watch for the permission-granted notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onAccessibilityPermissionGranted),
            name: .accessibilityPermissionGranted,
            object: nil
        )
        
        // Watch for mode-change notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onModeChanged),
            name: .modeChanged,
            object: nil
        )

        // Watch for workspace-change notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onWorkspaceChanged),
            name: .workspaceChanged,
            object: nil
        )
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.stop()
        windowCheckTimer?.invalidate()
    }
    
    // MARK: - Status Bar
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            updateStatusItemIcon(mode: .normal)
            button.action = #selector(statusItemClicked)
            button.target = self
        }
        
        // Set up the menu
        let menu = NSMenu()
        
        // Tile Windows: Ctrl+Option+T
        let tileItem = NSMenuItem(title: "Tile Windows", action: #selector(tileWindows), keyEquivalent: "t")
        tileItem.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(tileItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Settings: Ctrl+Option+,
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit: Ctrl+Option+Q
        let quitItem = NSMenuItem(title: "Quit Axis", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
    }
    
    private func updateStatusItemIcon(mode: HotkeyManager.Mode) {
        guard let button = statusItem?.button else { return }
        
        let iconName: String
        switch mode {
        case .normal:
            iconName = "rectangle.split.3x1" // 通常のタイリングアイコン
        case .windowSelect:
            iconName = "rectangle.stack" // ウィンドウ選択
        case .gapSelect:
            iconName = "arrow.left.and.right" // ギャップ選択
        case .windowPalette:
            iconName = "rectangle.grid.2x2" // ウィンドウパレット
        }
        
        button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: mode.rawValue)
    }
    
    // MARK: - Actions
    
    @objc private func statusItemClicked() {
        // The right-click menu is shown by default
    }
    
    @objc private func tileWindows() {
        tilingEngine.tileAllScreens()
    }
    
    @objc private func openSettings() {
        // Open the settings screen (to be implemented later)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func quitApp() {
        // Bring all off-screen windows back on-screen before quitting
        restoreAllWindowsBeforeQuit()
        NSApp.terminate(nil)
    }

    // MARK: - Window restoration on quit

    /// Before Axis quits, bring every window that was moved off-screen back on screen
    private func restoreAllWindowsBeforeQuit() {
        let allWindows = accessibilityManager.getAllWindows()

        // 1. Restore windows hidden by ZenMode
        if ZenModeManager.shared.isActive {
            let hiddenFrames = ZenModeManager.shared.exitAndHandOffHiddenFrames()
            for window in allWindows {
                if let frame = hiddenFrames[window.id] {
                    window.setFrame(frame)
                }
            }
            print("[Axis] 終了処理: ZenMode のウィンドウを復元")
        }

        // 2. Restore windows hidden by the window palette
        if hotkeyManager.currentMode == .windowPalette {
            WindowPaletteManager.shared.endPalette()
            print("[Axis] 終了処理: ウィンドウパレットのウィンドウを復元")
        }

        // 3. Restore windows hidden by the workspace
        workspaceManager.restoreAllHiddenWindows()

        // 4. Safety net: move any windows still off-screen back on-screen
        rescueOffScreenWindows()
    }

    /// Move an off-screen window into the bounds of the nearest screen
    private func rescueOffScreenWindows() {
        let allWindows = accessibilityManager.getAllWindows()
        guard let mainScreenHeight = NSScreen.screens.first?.frame.height else { return }

        var rescuedCount = 0

        for window in allWindows {
            // Skip minimized or fullscreen windows
            guard !window.isMinimized && !window.isFullscreen else { continue }
            // Skip windows with zero size
            guard window.frame.width > 0 && window.frame.height > 0 else { continue }

            // Convert the window's center point to NSScreen coordinates (bottom-left origin)
            let centerX = window.frame.midX
            let centerY = mainScreenHeight - window.frame.midY
            let centerInNS = CGPoint(x: centerX, y: centerY)

            // Check whether it's contained in any screen
            let isOnScreen = NSScreen.screens.contains { $0.frame.contains(centerInNS) }

            if !isOnScreen {
                // Find the nearest screen
                guard let targetScreen = closestScreen(to: centerInNS) else { continue }
                let visibleFrame = targetScreen.visibleFrame

                // Compute visibleFrame's bounds in the AX coordinate system
                let screenTopInAX = mainScreenHeight - (visibleFrame.minY + visibleFrame.height)
                let screenBottomInAX = mainScreenHeight - visibleFrame.minY

                // Keep the window's position within visibleFrame
                var newX = window.frame.origin.x
                var newY = window.frame.origin.y

                // Adjustment along the X axis
                if newX + window.frame.width <= visibleFrame.minX {
                    newX = visibleFrame.minX
                } else if newX >= visibleFrame.maxX {
                    newX = visibleFrame.maxX - window.frame.width
                }

                // Adjustment along the Y axis (AX coordinate system: smaller values are toward the top)
                if newY + window.frame.height <= screenTopInAX {
                    newY = screenTopInAX
                } else if newY >= screenBottomInAX {
                    newY = screenBottomInAX - window.frame.height
                }

                window.setPosition(CGPoint(x: newX, y: newY))
                rescuedCount += 1
            }
        }

        if rescuedCount > 0 {
            print("[Axis] 終了処理: \(rescuedCount) 個の画面外ウィンドウを画面内に移動")
        }
    }

    /// Return the screen nearest to the given coordinates (NSScreen coordinate system)
    private func closestScreen(to point: CGPoint) -> NSScreen? {
        return NSScreen.screens.min(by: { screen1, screen2 in
            let center1 = CGPoint(x: screen1.frame.midX, y: screen1.frame.midY)
            let center2 = CGPoint(x: screen2.frame.midX, y: screen2.frame.midY)
            let dist1 = hypot(point.x - center1.x, point.y - center1.y)
            let dist2 = hypot(point.x - center2.x, point.y - center2.y)
            return dist1 < dist2
        })
    }
    
    // MARK: - Accessibility
    
    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "Axis needs Accessibility permission to manage windows. Click 'Open System Settings' to grant permission."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")
        alert.alertStyle = .warning
        
        NSApp.activate(ignoringOtherApps: true)
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            accessibilityManager.requestAccessibility()
        } else {
            NSApp.terminate(nil)
        }
    }
    
    @objc private func onAccessibilityPermissionGranted() {
        DispatchQueue.main.async { [weak self] in
            self?.startWindowManagement()
        }
    }
    
    private func startWindowManagement() {
        // Start hotkey monitoring
        hotkeyManager.start()

        // Record the current monitor list (for detecting monitor connect/disconnect)
        knownScreenIDs = Set(NSScreen.screens.map { ScreenIdentifier(from: $0) })

        // Initialize the workspace (register all windows to workspace 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.workspaceManager.initializeWithCurrentWindows()
        }

        // Run the initial tiling
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.tilingEngine.tileAllScreens()
            self?.borderManager.updateBorder()
        }

        // Watch for window changes
        setupWindowObservers()
    }
    
    private func setupWindowObservers() {
        // Watch for workspace notifications
        let workspace = NSWorkspace.shared
        
        // Watch for app launches
        workspace.notificationCenter.addObserver(
            self,
            selector: #selector(onAppLaunched),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        
        // Watch for app terminations
        workspace.notificationCenter.addObserver(
            self,
            selector: #selector(onAppTerminated),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        
        // Watch for active-app changes
        workspace.notificationCenter.addObserver(
            self,
            selector: #selector(onActiveAppChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        
        // Watch for Space switches
        workspace.notificationCenter.addObserver(
            self,
            selector: #selector(onActiveSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        // Watch for monitor connect/disconnect
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // Periodically check for window-count changes (detects new and closed windows)
        // Target only on-screen windows
        let onScreenIDs = accessibilityManager.getOnScreenWindowIDs()
        let allWindows = accessibilityManager.getAllWindows()
        let onScreenWindows = allWindows.filter { onScreenIDs.contains($0.id) }
        lastWindowCount = onScreenWindows.count
        lastWindowIDs = Set(onScreenWindows.map { $0.id })
        windowCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkForWindowChanges()
        }
    }
    
    private func checkForWindowChanges() {
        // Skip processing while a Space switch or workspace switch is in progress
        guard !isSpaceSwitching && !workspaceManager.isSwitching else {
            print("[Axis] Skipping window check during switching")
            return
        }

        // Skip automatic tiling while Zen mode is active (guards against input-source switches like the eisu key)
        guard !ZenModeManager.shared.isActive else {
            return
        }

        // Target only on-screen windows (i.e. windows in the current Space)
        let onScreenIDs = accessibilityManager.getOnScreenWindowIDs()
        let allWindows = accessibilityManager.getAllWindows()
        let currentWindows = allWindows.filter { onScreenIDs.contains($0.id) }
        let currentCount = currentWindows.count
        let currentWindowIDs = Set(currentWindows.map { $0.id })

        if currentCount != lastWindowCount {
            print("[Axis] Window count changed: \(lastWindowCount) -> \(currentCount)")

            // When a window was closed
            if currentCount < lastWindowCount {
                let closedWindowIDs = lastWindowIDs.subtracting(currentWindowIDs)
                print("[Axis] Windows closed: \(closedWindowIDs)")

                // Also unregister from the workspace
                for closedID in closedWindowIDs {
                    workspaceManager.unregisterWindow(closedID)
                }

                focusAdjacentWindowAfterClose()
            }

            // When a window was added
            if currentCount > lastWindowCount {
                let newWindowIDs = currentWindowIDs.subtracting(lastWindowIDs)
                print("[Axis] New windows: \(newWindowIDs)")

                // Register the new window to the current workspace
                for newID in newWindowIDs {
                    // Skip if it's already registered in some workspace
                    // (avoids mistakenly registering a window from another workspace right after a workspace switch)
                    if workspaceManager.isWindowInAnyWorkspace(newID) {
                        print("[Axis] Window \(newID) already in a workspace, skipping registration")
                        continue
                    }

                    if let window = currentWindows.first(where: { $0.id == newID }) {
                        // Determine which screen a window belongs to
                        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
                        let centerX = window.frame.midX
                        let centerY = mainScreenHeight - window.frame.midY
                        let center = CGPoint(x: centerX, y: centerY)

                        for screen in NSScreen.screens {
                            if screen.frame.contains(center) {
                                workspaceManager.registerWindow(newID, on: screen)
                                break
                            }
                        }
                    }
                }

                focusNewWindow(newWindowIDs: newWindowIDs, allWindows: currentWindows)
            }

            lastWindowCount = currentCount
            lastWindowIDs = currentWindowIDs
            tilingEngine.tileAllScreens()

            // Update the border after tiling
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.borderManager.updateBorder()
            }
        }
    }
    
    /// Move focus to the newly added window
    private func focusNewWindow(newWindowIDs: Set<CGWindowID>, allWindows: [WindowInfo]) {
        // Find and focus the new window
        for window in allWindows {
            if newWindowIDs.contains(window.id) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    window.focus()
                    print("[Axis] Focused new window: \(window.title)")
                }
                return
            }
        }
    }

    /// After a window closes, move focus to the window under the mouse cursor
    private func focusAdjacentWindowAfterClose() {
        // Move focus after a short delay (waiting for tiling to finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }

            // Get the current mouse position
            let mouseLocation = NSEvent.mouseLocation
            
            // Find the window at the mouse position
            if let windowUnderMouse = self.accessibilityManager.getWindowAt(mouseLocation) {
                print("[Axis] Focusing window under mouse: \(windowUnderMouse.title)")
                windowUnderMouse.focus()
                return
            }

            // Only fall back to the top-left when there's no window under the mouse and nothing currently has focus
            if self.accessibilityManager.getFocusedWindow() == nil {
                // Focus the first of the tiled windows
                for screen in NSScreen.screens {
                    if let columns = self.tilingEngine.tiledWindows[screen],
                       let firstColumn = columns.first,
                       let firstWindow = firstColumn.first {
                        firstWindow.focus()
                        print("[Axis] Focused first available window (fallback): \(firstWindow.title)")
                        return
                    }
                }
            }
        }
    }
    
    @objc private func onAppLaunched(_ notification: Notification) {
        // Skip automatic tiling while Zen mode is active
        guard !ZenModeManager.shared.isActive else { return }

        // Retile when a new app launches
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard !ZenModeManager.shared.isActive else { return }
            self?.tilingEngine.tileAllScreens()
        }
    }

    @objc private func onAppTerminated(_ notification: Notification) {
        // Skip automatic tiling while Zen mode is active
        guard !ZenModeManager.shared.isActive else { return }

        // Retile when an app quits
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard !ZenModeManager.shared.isActive else { return }
            self?.tilingEngine.tileAllScreens()
        }
    }
    
    @objc private func onActiveAppChanged(_ notification: Notification) {
        // Handling for when the active app changes (as needed)
    }
    
    @objc private func onActiveSpaceChanged(_ notification: Notification) {
        print("[Axis] Active space changed")

        // Set the Space-switching flag
        isSpaceSwitching = true

        // Update the current Space's window info after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }

            // Update lastWindowIDs with the current Space's on-screen windows
            let onScreenIDs = self.accessibilityManager.getOnScreenWindowIDs()
            let allWindows = self.accessibilityManager.getAllWindows()
            let onScreenWindows = allWindows.filter { onScreenIDs.contains($0.id) }
            self.lastWindowCount = onScreenWindows.count
            self.lastWindowIDs = Set(onScreenWindows.map { $0.id })

            // Reinitialize the workspace's window registrations
            // (The window set may change during a macOS Space switch)
            self.workspaceManager.initializeWithCurrentWindows()

            // Reapply tiling
            self.tilingEngine.tileAllScreens()

            // Update the border
            self.borderManager.updateBorder()

            // Clear the flag
            self.isSpaceSwitching = false
            print("[Axis] Space switch completed, tracking \(self.lastWindowCount) windows")
        }
    }
    
    @objc private func onModeChanged(_ notification: Notification) {
        if let mode = notification.object as? HotkeyManager.Mode {
            DispatchQueue.main.async { [weak self] in
                self?.updateStatusItemIcon(mode: mode)
            }
        }
    }

    @objc private func onWorkspaceChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.updateWorkspaceDisplay()
        }

        // Update window tracking after a workspace switch
        // (delayed slightly to wait for the position change to take effect)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            let onScreenIDs = self.accessibilityManager.getOnScreenWindowIDs()
            let allWindows = self.accessibilityManager.getAllWindows()
            let onScreenWindows = allWindows.filter { onScreenIDs.contains($0.id) }
            self.lastWindowCount = onScreenWindows.count
            self.lastWindowIDs = Set(onScreenWindows.map { $0.id })
            print("[Axis] Workspace changed, tracking \(self.lastWindowCount) windows")
        }
    }

    // MARK: - Monitor change handling

    @objc private func onScreenParametersChanged() {
        // Debounce rapid successive notifications (this can fire multiple times on monitor changes)
        guard !isHandlingScreenChange else { return }
        isHandlingScreenChange = true

        // Wait for macOS to fully update the monitor info before proceeding
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.processScreenChange()

            // Cooldown period (to guard against rapid successive changes)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.isHandlingScreenChange = false
            }
        }
    }

    private func processScreenChange() {
        let currentScreenIDs = Set(NSScreen.screens.map { ScreenIdentifier(from: $0) })

        let removedScreenIDs = knownScreenIDs.subtracting(currentScreenIDs)
        let addedScreenIDs = currentScreenIDs.subtracting(knownScreenIDs)

        // If the monitor count hasn't changed, just retile (a resolution or arrangement change only)
        guard !removedScreenIDs.isEmpty || !addedScreenIDs.isEmpty else {
            knownScreenIDs = currentScreenIDs
            tilingEngine.tileAllScreens()
            return
        }

        // Handling for a disconnected monitor
        for removedID in removedScreenIDs {
            print("[Axis] モニター切断を検知: displayID=\(removedID.displayID)")
            workspaceManager.handleScreenDisconnected(removedScreenID: removedID)
        }

        // Handling for a connected monitor
        for addedID in addedScreenIDs {
            if let newScreen = NSScreen.screens.first(where: {
                ScreenIdentifier(from: $0) == addedID
            }) {
                print("[Axis] モニター接続を検知: displayID=\(addedID.displayID)")
                workspaceManager.handleScreenConnected(newScreen: newScreen)
            }
        }

        // Refresh the monitor list
        knownScreenIDs = currentScreenIDs

        // Update window tracking
        let onScreenIDs = accessibilityManager.getOnScreenWindowIDs()
        let allWindows = accessibilityManager.getAllWindows()
        let onScreenWindows = allWindows.filter { onScreenIDs.contains($0.id) }
        lastWindowCount = onScreenWindows.count
        lastWindowIDs = Set(onScreenWindows.map { $0.id })

        print("[Axis] モニター構成が変更されました: \(NSScreen.screens.count) 台")
    }

    /// Show the workspace number in the menu bar
    private func updateWorkspaceDisplay() {
        guard let button = statusItem?.button else { return }
        let ws = workspaceManager.currentWorkspaceForFocusedScreen()
        button.title = " \(ws)"
    }
}
