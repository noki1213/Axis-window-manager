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
    
    /// Set the window's position and size
    /// Based on AeroSpace's implementation: set size, then position, then size again
    func setFrame(_ newFrame: CGRect) {
        // Disable animation (the technique used by AeroSpace/yabai/Rectangle)
        disableAnimations {
            // Set the size first (important: it won't be positioned correctly in any other order)
            setSize(newFrame.size)
            // Set the position
            setPosition(newFrame.origin)
            // Set the size again (needed for some apps)
            setSize(newFrame.size)
        }
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
            var pos = position
            let positionValue = AXValueCreate(.cgPoint, &pos)!
            AXUIElementSetAttributeValue(axElement, kAXPositionAttribute as CFString, positionValue)
        }
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
    func focus() {
        // First activate the app
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        
        // Bring the window to the front
        AXUIElementSetAttributeValue(axElement, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        
        // Raise the window to bring it to the front
        AXUIElementPerformAction(axElement, kAXRaiseAction as CFString)
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
