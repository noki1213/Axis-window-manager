//
//  WindowInfo.swift
//  Axis
//
//  Created on 2026/01/27.
//

import AppKit
import ApplicationServices

/// A struct holding a window's information
struct WindowInfo: Identifiable, Equatable {
    let id: CGWindowID
    let axElement: AXUIElement
    let app: NSRunningApplication
    
    var title: String
    var frame: CGRect
    var isMinimized: Bool
    var isFullscreen: Bool
    var minSize: CGSize  // ウィンドウの最小サイズ
    
    // For determining floating status
    var subrole: String?
    var role: String?

    /// Whether it has a close button (used to supplement standard-window detection)
    var hasCloseButton: Bool
    
    init?(axElement: AXUIElement, app: NSRunningApplication) {
        // Window elements don't inherit the application element's timeout, so
        // Set a timeout so the main thread doesn't block on a slow-responding app.
        // Too short and it cuts off slow-responding apps (measured: Arc at 100-135ms), and
        // because that window would be treated as if it didn't exist, breaking the layout,
        // Set with margin above the worst measured value
        AXUIElementSetMessagingTimeout(axElement, 0.3)
        
        self.axElement = axElement
        self.app = app
        
        // Get the window ID
        var windowID: CGWindowID = 0
        let idResult = _AXUIElementGetWindow(axElement, &windowID)
        guard idResult == .success, windowID != 0 else {
            return nil
        }
        self.id = windowID
        
        // Get the title
        self.title = Self.getString(from: axElement, attribute: kAXTitleAttribute) ?? ""
        
        // Get the frame
        self.frame = Self.getFrame(from: axElement) ?? .zero
        
        // Minimized state
        self.isMinimized = Self.getBool(from: axElement, attribute: kAXMinimizedAttribute) ?? false
        
        // Fullscreen state
        self.isFullscreen = Self.getBool(from: axElement, attribute: "AXFullScreen") ?? false
        
        // Get the minimum size
        self.minSize = Self.getSize(from: axElement, attribute: "AXMinimumSize") ?? CGSize(width: 200, height: 200)
        
        // Role / Subrole
        self.role = Self.getString(from: axElement, attribute: kAXRoleAttribute)
        self.subrole = Self.getString(from: axElement, attribute: kAXSubroleAttribute)

        // Whether it has a close button (used to detect windows like PowerPoint's with a non-standard subrole)
        var closeButtonRef: CFTypeRef?
        let closeResult = AXUIElementCopyAttributeValue(axElement, kAXCloseButtonAttribute as CFString, &closeButtonRef)
        self.hasCloseButton = (closeResult == .success && closeButtonRef != nil)
    }
    
