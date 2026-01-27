//
//  BorderManager.swift
//  Axis
//
//  Created on 2026/01/27.
//

import AppKit
import Combine

class BorderManager: ObservableObject {
    static let shared = BorderManager()
    
    private var borderWindow: NSWindow?
    private var borderView: SelectionBorderView?
    private var currentWindow: WindowInfo?
    private var currentWindowID: CGWindowID?
    private var cancellables = Set<AnyCancellable>()
    private var updateTimer: Timer?
    
    // Settings
    private let padding: CGFloat = 10.0 // WindowSelectManagerと同じパディング
    
    private init() {
        setupNotifications()
        setupBorderWindow()
    }
    
    private func setupNotifications() {
        // ... (notifications remain same) ...
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in self?.updateBorder() }
            .store(in: &cancellables)
            
        NotificationCenter.default.publisher(for: Notification.Name("WindowMoved"))
            .sink { [weak self] _ in self?.updateBorder() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .modeChanged)
            .sink { [weak self] _ in self?.updateBorder() }
            .store(in: &cancellables)
            
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.checkWindowFrame()
        }
    }
    
    // Helper method that creates a window (called on demand rather than reused)
    private func createBorderWindow(for frame: CGRect) -> (NSWindow, SelectionBorderView) {
        let overlay = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.level = .floating
        overlay.ignoresMouseEvents = true
        overlay.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        overlay.isReleasedWhenClosed = false // 明示的に閉じるまで保持
        
        let view = SelectionBorderView(frame: overlay.contentView!.bounds)
        view.mainColor = .white // ノーマルモードは白
        view.showsFill = false // ノーマルモードは曇りなし！
        view.autoresizingMask = [.width, .height]
        overlay.contentView?.addSubview(view)
        
        return (overlay, view)
    }
    
    // Don't call setupBorderWindow during initialization (updateBorder creates it)
    private func setupBorderWindow() {
        // Do nothing, or remove it
    }

    func updateBorder() {
        guard let focusedWindow = AccessibilityManager.shared.getFocusedWindow() else {
            hideBorder()
            return
        }
        
        if WindowSelectManager.shared.isActive || GapSelectManager.shared.isActive {
            hideBorder()
            return
        }
        
        let windowChanged = (currentWindowID != focusedWindow.id)
        let targetRect = calculateBorderRect(for: focusedWindow.frame)
        
        self.currentWindow = focusedWindow
        self.currentWindowID = focusedWindow.id
        
        if windowChanged {
            // If the window changed: discard the old one and create a new one!
            borderWindow?.close()
            borderWindow = nil
            borderView = nil
            
            let (newWindow, newView) = createBorderWindow(for: targetRect)
            self.borderWindow = newWindow
            self.borderView = newView
            
            // Show it with a slight delay (matching WindowSelectManager's behavior)
            DispatchQueue.main.async {
                newWindow.orderFront(nil)
            }
        } else {
            // If it's the same window: update position only (don't recreate it, to avoid flicker)
            borderWindow?.setFrame(targetRect, display: true)
            borderWindow?.orderFront(nil)
        }
    }
    
    // (triggerFlashAnimation method is no longer called and can be removed or ignored)
    
    private func checkWindowFrame() {
        guard let currentWindow = currentWindow,
              let borderWindow = borderWindow,
              borderWindow.isVisible else { return }
        
        var position: CFTypeRef?
        var size: CFTypeRef?
        
        let axElement = currentWindow.axElement
        
        AXUIElementCopyAttributeValue(axElement, kAXPositionAttribute as CFString, &position)
        AXUIElementCopyAttributeValue(axElement, kAXSizeAttribute as CFString, &size)
        
        if let pos = position as? CGPoint, let sz = size as? CGSize {
            let newFrame = CGRect(origin: pos, size: sz)
            let expectedBorderRect = calculateBorderRect(for: newFrame)
            
            // Correct any positional drift (applied immediately)
            if abs(borderWindow.frame.origin.x - expectedBorderRect.origin.x) > 1 ||
               abs(borderWindow.frame.origin.y - expectedBorderRect.origin.y) > 1 ||
               abs(borderWindow.frame.width - expectedBorderRect.width) > 1 ||
               abs(borderWindow.frame.height - expectedBorderRect.height) > 1 {
                
                borderWindow.setFrame(expectedBorderRect, display: true)
                borderView?.frame = NSRect(origin: .zero, size: expectedBorderRect.size)
            }
        }
    }
    
    private func calculateBorderRect(for windowFrame: CGRect) -> CGRect {
        // Convert Accessibility coordinates (top-left origin) to Cocoa coordinates (bottom-left origin)
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let nsWindowY = mainScreenHeight - windowFrame.origin.y - windowFrame.height
        
        return CGRect(
            x: windowFrame.origin.x - padding,
            y: nsWindowY - padding,
            width: windowFrame.width + (padding * 2),
            height: windowFrame.height + (padding * 2)
        )
    }
    
    /// Trigger the "glow and fade out" animation
    private func triggerFlashAnimation() {
        guard let borderView = borderView else { return }
        
        // Initial state: the fill is visible
        borderView.fillColor = NSColor.white.withAlphaComponent(0.15)
        
        // Fade the fill out over 0.8 seconds (for a slower, softer fade)
        let steps = 40 // ステップ数を増やしてより滑らかに
        let duration = 0.8 // 0.5秒から0.8秒に延長
        let interval = duration / Double(steps)
        let startAlpha: CGFloat = 0.15
        
        var currentStep = 0
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            currentStep += 1
            let progress = CGFloat(currentStep) / CGFloat(steps)
            let newAlpha = startAlpha * (1.0 - progress)
            
            borderView.fillColor = NSColor.white.withAlphaComponent(newAlpha)
            
            if currentStep >= steps {
                timer.invalidate()
                borderView.fillColor = .clear
            }
        }
    }
    
    func hideBorder() {
        borderWindow?.orderOut(nil)
        currentWindow = nil
        currentWindowID = nil
    }
}
