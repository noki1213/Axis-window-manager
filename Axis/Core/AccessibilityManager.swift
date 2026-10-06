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

    /// System UI that temporarily steals the frontmost position but has no focus window of its own.
    /// Notification banners and Control Center, in order to catch clicks outside the banner,
    /// Create a transparent catch-all window covering the whole screen. Treating this as a normal window
    /// treating it that way causes problems like the border expanding to fill the whole screen, or wrongly concluding focus was lost
    /// causes problems, so both BorderManager and Focus Follows Mouse reference this list to exclude them
    static let transientOverlayBundleIds: Set<String> = [
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.Spotlight",
        "com.apple.dock"
    ]

    @Published var isAccessibilityEnabled: Bool = false

    /// The reason the last getFocusedWindow() call failed (AXError)
    private(set) var lastFocusedWindowError: AXError?

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

    /// Get the windows of the application with the given PID (an app that can't be read is
    /// reported as having no windows)
    func getWindows(forPID pid: pid_t) -> [WindowInfo] {
        guard isAccessibilityEnabled, let app = NSRunningApplication(processIdentifier: pid) else {
            return []
        }
        let perfStart = CFAbsoluteTimeGetCurrent()
        defer {
            let perfElapsed = CFAbsoluteTimeGetCurrent() - perfStart
            // Only log entries over 10ms, to pin down which app is slow
            if PerfLog.enabled && perfElapsed >= 0.010 {
                PerfLog.logf("AX.getWindows(%@): %.1fms", app.localizedName ?? "?", perfElapsed * 1000)
            }
        }

        let axApp = AXUIElementCreateApplication(pid)
        // Set a timeout so the main thread doesn't block on a slow-responding app
        AXUIElementSetMessagingTimeout(axApp, 0.3)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            return []
        }
        return axWindows.compactMap { WindowInfo(axElement: $0, app: app) }
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
            lastFocusedWindowError = nil
            return nil
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            lastFocusedWindowError = nil
            PerfLog.reportFocusLost(reason: "no frontmost app", app: "-")
            return nil
        }

        let appName = frontApp.bundleIdentifier ?? frontApp.localizedName ?? "?"

        let axApp = AXUIElementCreateApplication(frontApp.processIdentifier)
        // Set a timeout so the main thread doesn't block on a slow-responding app
        // (too short and it misses slow apps' windows, breaking the layout)
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        var focusedWindowRef: CFTypeRef?
        let axStart = CFAbsoluteTimeGetCurrent()
        let result = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindowRef)
        let axElapsed = CFAbsoluteTimeGetCurrent() - axStart

        guard result == .success, let axWindow = focusedWindowRef else {
            lastFocusedWindowError = result
            // For tracking down the border-disappearing issue. Records the AX error code and elapsed time
            // (around 0.3 seconds means a timeout; -25204 is no response, -25212 is no such attribute)
            PerfLog.reportFocusLost(
                reason: String(format: "AX error %d (%.0fms)", result.rawValue, axElapsed * 1000),
                app: appName
            )
            return nil
        }

        // Treat it as an AXUIElement
        let windowElement = axWindow as! AXUIElement
        guard let window = WindowInfo(axElement: windowElement, app: frontApp) else {
            lastFocusedWindowError = nil
            // When AX returned a window but its window ID couldn't be obtained
            PerfLog.reportFocusLost(reason: "could not get window ID", app: appName)
            return nil
        }
        lastFocusedWindowError = nil
        PerfLog.reportFocusRecovered(app: appName)
        return window
    }
    
    /// Get just the ID of the focused window
    /// getFocusedWindow() queries several AX attributes (title, frame, subrole, ...) to build a WindowInfo.
    /// Callers that only need to know which window has focus use this instead, to cut the wait
    /// on the main thread
    func getFocusedWindowID() -> CGWindowID? {
        if case .window(let id) = readFocusedWindowID() {
            return id
        }
        return nil
    }

    /// What a read of the focused window's ID found
    enum FocusedWindowIDRead: Equatable {
        case window(CGWindowID)
        /// The app answered, but no window of it is focused (or the focused one has no window ID)
        case noWindow
        /// The app ran into the timeout. Asking again only makes the main thread wait for it again
        case timedOut
    }

    /// Read the focused window's ID, saying whether the app answered
    /// - Parameter timeout: the longest the read may block (in seconds)
    func readFocusedWindowID(timeout: TimeInterval = 0.3) -> FocusedWindowIDRead {
        guard isAccessibilityEnabled,
              let frontApp = NSWorkspace.shared.frontmostApplication else {
            return .noWindow
        }

        let axApp = AXUIElementCreateApplication(frontApp.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, Float(timeout))

        var focusedWindowRef: CFTypeRef?
        let start = CFAbsoluteTimeGetCurrent()
        let result = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindowRef)
        guard result == .success, let axWindow = focusedWindowRef else {
            // The same error that comes back at once is the app refusing to answer; one that comes
            // back after the whole timeout is an app that hangs
            let ranIntoTimeout = result == .cannotComplete && CFAbsoluteTimeGetCurrent() - start >= timeout * 0.8
            return ranIntoTimeout ? .timedOut : .noWindow
        }

        let element = axWindow as! AXUIElement
        AXUIElementSetMessagingTimeout(element, Float(timeout))

        var windowID: CGWindowID = 0
        let idResult = _AXUIElementGetWindow(element, &windowID)
        if idResult == .success, windowID != 0 {
            return .window(windowID)
        }
        let ranIntoTimeout = idResult == .cannotComplete && CFAbsoluteTimeGetCurrent() - start >= timeout * 0.8
        return ranIntoTimeout ? .timedOut : .noWindow
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let accessibilityPermissionGranted = Notification.Name("accessibilityPermissionGranted")
}
