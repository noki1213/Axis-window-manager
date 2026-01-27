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
    
    // MARK: - Event Monitor
    
    private var eventMonitor: Any?
    
    private let tilingEngine = TilingEngine.shared
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Start hotkey monitoring
    func start() {
        // Monitor global key events
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        
        // Also monitor local (in-app) key events
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleKeyEvent(event) == true {
                return nil // イベントを消費
            }
            return event
        }
    }
    
    /// Stop hotkey monitoring
    func stop() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
    
    // MARK: - Key Event Handling
    
    @discardableResult
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Return to normal mode with Escape
        if event.keyCode == kVK_Escape {
            if currentMode != .normal {
                currentMode = .normal
                return true
            }
            return false
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
            NotificationCenter.default.post(name: .modeChanged, object: currentMode)
            return true
            
        // MARK: Virtual Desktop (UO)
        case kVK_ANSI_U: // 左の仮想デスクトップ
            if hasShift {
                // Send the window to the desktop on the left (to be implemented in Phase 4)
            } else {
                // Move to the desktop on the left (to be implemented in Phase 4)
            }
            return true
            
        case kVK_ANSI_O: // 右の仮想デスクトップ
            if hasShift {
                // Send the window to the desktop on the right (to be implemented in Phase 4)
            } else {
                // Move to the desktop on the right (to be implemented in Phase 4)
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
}

// MARK: - Notification Names

extension Notification.Name {
    static let modeChanged = Notification.Name("modeChanged")
}
