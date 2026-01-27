//
//  HotkeyManager.swift
//  Axis
//
//  Created on 2026/01/27.
//

import AppKit
import Carbon
import Combine

/// Handles global hotkey management
class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()
    
    // MARK: - Mode
    
    enum Mode: String {
        case normal = "Normal"
        case windowSelect = "Window Select"
        case gapSelect = "Gap Select"
    }
    
    @Published var currentMode: Mode = .normal
    
    // MARK: - Modifier Keys
    
    /// ctrl + option (for CGEventFlags)
    private let requiredFlags: CGEventFlags = [.maskControl, .maskAlternate]
    
    /// ctrl + option (for NSEvent.ModifierFlags)
    private let modifierMask: NSEvent.ModifierFlags = [.control, .option]
    
    // MARK: - Event Tap (low-level event monitoring)
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    // For periodic health checks
    private var heartbeatTimer: Timer?
    
    private let tilingEngine = TilingEngine.shared
    private let windowSelectManager = WindowSelectManager.shared
    private let gapSelectManager = GapSelectManager.shared

    private init() {}
    
    // MARK: - Public Methods
    
    /// Start hotkey monitoring
    func start() {
        setupEventTap()
        startHeartbeat()
    }
    
    /// Stop hotkey monitoring
    func stop() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        destroyEventTap()
    }
    
    /// Force a restart (for calling from the menu, etc.)
    func restart() {
        stop()
        start()
    }
    
    // MARK: - Event Tap Setup
    
    private func setupEventTap() {
        // Do nothing if it already exists (or recreate it)
        if eventTap != nil { return }

            // The event tap's callback
        let callback: CGEventTapCallBack = { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            guard let refcon = refcon else {
                return Unmanaged.passUnretained(event)
            }
            
            let hotkeyManager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            
            // Try to re-enable the tap if it got disabled
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                print("[Axis] Event tap disabled by system (type: \(type.rawValue)). Re-enabling...")
                
                // Re-enable it immediately
                if let tap = hotkeyManager.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }
            
            // Only handle key-down events
            guard type == .keyDown else {
                return Unmanaged.passUnretained(event)
            }
            
            // Filter according to the processing mode
            // In normal mode Ctrl + Option is required, so anything else passes through immediately (for efficiency)
            if hotkeyManager.currentMode == .normal {
                let flags = event.flags
                // Ignore unless both .maskControl and .maskAlternate are present
                // Note: check with a bitwise operation: (flags & required) == required
                if !flags.contains(hotkeyManager.requiredFlags) {
                    return Unmanaged.passUnretained(event)
                }
            }
            
            // From here on it might be relevant, so convert to NSEvent for a detailed check
            // Note: NSEvent conversion is expensive, so do it after the filtering above
            guard let nsEvent = NSEvent(cgEvent: event) else {
                return Unmanaged.passUnretained(event)
            }
            
            // Handle the event and return nil if it should be consumed
            if hotkeyManager.handleKeyEvent(nsEvent) {
                return nil // イベントを消費
            }
            
            return Unmanaged.passRetained(event)
        }
        
        // Create the event tap
        let eventMask = (1 << CGEventType.keyDown.rawValue)
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[Axis] Failed to create event tap. Make sure Accessibility permission is granted.")
            return
        }
        
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            print("[Axis] Event tap started successfully")
        }
    }
    
    private func destroyEventTap() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Heartbeat (Self-Healing)
    
    /// Periodically check whether the Event Tap is alive, and revive it if it's dead
    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkEventTapHealth()
        }
    }
    
    private func checkEventTapHealth() {
        guard let tap = eventTap else {
            // Recreate it if nil
            print("[Axis] Heartbeat: Event tap is missing. Restarting...")
            setupEventTap()
            return
        }
        
        // Check whether the tap is enabled
        if !CGEvent.tapIsEnabled(tap: tap) {
            print("[Axis] Heartbeat: Event tap is disabled. Re-enabling...")
            CGEvent.tapEnable(tap: tap, enable: true)
            
            // Recreate it if that still doesn't work
            if !CGEvent.tapIsEnabled(tap: tap) {
                print("[Axis] Heartbeat: Failed to re-enable. Recreating...")
                stop()
                start()
            }
        }
    }
    
    // MARK: - Key Event Handling
    
    @discardableResult
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Return to normal mode with Escape
        if event.keyCode == kVK_Escape {
            if currentMode == .gapSelect {
                DispatchQueue.main.async { [weak self] in
                    self?.gapSelectManager.endGapSelectMode()
                    self?.currentMode = .normal
                    NotificationCenter.default.post(name: .modeChanged, object: self?.currentMode)
                }
                return true
            } else if currentMode != .normal {
                DispatchQueue.main.async { [weak self] in
                    self?.currentMode = .normal
                    NotificationCenter.default.post(name: .modeChanged, object: self?.currentMode)
                }
                return true
            }
            return false
        }
        
        // Special key handling in window-selection mode
        if currentMode == .windowSelect {
            return handleWindowSelectModeKeyEvent(event)
        }

        // Special key handling while in gap selection mode
        if currentMode == .gapSelect {
            return handleGapSelectModeKeyEvent(event)
        }

        // Check whether ctrl+option is held down
        // (Already filtered on the EventTap side, but check again here just in case)
        guard event.modifierFlags.contains(modifierMask) else {
            return false
        }
        
        let hasShift = event.modifierFlags.contains(.shift)
        
        // Branch handling based on the key code
        switch Int(event.keyCode) {
        // MARK: Focus / Move (JKLI)
        case kVK_ANSI_J: // 左
            DispatchQueue.main.async { [weak self] in
                if hasShift {
                    self?.tilingEngine.moveWindow(direction: .left)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        BorderManager.shared.updateBorder()
                    }
                } else {
                    self?.tilingEngine.moveFocus(direction: .left)
                    // Briefly show the border at the destination even in normal mode
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        BorderManager.shared.updateBorder()
                    }
                }
            }
            return true
            
        case kVK_ANSI_L: // 右
            DispatchQueue.main.async { [weak self] in
                if hasShift {
                    self?.tilingEngine.moveWindow(direction: .right)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        BorderManager.shared.updateBorder()
                    }
                } else {
                    self?.tilingEngine.moveFocus(direction: .right)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        BorderManager.shared.updateBorder()
                    }
                }
            }
            return true
            
        case kVK_ANSI_I: // 上
            DispatchQueue.main.async { [weak self] in
                if hasShift {
                    self?.tilingEngine.moveWindow(direction: .up)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        BorderManager.shared.updateBorder()
                    }
                } else {
                    self?.tilingEngine.moveFocus(direction: .up)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        BorderManager.shared.updateBorder()
                    }
                }
            }
            return true
            
        case kVK_ANSI_K: // 下
            DispatchQueue.main.async { [weak self] in
                if hasShift {
                    self?.tilingEngine.moveWindow(direction: .down)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        BorderManager.shared.updateBorder()
                    }
                } else {
                    self?.tilingEngine.moveFocus(direction: .down)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        BorderManager.shared.updateBorder()
                    }
                }
            }
            return true
            
        // MARK: Mode Switching
        case kVK_ANSI_S: // ウィンドウ選択モード
            DispatchQueue.main.async { [weak self] in
                self?.currentMode = .windowSelect
                NotificationCenter.default.post(name: .modeChanged, object: self?.currentMode)
            }
            return true
            
        case kVK_ANSI_G: // ギャップ選択モード
            DispatchQueue.main.async { [weak self] in
                self?.currentMode = .gapSelect
                self?.gapSelectManager.startGapSelectMode()
                NotificationCenter.default.post(name: .modeChanged, object: self?.currentMode)
            }
            return true

        // MARK: Reset Layout
        case kVK_ANSI_R: // 全ウィンドウを縦分割に戻す
            DispatchQueue.main.async { [weak self] in
                self?.tilingEngine.resetToSingleWindowColumns()
            }
            return true

        // MARK: Virtual Desktop (UO)
        case kVK_ANSI_U: // 左の仮想デスクトップ
            DispatchQueue.main.async { [weak self] in
                if hasShift {
                    // Send the window to the desktop on the left (to be implemented in Phase 4)
                } else {
                    // Move to the desktop on the left
                    self?.switchToSpace(direction: .left)
                }
            }
            return true

        case kVK_ANSI_O: // 右の仮想デスクトップ
            DispatchQueue.main.async { [weak self] in
                if hasShift {
                    // Send the window to the desktop on the right (to be implemented in Phase 4)
                } else {
                    // Move to the desktop on the right
                    self?.switchToSpace(direction: .right)
                }
            }
            return true
            
        // MARK: Monitor Cursor (MQ)
        case kVK_ANSI_M, kVK_ANSI_Q: // Monitor間カーソル移動
            DispatchQueue.main.async { [weak self] in
                self?.cycleMonitorCursor()
            }
            return true
            
        default:
            return false
        }
    }
    
    // MARK: - Monitor Cursor

    /// Move the cursor to the next monitor
    private func cycleMonitorCursor() {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return }

        let currentLocation = NSEvent.mouseLocation

        // Identify the current screen
        guard let currentScreenIndex = screens.firstIndex(where: { $0.frame.contains(currentLocation) }) else {
            return
        }

        // Next screen (cycles)
        let nextIndex = (currentScreenIndex + 1) % screens.count
        let nextScreen = screens[nextIndex]

        // Move the cursor to the center of the next screen
        let centerX = nextScreen.frame.midX
        let centerY = nextScreen.frame.midY

        // Convert since CGWarpMouseCursorPosition uses a top-left origin
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let warpY = mainScreenHeight - centerY

        CGWarpMouseCursorPosition(CGPoint(x: centerX, y: warpY))
    }

    // MARK: - Virtual Desktop (Space) Switching

    enum SpaceDirection {
        case left
        case right
    }

    /// Switch the virtual desktop (Space)
    /// Send ctrl+arrow key using CGEvent
    private func switchToSpace(direction: SpaceDirection) {
        print("[Axis] switchToSpace: direction=\(direction)")

        // Arrow key key codes
        let arrowKeyCode: CGKeyCode
        switch direction {
        case .left:
            arrowKeyCode = CGKeyCode(kVK_LeftArrow)
        case .right:
            arrowKeyCode = CGKeyCode(kVK_RightArrow)
        }

        // Create the event source
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            print("[Axis] switchToSpace: Failed to create event source")
            return
        }

        // Create a key-down event for ctrl+arrow key
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: arrowKeyCode, keyDown: true) else {
            print("[Axis] switchToSpace: Failed to create keyDown event")
            return
        }
        keyDown.flags = .maskControl

        // Create the key-up event
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: arrowKeyCode, keyDown: false) else {
            print("[Axis] switchToSpace: Failed to create keyUp event")
            return
        }
        keyUp.flags = .maskControl

        // Post the event (using cgAnnotatedSessionEventTap)
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)

        print("[Axis] switchToSpace: completed")
    }
    
    // MARK: - Window Select Mode Key Handling
    
    /// Key handling in window-selection mode
    private func handleWindowSelectModeKeyEvent(_ event: NSEvent) -> Bool {
        let hasModifier = event.modifierFlags.contains(modifierMask)
        let hasShift = event.modifierFlags.contains(.shift)
        
        // Enter: select/deselect the window (toggle)
        if event.keyCode == kVK_Return {
            DispatchQueue.main.async { [weak self] in
                self?.windowSelectManager.toggleCurrentWindow()
            }
            return true
        }

        // Backspace/Delete: clear selection
        if event.keyCode == kVK_Delete || event.keyCode == kVK_ForwardDelete {
            DispatchQueue.main.async { [weak self] in
                self?.windowSelectManager.deselectCurrentWindow()
            }
            return true
        }

        // V: merge the selected windows vertically (into one column)
        // Shift+V: split the selected windows' column back into individual columns
        if event.keyCode == kVK_ANSI_V {
            DispatchQueue.main.async { [weak self] in
                if hasShift {
                    self?.windowSelectManager.splitSelectedWindowsToColumns()
                } else {
                    self?.windowSelectManager.mergeSelectedWindowsVertically()
                }
            }
            return true
        }

        // JKLI handling (works with or without ctrl+option)
        switch Int(event.keyCode) {
        case kVK_ANSI_J: // 左
            DispatchQueue.main.async { [weak self] in
                if hasShift || (hasModifier && hasShift) {
                    self?.windowSelectManager.moveSelectedWindows(direction: .left)
                } else {
                    self?.tilingEngine.moveFocus(direction: .left)
                    // Update the overlay after focus moves (with a slight delay)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self?.windowSelectManager.updateOverlays()
                    }
                }
            }
            return true

        case kVK_ANSI_L: // 右
            DispatchQueue.main.async { [weak self] in
                if hasShift || (hasModifier && hasShift) {
                    self?.windowSelectManager.moveSelectedWindows(direction: .right)
                } else {
                    self?.tilingEngine.moveFocus(direction: .right)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self?.windowSelectManager.updateOverlays()
                    }
                }
            }
            return true

        case kVK_ANSI_I: // 上
            DispatchQueue.main.async { [weak self] in
                if hasShift || (hasModifier && hasShift) {
                    self?.windowSelectManager.moveSelectedWindows(direction: .up)
                } else {
                    self?.tilingEngine.moveFocus(direction: .up)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self?.windowSelectManager.updateOverlays()
                    }
                }
            }
            return true

        case kVK_ANSI_K: // 下
            DispatchQueue.main.async { [weak self] in
                if hasShift || (hasModifier && hasShift) {
                    self?.windowSelectManager.moveSelectedWindows(direction: .down)
                } else {
                    self?.tilingEngine.moveFocus(direction: .down)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self?.windowSelectManager.updateOverlays()
                    }
                }
            }
            return true

        default:
            // Block every key while in this mode (don't pass them to the app)
            return true
        }
    }

    // MARK: - Gap Select Mode Key Handling

    /// Key handling in gap-selection mode
    private func handleGapSelectModeKeyEvent(_ event: NSEvent) -> Bool {
        // Enter: select the gap / confirm the resize
        if event.keyCode == kVK_Return {
            DispatchQueue.main.async { [weak self] in
                self?.gapSelectManager.selectCurrentGap()
            }
            return true
        }

        // JKLI handling (works with or without ctrl+option)
        switch Int(event.keyCode) {
        case kVK_ANSI_J: // 左
            DispatchQueue.main.async { [weak self] in
                if self?.gapSelectManager.state == .resizing {
                    self?.gapSelectManager.moveGap(direction: .left)
                } else {
                    self?.gapSelectManager.moveToNextGap(direction: .left)
                }
            }
            return true

        case kVK_ANSI_L: // 右
            DispatchQueue.main.async { [weak self] in
                if self?.gapSelectManager.state == .resizing {
                    self?.gapSelectManager.moveGap(direction: .right)
                } else {
                    self?.gapSelectManager.moveToNextGap(direction: .right)
                }
            }
            return true

        case kVK_ANSI_I: // 上
            DispatchQueue.main.async { [weak self] in
                if self?.gapSelectManager.state == .resizing {
                    self?.gapSelectManager.moveGap(direction: .up)
                } else {
                    self?.gapSelectManager.moveToNextGap(direction: .up)
                }
            }
            return true

        case kVK_ANSI_K: // 下
            DispatchQueue.main.async { [weak self] in
                if self?.gapSelectManager.state == .resizing {
                    self?.gapSelectManager.moveGap(direction: .down)
                } else {
                    self?.gapSelectManager.moveToNextGap(direction: .down)
                }
            }
            return true

        default:
            // Block every key while in this mode (don't pass them to the app)
            return true
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let modeChanged = Notification.Name("modeChanged")
}
