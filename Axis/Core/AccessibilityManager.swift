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

        // A very short-lived cache.
        // Within a single key press or hover, focus moves, tiling, border updates, and so on
        // Since each one triggered a full scan independently, it was measured running 2-5 times per second (10-125ms each).
        // Whenever Axis itself moves a window, invalidateWindowCache() always discards it, so
        // It never gets placed using stale coordinates
        let now = CFAbsoluteTimeGetCurrent()
        if now - cachedAllWindowsTime < Self.allWindowsCacheTTL {
            return cachedAllWindows
        }

        let perfStart = now

        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }

        // Run the per-app AX queries in parallel.
        // Running them serially means a slow-responding app (measured: Activity Monitor at 187ms, Outlook at 149ms)
        // The wait times just summed up, adding up to 25-390ms overall.
        // Running them in parallel cuts the wait down to just the slowest single app.
        // Write results back by index to preserve the original app order
        var results = [[WindowInfo]](repeating: [], count: runningApps.count)
        if !runningApps.isEmpty {
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: runningApps.count) { index in
                let appWindows = self.getWindows(for: runningApps[index])
                lock.lock()
                results[index] = appWindows
                lock.unlock()
            }
        }
        let windows = results.flatMap { $0 }

        // Record windows that disappeared since the last scan (for diagnostics).
        // A genuine close also shows up here, but if it appears right before "assigned the whole screen,"
        // Serves as evidence that a miss broke the layout
        if PerfLog.enabled {
            let currentIDs = Set(windows.map { $0.id })
            let disappeared = previousScanWindows.filter { !currentIDs.contains($0.key) }
            if !disappeared.isEmpty {
                let names = disappeared.values.joined(separator: ", ")
                PerfLog.logf("★ウィンドウ消失: %@ (%d件 → %d件)", names, previousScanWindows.count, windows.count)
            }
            previousScanWindows = Dictionary(uniqueKeysWithValues: windows.map {
                ($0.id, "\($0.app.localizedName ?? "?")/\($0.title)")
            })
        }

        cachedAllWindows = windows
        cachedAllWindowsTime = CFAbsoluteTimeGetCurrent()

        let perfElapsed = CFAbsoluteTimeGetCurrent() - perfStart
        if PerfLog.enabled && perfElapsed >= 0.005 {
            PerfLog.logf("AX.getAllWindows: %.1fms (%d windows)", perfElapsed * 1000, windows.count)
        }

        return windows
    }

    // MARK: - Window list cache

    /// The cache's lifetime (in seconds)
    /// Short enough to feel like a single action to a person, yet long enough to batch together consecutive internal operations
    private static let allWindowsCacheTTL: TimeInterval = 0.1

    private var cachedAllWindows: [WindowInfo] = []
    private var cachedAllWindowsTime: CFAbsoluteTime = 0

    /// Windows visible on the previous scan (for diagnostics: ID → app name/title)
    private var previousScanWindows: [CGWindowID: String] = [:]

    /// Discard the window list cache
    /// Always call this right after Axis changes state — moving a window, shifting focus, etc.
    func invalidateWindowCache() {
        cachedAllWindowsTime = 0
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
        // (too short and it misses slow apps' windows, breaking the layout)
        AXUIElementSetMessagingTimeout(axApp, 0.3)

        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)

        guard result == .success, let axWindows = windowsRef as? [AXUIElement] else {
            // The query failed (usually cut off by a timeout).
            // This app's windows get reported downstream as "not existing," and
            // This can break the layout, so always log when it happens
            if PerfLog.enabled {
                PerfLog.logf("★AX取りこぼし: %@ (result=%d)", app.localizedName ?? "?", result.rawValue)
            }
            return []
        }

        let windows = axWindows.compactMap { axWindow -> WindowInfo? in
            return WindowInfo(axElement: axWindow, app: app)
        }

        // Also counts as a miss when AX returned a window but a WindowInfo couldn't be built for it
        if PerfLog.enabled && windows.count < axWindows.count {
            PerfLog.logf("★AX取りこぼし(情報取得失敗): %@ (%d件中 %d件のみ)",
                         app.localizedName ?? "?", axWindows.count, windows.count)
        }

        return windows
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
        // (too short and it misses slow apps' windows, breaking the layout)
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        var focusedWindowRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindowRef)

        guard result == .success, let axWindow = focusedWindowRef else {
            return nil
        }

        // Treat it as an AXUIElement
        let windowElement = axWindow as! AXUIElement
        return WindowInfo(axElement: windowElement, app: frontApp)
    }
    
    /// Get just the ID of the focused window
    /// getFocusedWindow() queries several AX attributes — title, size, role, etc. — to build a WindowInfo
    /// Polls AX about 8 times. Just to confirm whether focus actually moved to the target window
    /// In this case, get just the ID to reduce the wait on the main thread
    func getFocusedWindowID() -> CGWindowID? {
        guard isAccessibilityEnabled,
              let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let axApp = AXUIElementCreateApplication(frontApp.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.3)

        var focusedWindowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindowRef) == .success,
              let axWindow = focusedWindowRef else {
            return nil
        }

        let element = axWindow as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.3)

        var windowID: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &windowID) == .success, windowID != 0 else {
            return nil
        }
        return windowID
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
