//
//  AccessibilityManager.swift
//  Axis
//
//  Created on 2026/01/27.
//

import AppKit
import ApplicationServices
import Combine

/// Handles Accessibility permission management and window access
class AccessibilityManager: ObservableObject {
    static let shared = AccessibilityManager()
    
    @Published var isAccessibilityEnabled: Bool = false
    
    private var pollTimer: Timer?
    
    private init() {
        _ = checkAccessibility()
    }
    
    // MARK: - Accessibility Permission
    
    /// Check the Accessibility permission
    func checkAccessibility() -> Bool {
        let trusted = AXIsProcessTrusted()
        DispatchQueue.main.async {
            self.isAccessibilityEnabled = trusted
        }
        return trusted
    }
    
    /// Request the Accessibility permission (opens System Settings)
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        startPollingAccessibility()
    }
    
    /// Poll until the permission is granted
    private func startPollingAccessibility() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            if self?.checkAccessibility() == true {
                timer.invalidate()
                self?.pollTimer = nil
                // Initialization run after permission is granted
                NotificationCenter.default.post(name: .accessibilityPermissionGranted, object: nil)
            }
        }
    }
    
    // MARK: - Window Access
    
    /// Get the windows of every application
    func getAllWindows() -> [WindowInfo] {
        guard isAccessibilityEnabled else { return [] }
        
        var windows: [WindowInfo] = []
        let runningApps = NSWorkspace.shared.runningApplications.filter { 
            $0.activationPolicy == .regular 
        }
        
        for app in runningApps {
            let appWindows = getWindows(for: app)
            windows.append(contentsOf: appWindows)
        }
        
        return windows
    }
    
    /// Get the windows of a specific application
    func getWindows(for app: NSRunningApplication) -> [WindowInfo] {
        guard let axApp = AXUIElementCreateApplication(app.processIdentifier) as AXUIElement? else {
            return []
        }
        
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
        
        guard result == .success, let axWindows = windowsRef as? [AXUIElement] else {
            return []
        }
        
        return axWindows.compactMap { axWindow -> WindowInfo? in
            return WindowInfo(axElement: axWindow, app: app)
        }
    }
    
    /// Get the focused window
    func getFocusedWindow() -> WindowInfo? {
        guard isAccessibilityEnabled else { return nil }
        
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        
        let axApp = AXUIElementCreateApplication(frontApp.processIdentifier)
        var focusedWindowRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindowRef)
        
        guard result == .success, let axWindow = focusedWindowRef else {
            return nil
        }
        
        // Treat it as an AXUIElement
        let windowElement = axWindow as! AXUIElement
        return WindowInfo(axElement: windowElement, app: frontApp)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let accessibilityPermissionGranted = Notification.Name("accessibilityPermissionGranted")
}
