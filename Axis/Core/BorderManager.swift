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

    private var isUpdating = false // 競合状態防止フラグ
    private var pendingUpdate = false // 更新中に新しいリクエストが来たかどうか
    private(set) var isInMissionControl = false // ミッションコントロール表示中フラグ（外部からは読み取りのみ）

    // Settings
    private let padding: CGFloat = 10.0 // 枠線のパディング

    /// Apps that don't get a border.
    /// Windows that appear only briefly, like a launcher, are distracting with a border on them, and moreover
    /// Also excluded because it flickers while the border returns to the original window right after a close.
    private let borderExcludedBundleIds: Set<String> = [
        "com.noki.TextToClipboard"
    ]

    /// Whether the border is currently hidden because of an excluded app.
    /// Even when an excluded app closes, the notification telling us focus returned to the original window
    /// can fail to arrive, so while this flag is set, a watchdog timer watches for the return instead
    private var hiddenForExcludedApp = false

    /// Whether to draw the border dashed. Since the border window is recreated on every focus move,
    /// State is held here and reflected in the view both at creation and on switches
    private var isDashed = false

    /// Toggle the border's dashed display (dashed only while waiting for a placement reservation)
    func setDashed(_ dashed: Bool) {
        guard isDashed != dashed else { return }
        isDashed = dashed
        borderView?.isDashed = dashed
    }

    private init() {
        setupNotifications()
        setupMissionControlObserver()
        setupBorderWindow()
    }
    
    private func setupNotifications() {
        // Receive all notifications on the main thread to serialize them
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleUpdateBorder() }
            .store(in: &cancellables)
            
        NotificationCenter.default.publisher(for: Notification.Name("WindowMoved"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleUpdateBorder() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .modeChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleUpdateBorder() }
            .store(in: &cancellables)
            
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.checkWindowFrame()
        }
    }
    
    /// Schedule an update (to prevent races)
    private func scheduleUpdateBorder() {
        if isUpdating {
            pendingUpdate = true
            return
        }
        performUpdateBorder()
    }
    
    private func performUpdateBorder() {
        isUpdating = true
        updateBorder()
        isUpdating = false
        
        // If a new request comes in during an update, update again
        if pendingUpdate {
            pendingUpdate = false
            performUpdateBorder()
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
        view.isDashed = isDashed // 待ち受け中に枠線が作り直されても点線のままにする
        view.autoresizingMask = [.width, .height]
        overlay.contentView?.addSubview(view)
        
        return (overlay, view)
    }
    
    // Don't call setupBorderWindow during initialization (updateBorder creates it)
    private func setupBorderWindow() {
        // Do nothing, or remove it
    }

    /// Watch for Mission Control (Exposé) starting and ending
    private func setupMissionControlObserver() {
        // Because notification-based detection doesn't work on newer macOS versions,
        // Detect Mission Control inside checkWindowFrame()
    }

    /// Check whether Mission Control is currently showing
    private func checkMissionControlActive() -> Bool {
        // Check the Dock process's windows
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []

        for window in windowList {
            guard let ownerName = window[kCGWindowOwnerName as String] as? String,
                  ownerName == "Dock" else { continue }

            // Check Mission Control's window name
            if let windowName = window[kCGWindowName as String] as? String {
                if windowName.contains("Mission Control") ||
                   windowName.contains("Exposé") ||
                   windowName.contains("Expose") {
                    return true
                }
            }

            // A Dock layer of 18 or higher means Mission Control is showing
            // Normally the Dock's only window is at layer=-2147483624 (the wallpaper layer)
            if let layer = window[kCGWindowLayer as String] as? Int, layer >= 18 {
                return true
            }
        }
        return false
    }

    /// After a focus move, retry until focus actually reaches the target window, then update the border
    /// Works around macOS sometimes taking a while to update focus state
    func updateBorderExpecting(windowID: CGWindowID, retryCount: Int = 0) {
        let focused = AccessibilityManager.shared.getFocusedWindow()

        if focused?.id != windowID, retryCount < 6 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.updateBorderExpecting(windowID: windowID, retryCount: retryCount + 1)
            }
            return
        }

        scheduleUpdateBorder()
    }

    func updateBorder() {
        // Don't show the border while Mission Control is active
        if isInMissionControl {
            return
        }

        guard let focusedWindow = AccessibilityManager.shared.getFocusedWindow() else {
            hideBorder()
            return
        }

        if GapSelectManager.shared.isActive {
            hideBorder()
            return
        }

        // Don't show the border on windows of excluded apps
        if let bundleId = focusedWindow.app.bundleIdentifier,
           borderExcludedBundleIds.contains(bundleId) {
            hideBorder()
            hiddenForExcludedApp = true
            return
        }

        hiddenForExcludedApp = false

        // Don't show the border on windows evacuated to another workspace or while the palette is showing
        if WorkspaceManager.shared.isWindowHidden(focusedWindow.id) ||
           WindowPaletteManager.shared.isWindowHidden(focusedWindow.id) {
            hideBorder()
            return
        }
        
        let windowChanged = (currentWindowID != focusedWindow.id)
        let targetRect = calculateBorderRect(for: focusedWindow.frame)

        self.currentWindow = focusedWindow
        self.currentWindowID = focusedWindow.id

        if windowChanged {
            // The focused window changed = it left the empty monitor
            TilingEngine.shared.cursorScreen = nil
            // If the window changed: make sure to remove the old one before creating a new one!
            if let oldWindow = borderWindow {
                oldWindow.close()
            }
            borderWindow = nil
            borderView = nil
            
            let (newWindow, newView) = createBorderWindow(for: targetRect)
            self.borderWindow = newWindow
            self.borderView = newView
            
            // Show it synchronously (doing it async causes a race condition where two get shown)
            newWindow.orderFront(nil)
        } else {
            // If it's the same window
            if borderWindow == nil {
                // Recreate it if we return to the same window after hideBorder() removed it
                let (newWindow, newView) = createBorderWindow(for: targetRect)
                self.borderWindow = newWindow
                self.borderView = newView
                newWindow.orderFront(nil)
            } else {
                // Update position only (don't recreate it, to avoid flicker)
                borderWindow?.setFrame(targetRect, display: true)
                borderWindow?.orderFront(nil)
            }
        }
    }
    
    // (triggerFlashAnimation method is no longer called and can be removed or ignored)
    
    private func checkWindowFrame() {
        // Check Mission Control's state
        let missionControlActive = checkMissionControlActive()

        if missionControlActive != isInMissionControl {
            isInMissionControl = missionControlActive
            if isInMissionControl {
                // Mission Control starts → hide the border
                borderWindow?.orderOut(nil)
                return
            } else {
                // Mission Control ends → show the border again
                borderWindow?.orderFront(nil)
            }
        }

        // Don't update while Mission Control is active
        if isInMissionControl { return }

        // While the border is hidden because of an excluded app, watch for the frontmost app changing.
        // Right after an excluded app closes, the notification sometimes doesn't arrive, so the border wouldn't come back on its own
        if hiddenForExcludedApp {
            let frontBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if frontBundleId == nil || !borderExcludedBundleIds.contains(frontBundleId!) {
                hiddenForExcludedApp = false
                scheduleUpdateBorder()
            }
            return
        }

        guard let currentWindow = currentWindow,
              let borderWindow = borderWindow,
              borderWindow.isVisible else { return }

        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?

        let axElement = currentWindow.axElement

        AXUIElementCopyAttributeValue(axElement, kAXPositionAttribute as CFString, &positionRef)
        AXUIElementCopyAttributeValue(axElement, kAXSizeAttribute as CFString, &sizeRef)

        // Extract the value from AXValue (can't cast directly)
        guard let posValue = positionRef, let szValue = sizeRef else { return }

        var position = CGPoint.zero
        var size = CGSize.zero

        AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(szValue as! AXValue, .cgSize, &size)

        let newFrame = CGRect(origin: position, size: size)
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
        // Make sure the window is destroyed (guards against a bug where two get shown)
        if let oldWindow = borderWindow {
            oldWindow.close()
        }
        borderWindow = nil
        borderView = nil
        currentWindow = nil
        currentWindowID = nil
    }
}

