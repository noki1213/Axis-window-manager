

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
    
    // For detecting window changes
    private var windowCheckTimer: Timer?
    private var lastWindowCount: Int = 0
    
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
            self?.startWindowManagement()
        }
    }
    
    private func startWindowManagement() {
        // Start hotkey monitoring
        hotkeyManager.start()
        
        // Run the initial tiling
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.tilingEngine.tileAllScreens()
        }
        
        // Watch for window changes (to be implemented later)
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
        
        // Periodically check for window-count changes (detects new and closed windows)
        lastWindowCount = accessibilityManager.getAllWindows().count
        windowCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkForWindowChanges()
        }
    }
    
    private func checkForWindowChanges() {
        let currentWindows = accessibilityManager.getAllWindows()
        let currentCount = currentWindows.count
        
        if currentCount != lastWindowCount {
            print("[Axis] Window count changed: \(lastWindowCount) -> \(currentCount)")
            lastWindowCount = currentCount
            tilingEngine.tileAllScreens()
        }
    }
    
    @objc private func onAppLaunched(_ notification: Notification) {
        // Retile when a new app launches
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.tilingEngine.tileAllScreens()
        }
    }
    
    @objc private func onAppTerminated(_ notification: Notification) {
        // Retile when an app quits
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.tilingEngine.tileAllScreens()
        }
    }
    
    @objc private func onActiveAppChanged(_ notification: Notification) {
        // Handling for when the active app changes (as needed)
    }
    
    @objc private func onModeChanged(_ notification: Notification) {
        if let mode = notification.object as? HotkeyManager.Mode {
            DispatchQueue.main.async { [weak self] in
                self?.updateStatusItemIcon(mode: mode)
            }
        }
    }
}
