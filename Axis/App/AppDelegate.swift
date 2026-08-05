

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
    private var lastOnScreenIDSignature: Set<CGWindowID> = []
    /// The number of consecutive times a full AX scan was skipped because the window set hadn't changed
    private var consecutiveScanSkips: Int = 0
    /// The cap on consecutive skips of the full scan (at a 0.3s interval, this guarantees a full scan roughly once every 3 seconds)
    private static let maxConsecutiveScanSkips = 10
    /// The number of consecutive times it was skipped as a presumed transient miss
    private var consecutiveGhostSkips: Int = 0
    /// The cap on consecutive skips (about 1.5 seconds; beyond this it's treated as genuinely closed)
    private static let maxConsecutiveGhostSkips = 5
    /// The monitor of the window that had focus on the previous timer cycle
    /// Used to determine the monitor when registering a new window (since focus has already moved to the new window by the time it's detected)
    private var lastFocusedScreen: NSScreen?
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
        }

        // 2. Restore windows hidden by the window palette
        if hotkeyManager.currentMode == .windowPalette {
            WindowPaletteManager.shared.endPalette()
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

        // Start watching for Focus Follows Mouse (auto-focus the window under the cursor)
        FocusFollowsMouseManager.shared.start()
        // A startup marker to confirm the measurement logging is running
        PerfLog.log("=== Axis 起動 / FFM有効=\(FocusFollowsMouseManager.shared.isEnabled) ===")

        // Record the current monitor list (for detecting monitor connect/disconnect)
        knownScreenIDs = Set(NSScreen.screens.map { ScreenIdentifier(from: $0) })

        // Rescue off-screen windows right after launch (a fallback for when the previous quit couldn't restore them)
        rescueOffScreenWindows()

        // Initialize workspaces (respecting windows' current positions, registering them to workspace 0 on each monitor)
        // Don't use the saved data's monitor assignment (it would move the window to a different monitor)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            self.workspaceManager.initializeWithCurrentWindows()
        }

        // Run the initial tiling
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.tilingEngine.tileAllScreens()
            self.borderManager.updateBorder()
        }

        // Focus the first window right after launch
        // (runs with a short delay after tiling finishes)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self = self else { return }
            // Prefer the main screen, otherwise search the other screens
            let screens = [NSScreen.main].compactMap { $0 } + NSScreen.screens.filter { $0 != NSScreen.main }
            for screen in screens {
                let screenID = ScreenIdentifier(from: screen)
                if let columns = self.tilingEngine.tiledWindows[screenID],
                   let firstWindow = columns.compactMap({ $0.first }).first {
                    firstWindow.focus()
                    break
                }
            }
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
        // While a Space switch, workspace switch, monitor-change handling, or wake from sleep is in progress,
        // Skip while Mission Control is showing
        // (during Mission Control, getOnScreenWindowIDs() becomes unreliable, causing false-positive close detection and
        //   because the watchdog's tileAllScreens() would move real windows while Mission Control is showing.
        //   lastWindowIDs isn't updated, so actual additions/removals during Mission Control are detected on the next cycle after it ends)
        guard !isSpaceSwitching && !workspaceManager.isSwitching && !isHandlingScreenChange && !isWaking && !borderManager.isInMissionControl else {
            return
        }

        // Skip automatic tiling while Zen mode is active (guards against input-source switches like the eisu key)
        // However, if a window change occurred, automatically exit Zen mode and return to normal tiling
        if ZenModeManager.shared.isActive {
            let onScreenIDsZen = accessibilityManager.getOnScreenWindowIDs()
            let allWindowsZen = accessibilityManager.getAllWindows()
            let currentCountZen = allWindowsZen.filter { onScreenIDsZen.contains($0.id) && $0.shouldBeManaged() }.count

            guard currentCountZen != lastWindowCount else {
                return
            }

            // Window changed → exit Zen mode and return to normal tiling
            ZenModeManager.shared.exit()
            // Continue with the normal window-change handling after this
        }

        // Skip everything while the lock screen (loginwindow) is frontmost
        // because the Accessibility API becomes unusable while locked, making windows appear to have vanished
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow" {
            return
        }

        // Also skip while the screen is locked
        if wasScreenLocked {
            return
        }

        // Record "the focus monitor at this moment" for registering the new window
        // By the time a new window is detected, macOS has already moved focus to it, so
        // Using the value recorded one cycle ago lets us correctly determine which monitor had focus
        // (this needs to run every cycle, so it's placed before the full-scan skip below)
        if let focused = accessibilityManager.getFocusedWindow(),
           workspaceManager.isWindowInAnyWorkspace(focused.id) {
            lastFocusedScreen = workspaceManager.screenForWindow(focused.id)
        }

        // Target only on-screen windows (i.e. windows in the current Space)
        // Filtering with shouldBeManaged() screens out transient windows during app launch, and
        // Exclude internal windows, like Excel's, from the count
        let onScreenIDs = accessibilityManager.getOnScreenWindowIDs()

        // Skip the expensive full AX scan if the set of windows is unchanged from last time.
        // Querying all apps via AX takes 25-390ms, and running it every 0.3 seconds
        // because it kept the main thread constantly busy, making the whole app feel sluggish
        // (but so the later watchdog's state-restore step isn't blocked,
        //   even if skips keep happening, always do a full scan at a fixed interval)
        if onScreenIDs == lastOnScreenIDSignature && consecutiveScanSkips < Self.maxConsecutiveScanSkips {
            consecutiveScanSkips += 1
            return
        }
        consecutiveScanSkips = 0
        lastOnScreenIDSignature = onScreenIDs

        let allWindows = accessibilityManager.getAllWindows()

        // Check whether a window hidden with Ctrl+Opt+X was manually restored via the Dock or similar.
        // Don't add a new poller — piggyback on this existing periodic scan (0.3s interval)
        HiddenWindowManager.shared.checkForManualRestores(allWindows: allWindows)

        let currentWindows = allWindows.filter { onScreenIDs.contains($0.id) && $0.shouldBeManaged() }
        let currentCount = currentWindows.count

        // Watchdog: even though no window is registered to the workspace,
        // If the window is visibly on screen, the state is broken, so restore it
        // Note: while moving to an empty Space, the current Space may be empty but other Spaces still have windows, so
        //       Treat it as fine if there's at least one registration across all Spaces
        if currentCount > 0 {
            let hasRegisteredWindows = workspaceManager.hasAnyRegisteredWindows()
            if !hasRegisteredWindows {
                // First try restoring from closedWindowsCache
                var restoredFromCache = false
                for window in currentWindows {
                    if workspaceManager.restoreFromCacheIfNeeded(detectedWindowID: window.id) {
                        restoredFromCache = true
                        break
                    }
                }

                if !restoredFromCache {
                    // Reinitialize if restoring from the cache fails
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

        // Gone from the accessibility list, but still showing up on screen (in CGWindowList)
        // If the window is there, it wasn't really closed — it's just a transient miss.
        // Measured: Arc's windows can briefly vanish from the AX list, and
        // Misreading it as "closed" dropped the registration, and the one remaining window ended up assigned the whole screen
        // (Arc comes back after this and ends up fullscreen instead).
        // But cap the number of consecutive skips, so a misjudgment doesn't cause it to be skipped forever
        let vanishedButStillOnScreen = lastWindowIDs.subtracting(currentWindowIDs).intersection(onScreenIDs)
        if !vanishedButStillOnScreen.isEmpty && consecutiveGhostSkips < Self.maxConsecutiveGhostSkips {
            consecutiveGhostSkips += 1
            if PerfLog.enabled {
                PerfLog.logf("一時的な取りこぼしとして見送り: %d件 (%d回目)",
                             vanishedButStillOnScreen.count, consecutiveGhostSkips)
            }
            // Discard the cache and the previous window set so the next cycle is guaranteed to re-fetch
            accessibilityManager.invalidateWindowCache()
            lastOnScreenIDSignature = []
            return
        }
        consecutiveGhostSkips = 0

        // Exited fullscreen and returned to the screen, but to a workspace that isn't currently active
        // If it belongs to one, evacuate it to the hidden corner (do nothing if there's nothing to act on)
        let strayHiddenIDs = workspaceManager.hideStrayVisibleWindows(currentWindows: currentWindows)

        // Whether a new window appeared this cycle (used by the delayed-retile check later)
        var windowsWereAdded = false

        if currentCount != lastWindowCount {
            // When a window was closed
            if currentCount < lastWindowCount {
                let closedWindowIDs = lastWindowIDs.subtracting(currentWindowIDs)

                // If every window disappears at once, that's a sign of the lock screen or sleep
                // Save the cache and wait, without unregistering the window
                // (the lock notification can arrive later than checkForWindowChanges)
                if currentCount == 0 && lastWindowCount > 1 {
                    workspaceManager.cacheCurrentStateOnWindowClose()
                    lastWindowCount = 0
                    lastWindowIDs = []
                    return
                }

                // Among windows that "disappeared from the screen," ones that merely entered native fullscreen
                // distinguishes this case from windows that are genuinely closed (or whose app quit entirely).
                // allWindows fetches every window per app via AX, so
                // Windows that went fullscreen and moved to another Space are also marked isFullscreen=true
                // is still included there. A window that's genuinely closed disappears from allWindows too.
                var allWindowsByID: [CGWindowID: WindowInfo] = [:]
                for w in allWindows {
                    allWindowsByID[w.id] = w
                }
                let fullscreenWindowIDs = closedWindowIDs.filter { allWindowsByID[$0]?.isFullscreen == true }

                // A window hidden (minimized) with Ctrl+Opt+X still shows up in the AX list, but
                // it drops out of CGWindowList's onScreen list (minimized windows aren't considered on-screen).
                // Excluded because misreading this as "closed" would lose the neighbor memory and workspace registration.
                // But if it's also gone from allWindowsByID (the whole app really quit), then
                // Treat it as closed normally
                let stillHiddenWindowIDs = closedWindowIDs.filter {
                    HiddenWindowManager.shared.isHidden($0) && allWindowsByID[$0] != nil
                }

                let reallyClosedWindowIDs = closedWindowIDs.subtracting(fullscreenWindowIDs).subtracting(stillHiddenWindowIDs)

                // Only do the cache save, unregister, and focus handling if a window was genuinely closed
                if !reallyClosedWindowIDs.isEmpty {
                    // Save the cache before unregistering, so we can restore later
                    workspaceManager.cacheCurrentStateOnWindowClose()

                    // Before unregistering, record which monitor the closed window was on
                    // (screenForWindow no longer works once the window is unregistered)
                    let preferredScreen = reallyClosedWindowIDs.compactMap {
                        workspaceManager.screenForWindow($0)
                    }.first

                    // Also unregister from the workspace
                    for closedID in reallyClosedWindowIDs {
                        workspaceManager.unregisterWindow(closedID)
                        // If it was actually closed while hidden, drop it from the hidden list too
                        HiddenWindowManager.shared.forgetIfPresent(closedID)
                    }

                    focusAdjacentWindowAfterClose(preferringScreen: preferredScreen)
                }
                // fullscreenWindowIDs (windows that merely entered fullscreen) are
                // Do nothing, keeping the workspace registration as is.
                // Once fullscreen is exited, hideStrayVisibleWindows and normal tiling will
                // It automatically returns to its original workspace/monitor assignment.
            }

            // When a window was added
            if currentCount > lastWindowCount {
                let newWindowIDs = currentWindowIDs.subtracting(lastWindowIDs)

                // Try to restore from the cache
                // Restore a vanished window if it comes back after unlock or wake from sleep
                // A window that's still registered in a workspace (one that, on exiting fullscreen,
                // a window that came back) doesn't need restoring, so skip it.
                // Without this skip, the stale cache would roll back the current state.
                var restoredFromCache = false
                for newID in newWindowIDs {
                    if workspaceManager.isWindowInAnyWorkspace(newID) {
                        continue
                    }
                    if workspaceManager.restoreFromCacheIfNeeded(detectedWindowID: newID) {
                        restoredFromCache = true
                        break
                    }
                }

                if restoredFromCache {
                    // Even after restoring from the cache, anything not in the cache
                    // Register new windows (Arc, etc.) individually
                    for newID in newWindowIDs {
                        if workspaceManager.isWindowInAnyWorkspace(newID) {
                            continue
                        }

                        if let window = currentWindows.first(where: { $0.id == newID }) {
                            let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
                            let centerX = window.frame.midX
                            let centerY = mainScreenHeight - window.frame.midY
                            let center = CGPoint(x: centerX, y: centerY)


                            var assigned = false
                            for screen in NSScreen.screens {
                                if screen.frame.contains(center) {
                                    workspaceManager.registerWindow(newID, on: screen)
                                    assigned = true
                                    break
                                }
                            }
                            if !assigned {
                                if let nearest = self.closestScreen(to: center) {
                                    workspaceManager.registerWindow(newID, on: nearest)
                                } else {
                                }
                            }
                        }
                    }

                    lastWindowCount = currentCount
                    lastWindowIDs = currentWindowIDs
                    tilingEngine.tileAllScreens()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.borderManager.updateBorder()
                    }
                    retileAfterNewWindowSettles()
                    return
                }

                // The normal new-window registration path
                // Prefer registering to the focus monitor recorded one cycle ago
                // (when opening a new window via Cmd+N etc., place it on the monitor that had focus rather than by physical position)
                for newID in newWindowIDs {
                    // Skip if it's already registered in some workspace
                    // (avoids mistakenly registering a window from another workspace right after a workspace switch)
                    if workspaceManager.isWindowInAnyWorkspace(newID) {
                        continue
                    }

                    // Register to the monitor that had focus one cycle ago, if there is one
                    if let screen = lastFocusedScreen {
                        workspaceManager.registerWindow(newID, on: screen)
                        continue
                    }

                    if let window = currentWindows.first(where: { $0.id == newID }) {
                        // Fall back to physical position when there's no focus information
                        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
                        let centerX = window.frame.midX
                        let centerY = mainScreenHeight - window.frame.midY
                        let center = CGPoint(x: centerX, y: centerY)

                        var assigned = false
                        for screen in NSScreen.screens {
                            if screen.frame.contains(center) {
                                workspaceManager.registerWindow(newID, on: screen)
                                assigned = true
                                break
                            }
                        }
                        if !assigned {
                            // If it doesn't fall inside any monitor, register it to the nearest one
                            if let nearest = self.closestScreen(to: center) {
                                workspaceManager.registerWindow(newID, on: nearest)
                            }
                        }
                    }
                }

                // windows re-hidden by hideStrayVisibleWindows (whose original workspace
                // don't move focus to a fullscreen-returned window that isn't currently active
                focusNewWindow(newWindowIDs: newWindowIDs.subtracting(strayHiddenIDs), allWindows: currentWindows)
                windowsWereAdded = true
            }

            lastWindowCount = currentCount
            lastWindowIDs = currentWindowIDs
            tilingEngine.tileAllScreens()

            // Update the border and save state after tiling
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.borderManager.updateBorder()
            }

            // A newly created window may not have settled on a final size yet, so
            // Retile once things have settled down
            if windowsWereAdded {
                retileAfterNewWindowSettles()
            }

            // Save state whenever a window change occurs
            // (don't rely solely on the save-on-shutdown path)
            workspaceManager.saveStateToDisk()

        } else if currentWindowIDs != lastWindowIDs {
            // Same window count, but the IDs changed
            // (e.g. when opening a file from the Excel/PowerPoint start screen,
            //   a case where a window gets swapped for a different window)
            let closedWindowIDs = lastWindowIDs.subtracting(currentWindowIDs)
            let newWindowIDs = currentWindowIDs.subtracting(lastWindowIDs)

            // Unregister the closed window from the workspace
            workspaceManager.cacheCurrentStateOnWindowClose()
            for closedID in closedWindowIDs {
                workspaceManager.unregisterWindow(closedID)
            }

            // Register the new window to the workspace
            for newID in newWindowIDs {
                if workspaceManager.isWindowInAnyWorkspace(newID) { continue }
                if let window = currentWindows.first(where: { $0.id == newID }) {
                    let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
                    let centerX = window.frame.midX
                    let centerY = mainScreenHeight - window.frame.midY
                    let center = CGPoint(x: centerX, y: centerY)
                    var assigned = false
                    for screen in NSScreen.screens {
                        if screen.frame.contains(center) {
                            workspaceManager.registerWindow(newID, on: screen)
                            assigned = true
                            break
                        }
                    }
                    if !assigned {
                        if let nearest = closestScreen(to: center) {
                            workspaceManager.registerWindow(newID, on: nearest)
                        }
                    }
                }
            }

            lastWindowIDs = currentWindowIDs
            tilingEngine.tileAllScreens()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.borderManager.updateBorder()
            }
        }
    }
    
    /// Retile once a new window has settled down
    /// With Ghostty's Cmd+N and similar, a window is still at its initial size right after detection, and
    /// A single tiling pass can sometimes settle on a size smaller than the assigned area
    private func retileAfterNewWindowSettles() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.tilingEngine.tileAllScreens()
            self.borderManager.updateBorder()
        }
    }

    /// Move focus to the newly added window
    private func focusNewWindow(newWindowIDs: Set<CGWindowID>, allWindows: [WindowInfo]) {
        // Find and focus the new window
        for window in allWindows {
            if newWindowIDs.contains(window.id) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    window.focus()
                }
                return
            }
        }
    }

    /// After a window closes, move focus to the window under the mouse cursor
    private func focusAdjacentWindowAfterClose(preferringScreen: NSScreen? = nil) {
        // Move focus after a short delay (waiting for tiling to finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }

            // Prefer focusing a window on the same monitor as the one that closed
            // Works around macOS automatically shifting focus to another window of the same app on a different monitor
            if let screen = preferringScreen {
                let screenID = ScreenIdentifier(from: screen)
                if let columns = self.tilingEngine.tiledWindows[screenID],
                   let firstWindow = columns.compactMap({ $0.first }).first {
                    firstWindow.focus()
                    return
                }
            }

            // Get the current mouse position
            let mouseLocation = NSEvent.mouseLocation

            // Find the window at the mouse position
            // Only move focus to windows registered in tiling (excludes unmanaged windows like Arc's)
            if let windowUnderMouse = self.accessibilityManager.getWindowAt(mouseLocation),
               self.workspaceManager.isWindowInAnyWorkspace(windowUnderMouse.id) {
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
        // Don't interfere while a workspace switch is in progress
        guard !workspaceManager.isSwitching else { return }
        guard let activatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }

        // Ignore Axis's own activation notifications
        if activatedApp.bundleIdentifier == Bundle.main.bundleIdentifier {
            return
        }

        // The focused window can be undetermined right after an app switch, so wait a bit before deciding
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self else { return }

            let focusedWindow = self.accessibilityManager.getFocusedWindow()
            let targetWindow: WindowInfo?

            // Prefer the frontmost focused window first
            if let focusedWindow = focusedWindow,
               focusedWindow.app.processIdentifier == activatedApp.processIdentifier,
               self.workspaceManager.isWindowInAnyWorkspace(focusedWindow.id) {
                targetWindow = focusedWindow
            } else {
                // If focus can't be determined, pick one of this app's managed windows
                targetWindow = self.accessibilityManager.getWindows(for: activatedApp)
                    .first { window in
                        window.shouldBeManaged() && self.workspaceManager.isWindowInAnyWorkspace(window.id)
                    }
            }

            guard let targetWindow = targetWindow,
                  let location = self.workspaceManager.workspaceLocation(for: targetWindow.id) else {
                return
            }

            let currentWorkspace = self.workspaceManager.currentWorkspace(on: location.screen)
            guard location.workspace != currentWorkspace else { return }

            self.workspaceManager.switchWorkspace(
                to: location.workspace,
                on: location.screen,
                focusWindowID: targetWindow.id
            )
        }
    }
    
    @objc private func onActiveSpaceChanged(_ notification: Notification) {
        // Skip while monitor-change handling is in progress
        // (a Space-switch notification also arrives on monitor connect/disconnect, but that's handled by processScreenChange)
        guard !isHandlingScreenChange else {
            return
        }

        // Also skip when the monitor configuration has changed but processScreenChange hasn't run yet
        // (macOS can send the Space-switch notification before the monitor-change one)
        let currentScreenIDs = Set(NSScreen.screens.map { ScreenIdentifier(from: $0) })
        if currentScreenIDs != knownScreenIDs {
            return
        }


        // Set the Space-switching flag
        isSpaceSwitching = true

        // Update the current Space's window info after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }

            // Update lastWindowIDs with the current Space's on-screen windows
            // Match the same criteria as checkForWindowChanges (on-screen + shouldBeManaged).
            // Including it in lastWindowIDs without filtering would, for a window returning from fullscreen,
            // The window would stop being caught by checkForWindowChanges' "new window detected" path
            let onScreenIDs = self.accessibilityManager.getOnScreenWindowIDs()
            let allWindows = self.accessibilityManager.getAllWindows()
            let onScreenWindows = allWindows.filter { onScreenIDs.contains($0.id) && $0.shouldBeManaged() }
            self.lastWindowCount = onScreenWindows.count
            self.lastWindowIDs = Set(onScreenWindows.map { $0.id })

            // Initialize the workspace's window registration
            // (runs only the first time; the isInitialized guard makes subsequent calls no-ops)
            self.workspaceManager.initializeWithCurrentWindows()

            // Register on-screen windows that aren't registered to any workspace
            // (when actually switching real macOS Spaces, that Space's windows
            //   to make sure it doesn't get left behind unregistered)
            let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
            for window in onScreenWindows {
                if self.workspaceManager.isWindowInAnyWorkspace(window.id) {
                    continue
                }
                let centerX = window.frame.midX
                let centerY = mainScreenHeight - window.frame.midY
                let center = CGPoint(x: centerX, y: centerY)
                var assigned = false
                for screen in NSScreen.screens {
                    if screen.frame.contains(center) {
                        self.workspaceManager.registerWindow(window.id, on: screen)
                        assigned = true
                        break
                    }
                }
                if !assigned, let nearest = self.closestScreen(to: center) {
                    self.workspaceManager.registerWindow(window.id, on: nearest)
                }
            }

            // Exited fullscreen and returned, but to a workspace that's not currently active
            // If it belongs to one, evacuate it to the hidden corner
            self.workspaceManager.hideStrayVisibleWindows(currentWindows: onScreenWindows)

            // Reapply tiling
            self.tilingEngine.tileAllScreens()

            // Update the border
            self.borderManager.updateBorder()

            // Clear the flag
            self.isSpaceSwitching = false
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
        }
    }

    // MARK: - Screen lock handling

    @objc private func onScreenLocked() {
        wasScreenLocked = true
    }

    @objc private func onScreenUnlocked() {
        wasScreenLocked = false

        // If unlocked after waking from sleep, run the recovery logic here
        if isWaking {
            performWakeRecovery()
        }
    }

    // MARK: - Sleep/wake handling

    @objc private func onSystemWillSleep() {
        // Set a flag so window checks don't run during sleep
        isWaking = true
        // Save workspace state before sleep
        workspaceManager.saveStateToDisk()
    }

    @objc private func onSystemWake() {

        // If the screen is locked, wait for it to unlock before running the recovery logic
        // (the Accessibility API is unavailable while locked)
        // Check not just the wasScreenLocked flag but also whether loginwindow is frontmost
        // (because on wake from sleep, the ScreenLocked notification doesn't always arrive first)
        let isLoginWindow = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow"

        if wasScreenLocked || isLoginWindow {
            wasScreenLocked = true
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
        let previousScreenCount = knownScreenIDs.count
        let currentScreenCount = currentScreenIDs.count

        let removedScreenIDs = knownScreenIDs.subtracting(currentScreenIDs)
        let addedScreenIDs = currentScreenIDs.subtracting(knownScreenIDs)

        // If the monitor count hasn't changed, just retile (a resolution or arrangement change only)
        guard !removedScreenIDs.isEmpty || !addedScreenIDs.isEmpty else {
            knownScreenIDs = currentScreenIDs
            tilingEngine.tileAllScreens()
            return
        }

        // Approach change:
        // When a monitor is added, do an internal reset equivalent to a restart.
        // (doesn't actually restart the app — just resets and rebuilds internal state)
        // So it doesn't get added by mistake even when a displayID glitch during removal produces a spurious "added" event,
        // Limited to the case where the monitor count actually increased.
        if !addedScreenIDs.isEmpty && currentScreenCount > previousScreenCount {
            workspaceManager.forceReinitialize()
            knownScreenIDs = currentScreenIDs
            tilingEngine.cleanupDisconnectedScreens()
            tilingEngine.tileAllScreens()
            borderManager.updateBorder()

            // Refresh window tracking
            let onScreenIDs = accessibilityManager.getOnScreenWindowIDs()
            let allWindows = accessibilityManager.getAllWindows()
            let onScreenWindows = allWindows.filter { onScreenIDs.contains($0.id) && $0.shouldBeManaged() }
            lastWindowCount = onScreenWindows.count
            lastWindowIDs = Set(onScreenWindows.map { $0.id })

            // Save the state after the reset
            workspaceManager.saveStateToDisk()
            return
        }

        // Handling for a disconnected monitor
        for removedID in removedScreenIDs {
            workspaceManager.handleScreenDisconnected(removedScreenID: removedID)
        }

        // Handling for a reconnected monitor
        for addedID in addedScreenIDs {
            workspaceManager.handleScreenReconnected(reconnectedScreenID: addedID)
        }

        // Refresh the monitor list
        knownScreenIDs = currentScreenIDs

        // Remove data keyed by the old NSScreen and retile across all screens
        // (macOS rebuilds NSScreen objects when the monitor configuration changes)
        tilingEngine.cleanupDisconnectedScreens()
        tilingEngine.tileAllScreens()
        borderManager.updateBorder()

        // Update window tracking (filtered by shouldBeManaged() to stay consistent with checkForWindowChanges)
        let onScreenIDs = accessibilityManager.getOnScreenWindowIDs()
        let allWindows = accessibilityManager.getAllWindows()
        let onScreenWindows = allWindows.filter { onScreenIDs.contains($0.id) && $0.shouldBeManaged() }
        lastWindowCount = onScreenWindows.count
        lastWindowIDs = Set(onScreenWindows.map { $0.id })

    }

    /// Show the workspace number in the menu bar
    private func updateWorkspaceDisplay() {
        guard let button = statusItem?.button else { return }
        let ws = workspaceManager.currentWorkspaceForFocusedScreen()
        button.title = " \(ws)"
    }
}