// MARK: - Selection Border View

/// The view that draws the border around the focused window
class SelectionBorderView: NSView {

    var showsFill: Bool = true {
        didSet { self.setNeedsDisplay(bounds) }
    }

    var borderColor: NSColor = .white {
        didSet { self.setNeedsDisplay(bounds) }
    }

    var fillColor: NSColor = NSColor.white.withAlphaComponent(0.15) {
        didSet { self.setNeedsDisplay(bounds) }
    }

    /// Whether to draw the border dashed (set true only while waiting for a placement reservation, as the signal that the mode was entered)
    var isDashed: Bool = false {
        didSet { self.setNeedsDisplay(bounds) }
    }

    /// For compatibility with the older interface (setting it applies to both)
    var mainColor: NSColor {
        get { return borderColor }
        set {
            borderColor = newValue
            fillColor = newValue.withAlphaComponent(0.15)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // The border is drawn a bit thicker (4pt), so draw with room for that plus an 8pt margin
        // As a result, the border ends up drawn about 2pt outside the actual window (Padding 10 - Inset 8 = 2)
        let inset: CGFloat = 8
        let cornerRadius: CGFloat = 12

        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: cornerRadius, yRadius: cornerRadius)

        // The background fill (only when showsFill is true)
        if showsFill {
            fillColor.setFill()
            path.fill()
        }

        // Draw the border
        borderColor.setStroke()
        path.lineWidth = 4
        if isDashed {
            path.setLineDash([6, 5], count: 2, phase: 0)
        }
        path.stroke()
    }
}