    // MARK: - Equatable
    
    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id
    }
    
    // MARK: - Window Operations
    
    /// The tolerance (in px) when verifying that the frame took effect
    private static let frameTolerance: CGFloat = 2.0

    /// The maximum number of attempts for setting the frame
    private static let frameMaxAttempts = 3

    /// The frame Axis last applied (window ID → frame)
    /// Because the watchdog and retiling keep rewriting the same layout over and over,
    /// Skip the AX write entirely when it's "already meant to be there, and actually is there"
    private static var lastAppliedFrames: [CGWindowID: CGRect] = [:]

    /// Discard the record of the applied frame (e.g. when a window closes)
    static func forgetAppliedFrame(_ windowID: CGWindowID) {
        lastAppliedFrames.removeValue(forKey: windowID)
    }

    /// Set the window's position and size
    /// Modeled on AeroSpace's implementation: set size → position → size, in that order.
    /// Except that when enlarging a window, the position is decided first (see the ordering note below).
    /// It also reads back the actual frame after setting it and re-applies if it drifted from the requested value.
    /// (for apps like Ghostty that round sizes to cell units, setting it just once may not
    /// because it ends up left smaller than its assigned area, not matching what was requested)
    func setFrame(_ newFrame: CGRect) {
        // Do nothing if it's already at the target position and size, and Axis itself was the one that put it there.
        // The reason for conditioning on "this app placed it" is that right after it's moved by an external cause,
        // So it doesn't get mistakenly skipped due to a WindowInfo holding a stale frame
        if Self.isCloseEnough(frame, newFrame),
           let applied = Self.lastAppliedFrames[id],
           Self.isCloseEnough(applied, newFrame) {
            return
        }

        // Moving a window makes the cached frame stale, so discard it
        AccessibilityManager.shared.invalidateWindowCache()

        // Decides the write order.
        // When enlarging, writing the size first makes the window — still at its old position — overflow off-screen, and
        // The app itself can shrink it, so it may not end up at the requested size.
        // so when expanding, set the position first, then the size
        let isGrowing = newFrame.width > frame.width + Self.frameTolerance
            || newFrame.height > frame.height + Self.frameTolerance

        // Disable animation (the technique used by AeroSpace/yabai/Rectangle)
        disableAnimations {
            var previousFrame: CGRect?

            for attempt in 0..<Self.frameMaxAttempts {
                if isGrowing {
                    // Position → size → position
                    applyPosition(newFrame.origin)
                    setSize(newFrame.size)
                    applyPosition(newFrame.origin)
                } else {
                    // Size → position → size (some apps need the size set last to take effect)
                    setSize(newFrame.size)
                    applyPosition(newFrame.origin)
                    setSize(newFrame.size)
                }

                // Read back the frame that was actually applied and verify it
                guard let actual = Self.getFrame(from: axElement) else { return }
                if Self.isCloseEnough(actual, newFrame) {
                    Self.lastAppliedFrames[id] = newFrame
                    return
                }

                // If the requested size is below the minimum, give up since it can't shrink further
                if newFrame.width < minSize.width - Self.frameTolerance
                    || newFrame.height < minSize.height - Self.frameTolerance {
                    return
                }

                // If nothing changed since the last attempt, retrying is pointless, so bail out
                if let previous = previousFrame, Self.isCloseEnough(actual, previous) {
                    return
                }
                previousFrame = actual

                // Wait for the app to finish its own relayout before the next attempt
                if attempt < Self.frameMaxAttempts - 1 {
                    usleep(15_000)
                }
            }
        }
    }

    /// Whether two frames match within the allowed tolerance
    private static func isCloseEnough(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= frameTolerance
            && abs(lhs.origin.y - rhs.origin.y) <= frameTolerance
            && abs(lhs.width - rhs.width) <= frameTolerance
            && abs(lhs.height - rhs.height) <= frameTolerance
    }
    
    /// Perform the operation with animation disabled
    private func disableAnimations(_ operation: () -> Void) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        
        // Fetch AXEnhancedUserInterface
        var wasEnabled: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, &wasEnabled)
        let wasEnabledBool = (wasEnabled as? Bool) ?? false
        
        // Temporarily disabled
        if wasEnabledBool {
            AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        }
        
        // Perform the operation
        operation()
        
        // Revert it
        if wasEnabledBool {
            AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }
    
    /// Set the window's position
    func setPosition(_ position: CGPoint) {
        disableAnimations {
            applyPosition(position)
        }
    }

    /// Write only the position to AX (disabling animation is the caller's responsibility)
    /// Prevents applying the animation-disable twice when called from within setFrame
    private func applyPosition(_ position: CGPoint) {
        var pos = position
        let positionValue = AXValueCreate(.cgPoint, &pos)!
        AXUIElementSetAttributeValue(axElement, kAXPositionAttribute as CFString, positionValue)
    }
    
    /// Set the window's size
    func setSize(_ size: CGSize) {
        var sz = size
        let sizeValue = AXValueCreate(.cgSize, &sz)!
        AXUIElementSetAttributeValue(axElement, kAXSizeAttribute as CFString, sizeValue)
    }
    
    /// Minimize the window (used to hide windows on workspace switches)
    func minimize() {
        AXUIElementSetAttributeValue(axElement, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    /// Un-minimize the window
    func unminimize() {
        AXUIElementSetAttributeValue(axElement, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }

    /// Set focus to the window
    /// Sometimes only the app activation takes effect and the window designation doesn't, in which case
    /// Focus falls back to another window that same app had just prior.
    /// So it reads back the focus state after setting it and retries if it doesn't match the target.
    func focus() {
        // Discard the cache since focus and frontmost state are changing
        AccessibilityManager.shared.invalidateWindowCache()

        let perfOverallStart = CFAbsoluteTimeGetCurrent()

        let perfSyncStart = perfOverallStart
        applyFocusOnce(useAppActivate: false)
        let perfSyncElapsed = CFAbsoluteTimeGetCurrent() - perfSyncStart
        if PerfLog.enabled && perfSyncElapsed >= 0.005 {
            PerfLog.logf("WindowInfo.focus()同期部分: %.1fms", perfSyncElapsed * 1000)
        }

        // If this focus change came from a key press, pick up that record to measure end-to-end time
        let claimedKeyPress = PerfLog.claimKeyPress()
        verifyFocus(attempt: 0, focusStart: perfOverallStart, claimedKeyPress: claimedKeyPress)
    }

    /// The actual implementation of setting focus (a single attempt)
    /// - Parameter useAppActivate: whether to focus via the conventional activate() instead of the private API.
    ///   Set to true on retry, as a fallback for environments where the private API doesn't work
    private func applyFocusOnce(useAppActivate: Bool) {
        // Normally this raises the process and designates the window at the same time.
        // If this succeeds, the app never gets a chance to pick a different window of its own
        if !useAppActivate, setFrontProcessWithThisWindow() {
            // Raising the app and designating the key window are both already done by this point.
            // The follow-up AX write is a just-in-case backup, but for slow-responding apps
            // Each call could block for up to 0.3 seconds, and two of those back to back were what made key presses feel sluggish.
            // No need to wait for the result, so run it off the main thread in the background
            let element = axElement
            DispatchQueue.global(qos: .userInitiated).async {
                AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
            return
        }

        // A fallback: the conventional approach.
        // NSRunningApplication.activate() only "brings the app to the front" — it doesn't control which window
        // which window it shows is left up to the app, so for apps with multiple windows an unintended one
        // Shows briefly. This path is only hit when the one above isn't usable
        AXUIElementSetAttributeValue(axElement, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)

        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }

        AXUIElementPerformAction(axElement, kAXRaiseAction as CFString)
    }

    /// The most recent result of setFrontProcessWithThisWindow() (recorded so we only log when it changes after launch)
    private static var lastSetFrontProcessResult: Bool?

    /// Activates the app and, at the same time, designates this window as the frontmost one
    /// - Returns: true on success. false if the private API is unavailable
    private func setFrontProcessWithThisWindow() -> Bool {
        let result = setFrontProcessWithThisWindowImpl()

        // Only log when the result differs from last time (logging on every pass after startup would be noisy)
        if PerfLog.enabled && Self.lastSetFrontProcessResult != result {
            Self.lastSetFrontProcessResult = result
            PerfLog.logf("setFrontProcessWithThisWindow: %@", result ? "成功（非公開API使用）" : "失敗（activate()にフォールバック）")
        }

        return result
    }

    /// The actual implementation of setFrontProcessWithThisWindow()
    private func setFrontProcessWithThisWindowImpl() -> Bool {
        guard let processForPID = FrontProcessAPI.processForPID,
              let setFrontProcess = FrontProcessAPI.setFrontProcess,
              FrontProcessAPI.postEventRecord != nil else {
            return false
        }

        var psn = ProcessSerialNumber()
        guard processForPID(app.processIdentifier, &psn) == noErr else { return false }

        // kCPSUserGenerated = 0x200 (makes it count as a user-initiated raise)
        guard setFrontProcess(&psn, id, 0x200) == .success else { return false }

        // Send the signal designating the target window as the key window (a pair of calls)
        postKeyWindowEvent(psn: &psn, marker: 0x01)
        postKeyWindowEvent(psn: &psn, marker: 0x02)
        return true
    }

    /// Send the signal to switch the key window
    private func postKeyWindowEvent(psn: UnsafeMutablePointer<ProcessSerialNumber>, marker: UInt8) {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x08] = marker
        bytes[0x3a] = 0x10

        // Fill 0x10 bytes starting at 0x20 with 0xff
        for offset in 0..<0x10 {
            bytes[0x20 + offset] = 0xff
        }

        // Embed the window ID at 0x3c
        var windowID = id
        withUnsafeBytes(of: &windowID) { raw in
            for offset in 0..<4 {
                bytes[0x3c + offset] = raw[offset]
            }
        }

        _ = FrontProcessAPI.postEventRecord?(psn, &bytes)
    }

    /// The interval between focus retries (in seconds)
    /// Right after activating an app, it tends to restore whichever window it remembers, so
    /// Do the first check as early as possible. Too slow and the window becomes visible, causing a flicker
    private static let focusRetryDelays: [TimeInterval] = [0.008, 0.016, 0.032, 0.064, 0.12]

    /// Confirm whether focus actually moved, and retry if it didn't
    /// - Parameter focusStart: For measurement. The time of the first focus() call
    private func verifyFocus(attempt: Int, focusStart: CFAbsoluteTime, claimedKeyPress: (label: String, start: CFAbsoluteTime)?) {
        guard attempt < Self.focusRetryDelays.count else {
            if PerfLog.enabled {
                let elapsed = CFAbsoluteTimeGetCurrent() - focusStart
                PerfLog.logf("WindowInfo.verifyFocus: 5回とも失敗 (%.1fms)", elapsed * 1000)
            }
            PerfLog.reportKeyPressToFocusConfirmed(claimedKeyPress)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusRetryDelays[attempt]) {
            // Do nothing if focus has already moved as intended
            if AccessibilityManager.shared.getFocusedWindowID() == self.id {
                if PerfLog.enabled {
                    let elapsed = CFAbsoluteTimeGetCurrent() - focusStart
                    PerfLog.logf("WindowInfo.verifyFocus: %d回目の確認で成功 (%.1fms)", attempt + 1, elapsed * 1000)
                }
                PerfLog.reportKeyPressToFocusConfirmed(claimedKeyPress)
                return
            }

            // Some apps don't respond to raising via AX, so also call activate() from the second attempt onward
            self.applyFocusOnce(useAppActivate: attempt >= 1)
            self.verifyFocus(attempt: attempt + 1, focusStart: focusStart, claimedKeyPress: claimedKeyPress)
        }
    }

    /// Raise the window to the front (without moving focus)
    /// Used to keep floating windows from getting hidden behind the tiles
    func raise() {
        AXUIElementPerformAction(axElement, kAXRaiseAction as CFString)
    }

    /// Update (re-fetch) the current frame
    mutating func refreshFrame() {
        self.frame = Self.getFrame(from: axElement) ?? .zero
    }
    
    // MARK: - Floating Detection (modeled on AeroSpace/Amethyst)
    
    /// Whether it should be managed as a tiling target
    func shouldBeManaged() -> Bool {
        // Exclude minimized windows
        if isMinimized {
            return false
        }

        // Exclude fullscreen windows
        if isFullscreen {
            return false
        }

        // A standard-window subrole → managed
        if subrole == kAXStandardWindowSubrole as String {
            return true
        }

        // Even with a non-standard subrole, treat it as a genuine window if it has a close button
        // (PowerPoint's document window etc. falls into this case)
        // Implementation modeled on AeroSpace's isWindowHeuristicOld()
        if hasCloseButton {
            return true
        }

        return false
    }
    
    /// Whether it should float (e.g. dialogs)
    func shouldFloat() -> Bool {
        // Dialogs float
        if subrole == kAXDialogSubrole as String {
            return true
        }
        
        // Floating windows float
        if subrole == kAXFloatingWindowSubrole as String {
            return true
        }
        
        // Small windows float (modeled on Amethyst)
        if frame.width < 500 && frame.height < 500 {
            return true
        }
        
        // Exclude specific apps (to be made configurable later)
        let floatingBundleIds = [
            "com.apple.systempreferences",
            "com.apple.SystemPreferences"
        ]
        
        if let bundleId = app.bundleIdentifier, floatingBundleIds.contains(bundleId) {
            return true
        }
        
        return false
    }
    
    // MARK: - Private Helpers
    
    private static func getString(from element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }
    
    private static func getBool(from element: AXUIElement, attribute: String) -> Bool? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }
    
    private static func getFrame(from element: AXUIElement) -> CGRect? {
        guard let position = getPosition(from: element),
              let size = getSize(from: element) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }
    
    private static func getPosition(from element: AXUIElement) -> CGPoint? {
        var positionRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef)
        guard result == .success, let positionValue = positionRef else { return nil }
        
        var position = CGPoint.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        return position
    }
    
    private static func getSize(from element: AXUIElement) -> CGSize? {
        var sizeRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
        guard result == .success, let sizeValue = sizeRef else { return nil }
        
        var size = CGSize.zero
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return size
    }
    
    private static func getSize(from element: AXUIElement, attribute: String) -> CGSize? {
        var sizeRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &sizeRef)
        guard result == .success, let sizeValue = sizeRef else { return nil }
        
        var size = CGSize.zero
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return size
    }
}

