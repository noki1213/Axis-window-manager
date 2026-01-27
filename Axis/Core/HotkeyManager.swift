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
    
    /// ctrl + option
    private let modifierMask: NSEvent.ModifierFlags = [.control, .option]
    
    // MARK: - Event Tap (low-level event monitoring; can block events)
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    private let tilingEngine = TilingEngine.shared
    private let windowSelectManager = WindowSelectManager.shared
    private let gapSelectManager = GapSelectManager.shared

    private init() {}
    
    // MARK: - Public Methods
    
    /// Start hotkey monitoring
    func start() {
        setupEventTap()
    }
    
    /// Stop hotkey monitoring
    func stop() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }
    
    // MARK: - Event Tap Setup
    
    private func setupEventTap() {
        // The event tap's callback
        let callback: CGEventTapCallBack = { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            guard let refcon = refcon else {
                return Unmanaged.passRetained(event)
            }
            
            let hotkeyManager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            
            // Re-enable the tap if it got disabled
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = hotkeyManager.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passRetained(event)
            }
            
            // Only handle key-down events
            guard type == .keyDown else {
                return Unmanaged.passRetained(event)
            }
            
            // Convert to NSEvent
            guard let nsEvent = NSEvent(cgEvent: event) else {
                return Unmanaged.passRetained(event)
            }
            
            // Handle the event and return nil if it should be consumed
            if hotkeyManager.handleKeyEvent(nsEvent) {
                return nil // イベントを消費（他のアプリに送らない）
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
    
    // MARK: - Key Event Handling
    
    @discardableResult
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Return to normal mode with Escape
        if event.keyCode == kVK_Escape {
            if currentMode == .gapSelect {
                gapSelectManager.endGapSelectMode()
                currentMode = .normal
                NotificationCenter.default.post(name: .modeChanged, object: currentMode)
                return true
            } else if currentMode != .normal {
                currentMode = .normal
                NotificationCenter.default.post(name: .modeChanged, object: currentMode)
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
        guard event.modifierFlags.contains(modifierMask) else {
            return false
        }
        
        let hasShift = event.modifierFlags.contains(.shift)
        
        // Branch handling based on the key code
        switch Int(event.keyCode) {
        // MARK: Focus / Move (JKLI)
        case kVK_ANSI_J: // 左
            if hasShift {
                tilingEngine.moveWindow(direction: .left)
            } else {
                tilingEngine.moveFocus(direction: .left)
            }
            return true
            
        case kVK_ANSI_L: // 右
            if hasShift {
                tilingEngine.moveWindow(direction: .right)
            } else {
                tilingEngine.moveFocus(direction: .right)
            }
            return true
            
        case kVK_ANSI_I: // 上
            if hasShift {
                tilingEngine.moveWindow(direction: .up)
            } else {
                tilingEngine.moveFocus(direction: .up)
            }
            return true
            
        case kVK_ANSI_K: // 下
            if hasShift {
                tilingEngine.moveWindow(direction: .down)
            } else {
                tilingEngine.moveFocus(direction: .down)
            }
            return true
            
        // MARK: Mode Switching
        case kVK_ANSI_S: // ウィンドウ選択モード
            currentMode = .windowSelect
            NotificationCenter.default.post(name: .modeChanged, object: currentMode)
            return true
            
        case kVK_ANSI_G: // ギャップ選択モード
            currentMode = .gapSelect
            gapSelectManager.startGapSelectMode()
            NotificationCenter.default.post(name: .modeChanged, object: currentMode)
            return true

        // MARK: Reset Layout
        case kVK_ANSI_R: // 全ウィンドウを縦分割に戻す
            tilingEngine.resetToSingleWindowColumns()
            return true

        // MARK: Virtual Desktop (UO)
        case kVK_ANSI_U: // 左の仮想デスクトップ
            if hasShift {
                // Send the window to the desktop on the left (to be implemented in Phase 4)
            } else {
                // Move to the desktop on the left
                switchToSpace(direction: .left)
            }
            return true

        case kVK_ANSI_O: // 右の仮想デスクトップ
            if hasShift {
                // Send the window to the desktop on the right (to be implemented in Phase 4)
            } else {
                // Move to the desktop on the right
                switchToSpace(direction: .right)
            }
            return true
            
        // MARK: Monitor Cursor (MQ)
        case kVK_ANSI_M, kVK_ANSI_Q: // Monitor間カーソル移動
            cycleMonitorCursor()
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
            windowSelectManager.toggleCurrentWindow()
            return true
        }

        // Backspace/Delete: clear selection
        if event.keyCode == kVK_Delete || event.keyCode == kVK_ForwardDelete {
            windowSelectManager.deselectCurrentWindow()
            return true
        }

        // V: merge the selected windows vertically
        if event.keyCode == kVK_ANSI_V {
            windowSelectManager.mergeSelectedWindowsVertically()
            return true
        }

        // JKLI handling (works with or without ctrl+option)
        switch Int(event.keyCode) {
        case kVK_ANSI_J: // 左
            if hasShift || (hasModifier && hasShift) {
                windowSelectManager.moveSelectedWindows(direction: .left)
            } else {
                tilingEngine.moveFocus(direction: .left)
            }
            return true

        case kVK_ANSI_L: // 右
            if hasShift || (hasModifier && hasShift) {
                windowSelectManager.moveSelectedWindows(direction: .right)
            } else {
                tilingEngine.moveFocus(direction: .right)
            }
            return true

        case kVK_ANSI_I: // 上
            if hasShift || (hasModifier && hasShift) {
                windowSelectManager.moveSelectedWindows(direction: .up)
            } else {
                tilingEngine.moveFocus(direction: .up)
            }
            return true

        case kVK_ANSI_K: // 下
            if hasShift || (hasModifier && hasShift) {
                windowSelectManager.moveSelectedWindows(direction: .down)
            } else {
                tilingEngine.moveFocus(direction: .down)
            }
            return true

        default:
            return false
        }
    }

    // MARK: - Gap Select Mode Key Handling

    /// Key handling in gap-selection mode
    private func handleGapSelectModeKeyEvent(_ event: NSEvent) -> Bool {
        let hasModifier = event.modifierFlags.contains(modifierMask)

        // Enter: select the gap / confirm the resize
        if event.keyCode == kVK_Return {
            gapSelectManager.selectCurrentGap()
            return true
        }

        // JKLI handling (works with or without ctrl+option)
        switch Int(event.keyCode) {
        case kVK_ANSI_J: // 左
            if gapSelectManager.state == .resizing {
                gapSelectManager.moveGap(direction: .left)
            } else {
                gapSelectManager.moveToNextGap(direction: .left)
            }
            return true

        case kVK_ANSI_L: // 右
            if gapSelectManager.state == .resizing {
                gapSelectManager.moveGap(direction: .right)
            } else {
                gapSelectManager.moveToNextGap(direction: .right)
            }
            return true

        case kVK_ANSI_I: // 上
            if gapSelectManager.state == .resizing {
                gapSelectManager.moveGap(direction: .up)
            } else {
                gapSelectManager.moveToNextGap(direction: .up)
            }
            return true

        case kVK_ANSI_K: // 下
            if gapSelectManager.state == .resizing {
                gapSelectManager.moveGap(direction: .down)
            } else {
                gapSelectManager.moveToNextGap(direction: .down)
            }
            return true

        default:
            return false
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let modeChanged = Notification.Name("modeChanged")
}
