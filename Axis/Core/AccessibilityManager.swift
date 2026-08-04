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
        guard isAccessibilityEnabled else {
            return []
        }

        let perfStart = CFAbsoluteTimeGetCurrent()

        var windows: [WindowInfo] = []
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }

        for app in runningApps {
            let appWindows = getWindows(for: app)
            windows.append(contentsOf: appWindows)
        }

        let perfElapsed = CFAbsoluteTimeGetCurrent() - perfStart
        if PerfLog.enabled && perfElapsed >= 0.005 {
            PerfLog.logf("AX.getAllWindows: %.1fms (%d windows)", perfElapsed * 1000, windows.count)
        }

        return windows
    }

    /// Get the windows of a specific application
    func getWindows(for app: NSRunningApplication) -> [WindowInfo] {
        let perfStart = CFAbsoluteTimeGetCurrent()
        defer {
            let perfElapsed = CFAbsoluteTimeGetCurrent() - perfStart
            // Only log entries over 10ms, to pin down which app is slow
            if PerfLog.enabled && perfElapsed >= 0.010 {
                PerfLog.logf("AX.getWindows(%@): %.1fms", app.localizedName ?? "?", perfElapsed * 1000)
            }
        }

        guard let axApp = AXUIElementCreateApplication(app.processIdentifier) as AXUIElement? else {
            return []
        }
        // Set a timeout so the main thread doesn't block on a slow-responding app
        AXUIElementSetMessagingTimeout(axApp, 0.2)

        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)

        guard result == .success, let axWindows = windowsRef as? [AXUIElement] else {
            return []
        }

        return axWindows.compactMap { axWindow -> WindowInfo? in
            return WindowInfo(axElement: axWindow, app: app)
        }
    }

    /// Get the windows of the application with the given PID
    func getWindows(forPID pid: pid_t) -> [WindowInfo] {
        guard isAccessibilityEnabled else {
            return []
        }
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return []
        }
        return getWindows(for: app)
    }
    
    /// Get the set of window IDs currently showing in the current Space (on screen)
    /// Using kCGWindowListOptionOnScreenOnly excludes windows on other Spaces
    func getOnScreenWindowIDs() -> Set<CGWindowID> {
        let options = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var windowIDs = Set<CGWindowID>()
        for windowInfo in windowList {
            if let windowNumber = windowInfo[kCGWindowNumber as String] as? CGWindowID {
                windowIDs.insert(windowNumber)
            }
        }
        return windowIDs
    }
    
    /// Get the focused window
    func getFocusedWindow() -> WindowInfo? {
        let perfStart = CFAbsoluteTimeGetCurrent()
        defer {
            let perfElapsed = CFAbsoluteTimeGetCurrent() - perfStart
            if PerfLog.enabled && perfElapsed >= 0.005 {
                PerfLog.logf("AX.getFocusedWindow: %.1fms", perfElapsed * 1000)
            }
        }

        guard isAccessibilityEnabled else {
            return nil
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }


        let axApp = AXUIElementCreateApplication(frontApp.processIdentifier)
        // Set a timeout so the main thread doesn't block on a slow-responding app
        AXUIElementSetMessagingTimeout(axApp, 0.2)
        var focusedWindowRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindowRef)

        guard result == .success, let axWindow = focusedWindowRef else {
            return nil
        }

        // Treat it as an AXUIElement
        let windowElement = axWindow as! AXUIElement
        return WindowInfo(axElement: windowElement, app: frontApp)
    }
    
    /// Get the window at the given coordinates (screen coordinate system: bottom-left origin)
    func getWindowAt(_ point: CGPoint) -> WindowInfo? {
        // Target only on-screen windows
        let onScreenIDs = getOnScreenWindowIDs()
        let allWindows = getAllWindows().filter { onScreenIDs.contains($0.id) }
        
        // We'd like to check in Z-order (frontmost first), but getAllWindows returns them in app order
        // so ideally we'd use WindowList to sort by Z-order, but
        // As a simple heuristic, the smallest window by area among the ones found (accounting for overlap), or
        // Simply returns whatever hits.
        // This simply returns whatever hits, but with overlapping windows the result can depend on app order.
        // In practice, since this is a tiling WM, overlap should be rare.
        
        // Convert to the Accessibility API's coordinate system (top-left origin)
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let axPoint = CGPoint(x: point.x, y: mainScreenHeight - point.y)
        
        return allWindows.first { window in
            window.frame.contains(axPoint)
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let accessibilityPermissionGranted = Notification.Name("accessibilityPermissionGranted")
}
