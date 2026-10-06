

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
    
    private let accessibilityManager = AccessibilityManager.shared
    private let hotkeyManager = HotkeyManager.shared
    private let tilingEngine = TilingEngine.shared
    private let borderManager = BorderManager.shared
    private let workspaceManager = WorkspaceManager.shared
    
    /// Follows focus into other workspaces and hands it on when the focused window closes
    private let focusFollower = FocusFollower()

    // The startup guide window
    private var startupGuideController: StartupGuideWindowController?

    // The settings window
    private var settingsWindow: NSWindow?
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Registered before launch finishes, so a URL that launched Axis is not missed
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    /// axis://launch-aside?path=/Applications/Some.app
    ///     launch the app with its windows on an empty workspace, out of sight
    /// axis://focus-back
    ///     jump back to the previously focused window
    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let components = URLComponents(string: string)
        else { return }
        let path = components.queryItems?.first(where: { $0.name == "path" })?.value

        switch components.host {
        case "launch-aside":
            guard let path, !path.isEmpty else { return }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            LaunchAsideManager.shared.launch(appAt: url, on: workspaceManager.focusedScreen())
        case "focus-back":
            FocusHistoryManager.shared.jumpBack()
        default:
            break
        }
    }

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
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Save the layout, then bring every window Axis moved out of sight back on screen
        workspaceManager.prepareForQuit()
        hotkeyManager.stop()
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
            iconName = "rectangle.split.3x1" // Normal tiling icon
        case .gapSelect:
            iconName = "arrow.left.and.right" // Gap selection
        case .windowPalette:
            iconName = "rectangle.grid.2x2" // Window palette
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
        PerfLog.log("=== Axis launched / FFM enabled=\(FocusFollowsMouseManager.shared.isEnabled) ===")

        // Periodic system load line, so misbehavior can be checked against CPU pressure at that moment
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            PerfLog.event("load: \(PerfLog.loadAverage())")
        }

        // Track the windows of every app: the saved workspaces and columns come back for the windows
        // that still exist, the others join the shown workspace of their monitor, and focus goes to
        // the first window once they are laid out
        focusFollower.start()
        workspaceManager.start { [weak self] in
            self?.focusFirstWindow()
        }
    }

    /// Focus the first tile, preferring the main screen
    private func focusFirstWindow() {
        let screens = [NSScreen.main].compactMap { $0 } + NSScreen.screens.filter { $0 != NSScreen.main }
        for screen in screens {
            if let firstWindow = tilingEngine.tiledColumns(on: screen).compactMap({ $0.first }).first {
                firstWindow.focus()
                borderManager.updateBorderExpecting(windowID: firstWindow.id)
                return
            }
        }
        borderManager.updateBorder()
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
    }

    /// Show the workspace number in the menu bar
    private func updateWorkspaceDisplay() {
        guard let button = statusItem?.button else { return }
        let ws = workspaceManager.currentWorkspaceForFocusedScreen()
        button.title = " \(ws)"
    }
}