// MARK: - Private API Declaration

/// A private API for getting the Window ID
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// A set of private APIs for raising a process and designating which window to bring to the front, at the same time.
///
/// With NSRunningApplication.activate(), the app itself decides which window to show, and
/// For apps with multiple windows, an unintended one flashes on screen briefly. This is used to avoid that.
/// yabai and AeroSpace use the same API for the same reason.
///
/// These live in a private framework (SkyLight) and won't link normally.
/// So symbols are looked up at runtime instead. If a future macOS version stops exposing them,
/// It simply becomes nil, and the caller automatically falls back to the conventional activate() approach.
enum FrontProcessAPI {
    typealias SetFrontProcess = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    typealias PostEventRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    typealias ProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    /// Look up the symbol across all already-loaded libraries
    private static func lookup<T>(_ name: String, as type: T.Type) -> T? {
        let allLoaded = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        guard let symbol = dlsym(allLoaded, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    static let setFrontProcess = lookup("_SLPSSetFrontProcessWithOptions", as: SetFrontProcess.self)
    static let postEventRecord = lookup("SLPSPostEventRecordTo", as: PostEventRecord.self)
    static let processForPID = lookup("GetProcessForPID", as: ProcessForPID.self)

    /// Whether all three are present (fall back to the conventional approach if even one is missing)
    static var isAvailable: Bool {
        setFrontProcess != nil && postEventRecord != nil && processForPID != nil
    }
}
