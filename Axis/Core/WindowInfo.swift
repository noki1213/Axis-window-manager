//
//  WindowInfo.swift
//  Axis
//
//  Created on 2026/01/27.
//

import AppKit
import ApplicationServices

/// A handle on a window for the features: its facts, focus, bringing it to the front. Moving,
/// resizing and minimizing windows go through the tracking state's plans.
struct WindowInfo: Identifiable, Equatable {
    let id: CGWindowID
    let axElement: AXUIElement
    let app: NSRunningApplication
    
    var title: String
    var frame: CGRect

    // The kind of window (standard window, dialog, floating panel, ...)
    var subrole: String?

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

        // Subrole
        self.subrole = Self.getString(from: axElement, attribute: kAXSubroleAttribute)

        // Whether it has a close button (used to detect windows like PowerPoint's with a non-standard subrole)
        var closeButtonRef: CFTypeRef?
        let closeResult = AXUIElementCopyAttributeValue(axElement, kAXCloseButtonAttribute as CFString, &closeButtonRef)
        self.hasCloseButton = (closeResult == .success && closeButtonRef != nil)
    }
    
    /// A handle built from facts already known about the window, without asking the app.
    init(facts: WindowFacts, element: AXUIElement, app: NSRunningApplication) {
        // Cached elements already carry this timeout; set again so a handle can never wait for the
        // system default (seconds) on an app that does not answer. Same value as the cache's, so
        // it does not shorten a call another thread has under way.
        AXUIElementSetMessagingTimeout(element, ElementCache.messagingTimeout)

        self.id = facts.id
        self.axElement = element
        self.app = app
        self.title = facts.title
        self.frame = facts.frame
        self.subrole = facts.subrole
        self.hasCloseButton = facts.hasCloseButton
    }

    /// Whether the window holds keyboard focus within its own app.
    /// Read live rather than cached at init: it changes on every click, with nothing about the window list
    /// changing along with it. A panel that can never become key reads false at all times
    var isFocusedInApp: Bool {
        Self.getBool(from: axElement, attribute: kAXFocusedAttribute) ?? false
    }

    // MARK: - Equatable

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id
    }
    
    // MARK: - Window Operations
    
    /// Set focus to the window
    /// Sometimes only the app activation takes effect and the window designation doesn't, in which case
    /// Focus falls back to another window that same app had just prior.
    /// So it reads back the focus state after setting it and retries if it doesn't match the target.
    func focus() {
        PerfLog.event("focus: -> \(PerfLog.describe(self))")

        let perfOverallStart = CFAbsoluteTimeGetCurrent()

        let perfSyncStart = perfOverallStart
        applyFocusOnce(useAppActivate: false)
        let perfSyncElapsed = CFAbsoluteTimeGetCurrent() - perfSyncStart
        if PerfLog.enabled && perfSyncElapsed >= 0.005 {
            PerfLog.logf("WindowInfo.focus() sync part: %.1fms", perfSyncElapsed * 1000)
        }

        // If this focus change came from a key press, pick up that record to measure end-to-end time
        let claimedKeyPress = PerfLog.claimKeyPress()
        verifyFocus(attempt: 0, focusStart: perfOverallStart, claimedKeyPress: claimedKeyPress)
    }

    /// The actual implementation of setting focus (a single attempt)
    /// - Parameter useAppActivate: whether to focus via the conventional activate() instead of the private API.
    ///   Set to true on retry, as a fallback for environments where the private API doesn't work
    /// - Returns: false when the app did not answer an AX call, so retrying would only wait for it again
    @discardableResult
    private func applyFocusOnce(useAppActivate: Bool) -> Bool {
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
            return true
        }

        // A fallback: the conventional approach.
        // NSRunningApplication.activate() only "brings the app to the front" — it doesn't control which window
        // which window it shows is left up to the app, so for apps with multiple windows an unintended one
        // Shows briefly. This path is only hit when the one above isn't usable
        // These run on the main thread, and an app that does not answer the first call will not answer
        // the next ones either: each would wait out the timeout, so the rest are skipped.
        var answered = AXUIElementSetAttributeValue(axElement, kAXMainAttribute as CFString, kCFBooleanTrue) != .cannotComplete
        if answered {
            answered = AXUIElementSetAttributeValue(axElement, kAXFocusedAttribute as CFString, kCFBooleanTrue) != .cannotComplete
        }

        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }

        if answered {
            answered = AXUIElementPerformAction(axElement, kAXRaiseAction as CFString) != .cannotComplete
        }
        return answered
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
            PerfLog.logf("setFrontProcessWithThisWindow: %@", result ? "succeeded (using private API)" : "failed (falling back to activate())")
        }

        return result
    }

    /// The actual implementation of setFrontProcessWithThisWindow()
    private func setFrontProcessWithThisWindowImpl() -> Bool {
        // kCPSUserGenerated = 0x200 (makes it count as a user-initiated raise)
        return setFrontProcess(options: 0x200)
    }

    /// Bring this window to the front by activating its app with all of its windows.
    /// Used for windows that reject kAXRaiseAction (System Settings answers it with attributeUnsupported);
    /// the private front-process call leaves such windows where they are, but a full activate reorders them.
    /// This moves focus to the app as well
    func activateBringingToFront() -> Bool {
        return app.activate(options: [.activateAllWindows])
    }

    /// Activate this window's process with the given kCPS* options and designate this window as the key window
    private func setFrontProcess(options: UInt32) -> Bool {
        guard let processForPID = FrontProcessAPI.processForPID,
              let setFrontProcess = FrontProcessAPI.setFrontProcess,
              FrontProcessAPI.postEventRecord != nil else {
            return false
        }

        var psn = ProcessSerialNumber()
        guard processForPID(app.processIdentifier, &psn) == noErr else { return false }

        guard setFrontProcess(&psn, id, options) == .success else { return false }

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

    /// The longest focus() goes on checking and retrying. This runs on the main thread, and every call
    /// to an app that does not answer waits out the messaging timeout, so a window of such an app
    /// must not keep the main thread busy for long (nothing else, like hiding the old workspace, runs meanwhile)
    private static let focusVerifyBudget: TimeInterval = 0.5

    /// With less of the budget left than this a read would only time out, so the check stops instead
    private static let minimumReadBudget: TimeInterval = 0.02

    /// Confirm whether focus actually moved, and retry if it didn't
    /// Stops at the end of the time budget, and right away once the app does not answer
    /// - Parameter focusStart: The time of the first focus() call. Also the start of the time budget
    private func verifyFocus(attempt: Int, focusStart: CFAbsoluteTime, claimedKeyPress: (label: String, start: CFAbsoluteTime)?) {
        func giveUp(_ reason: String) {
            if PerfLog.enabled {
                let elapsed = CFAbsoluteTimeGetCurrent() - focusStart
                PerfLog.logf("WindowInfo.verifyFocus: %@ (%.1fms)", reason, elapsed * 1000)
            }
            PerfLog.reportKeyPressToFocusConfirmed(claimedKeyPress)
        }

        guard attempt < Self.focusRetryDelays.count else {
            giveUp("all \(Self.focusRetryDelays.count) attempts failed")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusRetryDelays[attempt]) {
            // A read may not wait longer than what is left of the budget
            let remaining = Self.focusVerifyBudget - (CFAbsoluteTimeGetCurrent() - focusStart)
            guard remaining > Self.minimumReadBudget else {
                giveUp("gave up, no confirmation within the time budget")
                return
            }

            // Do nothing if focus has already moved as intended
            switch AccessibilityManager.shared.readFocusedWindowID(timeout: min(0.3, remaining)) {
            case .window(let focusedID) where focusedID == self.id:
                if PerfLog.enabled {
                    let elapsed = CFAbsoluteTimeGetCurrent() - focusStart
                    PerfLog.logf("WindowInfo.verifyFocus: succeeded on check %d (%.1fms)", attempt + 1, elapsed * 1000)
                }
                PerfLog.reportKeyPressToFocusConfirmed(claimedKeyPress)
                return
            case .timedOut:
                giveUp("gave up, the app did not answer")
                return
            case .window, .noWindow:
                break
            }

            // Some apps don't respond to raising via AX, so also call activate() from the second attempt onward
            guard self.applyFocusOnce(useAppActivate: attempt >= 1) else {
                giveUp("gave up, the app did not answer")
                return
            }
            self.verifyFocus(attempt: attempt + 1, focusStart: focusStart, claimedKeyPress: claimedKeyPress)
        }
    }

    /// Update (re-fetch) the current frame
    mutating func refreshFrame() {
        self.frame = Self.getFrame(from: axElement) ?? .zero
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

}

extension WindowInfo {
    /// The window's center in screen coordinates. Window frames come from
    /// Accessibility, with the origin at the top-left of the primary display;
    /// NSScreen frames put it at the bottom-left.
    var centerInScreenCoordinates: CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: frame.midX, y: primaryHeight - frame.midY)
    }

    /// The screen holding the window's center, or nil when the center is off
    /// every screen.
    var screen: NSScreen? {
        let center = centerInScreenCoordinates
        return NSScreen.screens.first { $0.frame.contains(center) }
    }
}
