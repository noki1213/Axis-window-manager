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
        case windowSwitcher = "Window Switcher"
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
    private let windowSwitcherManager = WindowSwitcherManager.shared

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
            if currentMode == .windowSwitcher {
                DispatchQueue.main.async { [weak self] in
                    self?.windowSwitcherManager.endSwitcher()
                    self?.currentMode = .normal
                    NotificationCenter.default.post(name: .modeChanged, object: self?.currentMode)
                }
                return true
            } else if currentMode == .gapSelect {
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

        // Special key handling in window switcher mode
        if currentMode == .windowSwitcher {
            return handleWindowSwitcherModeKeyEvent(event)
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
            
        // MARK: Focus Mode
        case kVK_ANSI_F:
            DispatchQueue.main.async {
                FocusModeManager.shared.toggle()
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

        // MARK: Window Switcher (W)
        case kVK_ANSI_W: // ウィンドウスイッチャーモード
            DispatchQueue.main.async { [weak self] in
                self?.currentMode = .windowSwitcher
                self?.windowSwitcherManager.startSwitcher()
                NotificationCenter.default.post(name: .modeChanged, object: self?.currentMode)
            }
            return true

        // MARK: Reset Layout
        case kVK_ANSI_R: // 全ウィンドウを縦分割に戻す
            DispatchQueue.main.async { [weak self] in
                self?.tilingEngine.resetToSingleWindowColumns()
                // Update the border after reset (move it to the newly focused window)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    BorderManager.shared.updateBorder()
                }
            }
            return true

            
        // MARK: Monitor Cursor (MQ)
        case kVK_ANSI_M, kVK_ANSI_Q: // Monitor間カーソル移動
            DispatchQueue.main.async { [weak self] in
                self?.cycleMonitorCursor()
            }
            return true
            
        // MARK: Workspace Switching (O / U)
        case kVK_ANSI_O: // 次のワークスペース（+1）/ Shift で移動
            DispatchQueue.main.async {
                guard let screen = WorkspaceManager.shared.focusedScreen() else { return }
                if hasShift {
                    // Move the focused window to the next workspace
                    WorkspaceManager.shared.moveWindowToNextWorkspace(on: screen)
                } else {
                    // Switch to the next workspace
                    WorkspaceManager.shared.switchToNextWorkspace(on: screen)
                }
            }
            return true

        case kVK_ANSI_U: // 前のワークスペース（-1）/ Shift で移動
            DispatchQueue.main.async {
                guard let screen = WorkspaceManager.shared.focusedScreen() else { return }
                if hasShift {
                    // Move the focused window to the previous workspace
                    WorkspaceManager.shared.moveWindowToPreviousWorkspace(on: screen)
                } else {
                    // Switch to the previous workspace
                    WorkspaceManager.shared.switchToPreviousWorkspace(on: screen)
                }
            }
            return true

        // MARK: Window Resize (- / =)
        case kVK_ANSI_Minus: // ウィンドウを縮小
            DispatchQueue.main.async { [weak self] in
                self?.tilingEngine.resizeCurrentWindow(increase: false)
            }
            return true
            
        case kVK_ANSI_Equal: // ウィンドウを拡大（=キーはShift押すと+になる）
            DispatchQueue.main.async { [weak self] in
                self?.tilingEngine.resizeCurrentWindow(increase: true)
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

    // MARK: - Window Switcher Mode Key Handling

    /// Key handling in window switcher mode
    private func handleWindowSwitcherModeKeyEvent(_ event: NSEvent) -> Bool {
        // Enter: confirm the selection (automatically returns to normal mode afterward)
        if event.keyCode == kVK_Return {
            DispatchQueue.main.async { [weak self] in
                self?.windowSwitcherManager.confirmSelection()
            }
            return true
        }

        switch Int(event.keyCode) {
        case kVK_ANSI_I: // 上に移動（前のワークスペースへ）
            DispatchQueue.main.async { [weak self] in
                self?.windowSwitcherManager.moveUp()
            }
            return true

        case kVK_ANSI_K: // 下に移動（次のワークスペースへ）
            DispatchQueue.main.async { [weak self] in
                self?.windowSwitcherManager.moveDown()
            }
            return true

        case kVK_ANSI_J: // 左に移動（前のウィンドウへ）
            DispatchQueue.main.async { [weak self] in
                self?.windowSwitcherManager.moveLeft()
            }
            return true

        case kVK_ANSI_L: // 右に移動（次のウィンドウへ）
            DispatchQueue.main.async { [weak self] in
                self?.windowSwitcherManager.moveRight()
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
