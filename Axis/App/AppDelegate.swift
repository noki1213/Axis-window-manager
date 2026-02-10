

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
    private var wasScreenLocked = false
    private var isWaking = false

    // For detecting Space switches
    private var isSpaceSwitching = false

    // For detecting monitor changes
    private var knownScreenIDs: Set<ScreenIdentifier> = []
    private var isHandlingScreenChange = false

    // The startup guide window
    private var startupGuideController: StartupGuideWindowController?

    // The settings window
    private var settingsWindow: NSWindow?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Configure it as a menu bar app (hide the Dock icon)
        NSApp.setActivationPolicy(.accessory)
        
        // Create the status bar item
        setupStatusItem()
        
        // Check the Accessibility permission
        if !accessibilityManager.checkAccessibility() {
            showAccessibilityAlert()
        } else {
            showStartupGuide()
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

        // Watch for screen lock/unlock notifications
        let dist = DistributedNotificationCenter.default()
        dist.addObserver(
            self,
            selector: #selector(onScreenLocked),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        dist.addObserver(
            self,
            selector: #selector(onScreenUnlocked),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Save workspace state to a file before quitting
        workspaceManager.saveStateToDisk()

        // Bring every off-screen window back on screen
        restoreAllWindowsBeforeQuit()
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
        // Bring it to the front if the window is already open
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create the NSWindow that hosts the settings screen
        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Axis Settings"
        window.styleMask = [.titled, .closable]
        window.center()
        window.isReleasedWhenClosed = false

        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func quitApp() {
        // Runs the window-restore logic from applicationWillTerminate
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
            self?.showStartupGuide()
        }
    }

    /// Show the startup guide, and begin window management once the user signals they're ready
    private func showStartupGuide() {
        startupGuideController = StartupGuideWindowController()
        startupGuideController?.show { [weak self] in
            self?.startupGuideController = nil
            self?.startWindowManagement()
        }
    }

    private func startWindowManagement() {
        // Start hotkey monitoring
        hotkeyManager.start()

        // Record the current monitor list (for detecting monitor connect/disconnect)
        knownScreenIDs = Set(NSScreen.screens.map { ScreenIdentifier(from: $0) })

        // Rescue off-screen windows right after launch (a fallback for when the previous quit couldn't restore them)
        rescueOffScreenWindows()

        // Initialize the workspace (restore from saved data if present, otherwise initialize fresh)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            let restored = self.workspaceManager.restoreStateFromDisk()
            if !restored {
                // If there's no saved data, do the normal initialization (register all windows to workspace 0)
                self.workspaceManager.initializeWithCurrentWindows()
            }
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

        // Save workspace state before sleep
        workspace.notificationCenter.addObserver(
            self,
            selector: #selector(onSystemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        // Watch for wake from sleep (to rescue windows left off-screen)
        workspace.notificationCenter.addObserver(
            self,
            selector: #selector(onSystemWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        // Periodically check for window-count changes (detects new and closed windows)
        // Target only on-screen windows
        let onScreenIDs = accessibilityManager.getOnScreenWindowIDs()
        let allWindows = accessibilityManager.getAllWindows()
        let onScreenWindows = allWindows.filter { onScreenIDs.contains($0.id) }
        lastWindowCount = onScreenWindows.count
        lastWindowIDs = Set(onScreenWindows.map { $0.id })
        windowCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.checkForWindowChanges()
        }
    }
    
    private func checkForWindowChanges() {
        // Skip while a Space switch, workspace switch, monitor-change handling, or wake-from-sleep is in progress
        guard !isSpaceSwitching && !workspaceManager.isSwitching && !isHandlingScreenChange && !isWaking else {
            print("[Axis] Skipping window check during switching")
            return
        }

        // Skip automatic tiling while Zen mode is active (guards against input-source switches like the eisu key)
        guard !ZenModeManager.shared.isActive else {
            return
        }

        // Skip everything while the lock screen (loginwindow) is frontmost
        // because the Accessibility API becomes unusable while locked, making windows appear to have vanished
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow" {
            print("[Axis] loginwindow active; skipping all window checks")
            return
        }

        // Also skip while the screen is locked
        if wasScreenLocked {
            print("[Axis] Screen locked; skipping window check")
            return
        }

        // Target only on-screen windows (i.e. windows in the current Space)
        let onScreenIDs = accessibilityManager.getOnScreenWindowIDs()
        let allWindows = accessibilityManager.getAllWindows()
        let currentWindows = allWindows.filter { onScreenIDs.contains($0.id) }
        let currentCount = currentWindows.count

        // Watchdog: even though no window is registered to the workspace,
        // If the window is visibly on screen, the state is broken, so restore it
        if currentCount > 0 {
            let hasRegisteredWindows = NSScreen.screens.contains { screen in
                let ids = workspaceManager.windowIDsForCurrentWorkspace(on: screen)
                return !ids.isEmpty
            }
            if !hasRegisteredWindows {
                // First try restoring from closedWindowsCache
                var restoredFromCache = false
                for window in currentWindows {
                    if workspaceManager.restoreFromCacheIfNeeded(detectedWindowID: window.id) {
                        restoredFromCache = true
                        print("[Axis] ウォッチドッグ: closedWindowsCache から復元成功")
                        break
                    }
                }

                if !restoredFromCache {
                    // Reinitialize if restoring from the cache fails
                    print("[Axis] ウォッチドッグ: キャッシュなし、強制再初期化（画面上に\(currentCount)個のウィンドウ）")
                    workspaceManager.forceReinitialize()
                }

                lastWindowCount = currentCount
                lastWindowIDs = Set(currentWindows.map { $0.id })
                tilingEngine.tileAllScreens()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.borderManager.updateBorder()
                }
                return
            }
        }
        let currentWindowIDs = Set(currentWindows.map { $0.id })

        if currentCount != lastWindowCount {
            print("[Axis] Window count changed: \(lastWindowCount) -> \(currentCount)")

            // When a window was closed
            if currentCount < lastWindowCount {
                let closedWindowIDs = lastWindowIDs.subtracting(currentWindowIDs)
                print("[Axis] Windows closed: \(closedWindowIDs)")

                // If every window disappears at once, that's a sign of the lock screen or sleep
                // Save the cache and wait, without unregistering the window
                // (the lock notification can arrive later than checkForWindowChanges)
                if currentCount == 0 && lastWindowCount > 1 {
                    workspaceManager.cacheCurrentStateOnWindowClose()
                    lastWindowCount = 0
                    lastWindowIDs = []
                    print("[Axis] 全ウィンドウが消失 → ロック/スリープの可能性があるため unregister をスキップ")
                    return
                }

                // Save the cache before unregistering, so we can restore later
                workspaceManager.cacheCurrentStateOnWindowClose()

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

                // Try to restore from the cache
                // Restore a vanished window if it comes back after unlock or wake from sleep
                var restoredFromCache = false
                for newID in newWindowIDs {
                    if workspaceManager.restoreFromCacheIfNeeded(detectedWindowID: newID) {
                        restoredFromCache = true
                        print("[Axis] Restored workspace state from closedWindowsCache")
                        break
                    }
                }

                if restoredFromCache {
                    // If restored from cache, reapply tiling and finish
                    lastWindowCount = currentCount
                    lastWindowIDs = currentWindowIDs
                    tilingEngine.tileAllScreens()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.borderManager.updateBorder()
                    }
                    return
                }

                // The normal new-window registration path
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

            // Update the border and save state after tiling
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.borderManager.updateBorder()
            }

            // Save state whenever a window change occurs
            // (don't rely solely on the save-on-shutdown path)
            workspaceManager.saveStateToDisk()
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
                    if let columns = self.tilingEngine.tiledWindows[ScreenIdentifier(from: screen)],
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
        // Skip while monitor-change handling is in progress
        // (a Space-switch notification also arrives on monitor connect/disconnect, but that's handled by processScreenChange)
        guard !isHandlingScreenChange else {
            print("[Axis] Skipping space change during screen change handling")
            return
        }

        // Also skip when the monitor configuration has changed but processScreenChange hasn't run yet
        // (macOS can send the Space-switch notification before the monitor-change one)
        let currentScreenIDs = Set(NSScreen.screens.map { ScreenIdentifier(from: $0) })
        if currentScreenIDs != knownScreenIDs {
            print("[Axis] Skipping space change due to pending screen configuration change")
            return
        }

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

    // MARK: - Screen lock handling

    @objc private func onScreenLocked() {
        wasScreenLocked = true
        print("[Axis] 画面ロックを検知")
    }

    @objc private func onScreenUnlocked() {
        wasScreenLocked = false
        print("[Axis] 画面ロック解除を検知")

        // If unlocked after waking from sleep, run the recovery logic here
        if isWaking {
            print("[Axis] ロック解除を検知 → スリープ復帰処理を開始")
            performWakeRecovery()
        }
    }

    // MARK: - Sleep/wake handling

    @objc private func onSystemWillSleep() {
        print("[Axis] システムがスリープに入ります")
        // Set a flag so window checks don't run during sleep
        isWaking = true
        // Save workspace state before sleep
        workspaceManager.saveStateToDisk()
    }

    @objc private func onSystemWake() {
        print("[Axis] システムがスリープから復帰")

        // If the screen is locked, wait for it to unlock before running the recovery logic
        // (the Accessibility API is unavailable while locked)
        // Check not just the wasScreenLocked flag but also whether loginwindow is frontmost
        // (because on wake from sleep, the ScreenLocked notification doesn't always arrive first)
        let isLoginWindow = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow"

        if wasScreenLocked || isLoginWindow {
            wasScreenLocked = true
            print("[Axis] 画面ロック中のため、ロック解除を待ちます")
            // Keep isWaking true → onScreenUnlocked will run the wake-recovery logic
            return
        }

        // If the screen isn't locked, go ahead and run the recovery logic
        performWakeRecovery()
    }

    /// The actual recovery logic run after waking from sleep
    /// Guarantee this is called only after the screen lock is released
    private func performWakeRecovery() {
        // Wait for the screen info to stabilize
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }

            // If the screen is still locked, wait a bit longer
            // (a safety net for when this is called almost simultaneously with unlock)
            if self.wasScreenLocked {
                print("[Axis] まだ画面ロック中、さらに待機します")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.executeWakeRecovery()
                }
                return
            }

            self.executeWakeRecovery()
        }
    }

    /// The main body of the recovery logic
    private func executeWakeRecovery() {
        // The window ID may have changed, so re-match it
        // (don't call rescueOffScreenWindows here — it would break intentionally hidden windows)
        workspaceManager.rematchWindowIDsAfterWake()

        // Retile the current workspace after recovery
        tilingEngine.tileAllScreens()
        borderManager.updateBorder()

        // Update the window tracking info (based on the correct post-recovery state)
        let onScreenIDs = accessibilityManager.getOnScreenWindowIDs()
        let allWindows = accessibilityManager.getAllWindows()
        let onScreenWindows = allWindows.filter { onScreenIDs.contains($0.id) }
        lastWindowCount = onScreenWindows.count
        lastWindowIDs = Set(onScreenWindows.map { $0.id })

        // Resume window checking
        isWaking = false
        print("[Axis] スリープ復帰処理完了、ウィンドウ追跡を再開（\(lastWindowCount) 個のウィンドウ）")
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

        // Refresh the monitor list
        knownScreenIDs = currentScreenIDs

        // Remove data keyed by the old NSScreen and retile across all screens
        // (macOS rebuilds NSScreen objects when the monitor configuration changes)
        tilingEngine.cleanupDisconnectedScreens()
        tilingEngine.tileAllScreens()
        borderManager.updateBorder()

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
