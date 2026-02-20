//
//  WindowSelectManager.swift
//  Axis
//
//  Created on 2026/01/27.
//

import AppKit
import Combine

/// Responsible for managing window-selection mode
class WindowSelectManager: ObservableObject {
    static let shared = WindowSelectManager()
    
    // MARK: - State
    
    /// The currently selected window ID
    @Published var selectedWindowIDs: Set<CGWindowID> = []
    
    /// Whether selection mode is active
    @Published var isActive: Bool = false
    
    // MARK: - Dependencies
    
    private let accessibilityManager = AccessibilityManager.shared
    private let tilingEngine = TilingEngine.shared
    private let gapSelectManager = GapSelectManager.shared
    
    // MARK: - Overlay Windows (for showing selection state visually)
    
    private var overlayWindows: [CGWindowID: NSWindow] = [:]
    
    private init() {
        // Watch for mode changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onModeChanged),
            name: .modeChanged,
            object: nil
        )
    }
    
    // MARK: - Public Methods
    
    /// Select/deselect the currently focused window (toggle)
    func toggleCurrentWindow() {
        guard let focusedWindow = accessibilityManager.getFocusedWindow() else {
            return
        }
        
        if selectedWindowIDs.contains(focusedWindow.id) {
            selectedWindowIDs.remove(focusedWindow.id)
        } else {
            selectedWindowIDs.insert(focusedWindow.id)
        }
        
        updateOverlays()
    }
    
    /// Deselect the currently focused window
    func deselectCurrentWindow() {
        guard let focusedWindow = accessibilityManager.getFocusedWindow() else {
            return
        }
        
        selectedWindowIDs.remove(focusedWindow.id)
        updateOverlays()
    }
    
    /// Clear every selection
    func deselectAll() {
        selectedWindowIDs.removeAll()
        updateOverlays()
    }
    
    /// Move the selected windows in the given direction
    func moveSelectedWindows(direction: Direction) {

        guard !selectedWindowIDs.isEmpty else {
            // Fall back to normal movement if nothing is selected
            tilingEngine.moveWindow(direction: direction)
            return
        }

        // Move the selected windows
        tilingEngine.moveWindows(windowIDs: selectedWindowIDs, direction: direction)

        // Also try updating once right after the move
        updateOverlays()

        // Update the overlay after a short delay (waiting for the window move to finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.updateOverlays()
        }
    }

    /// Merge the selected windows into a single column (stack them vertically)
    func mergeSelectedWindowsVertically() {

        guard selectedWindowIDs.count >= 2 else {
            // Do nothing unless at least two items are selected
            return
        }

        // Merge the selected windows
        tilingEngine.mergeWindowsIntoColumn(windowIDs: selectedWindowIDs)

        // Update the overlay after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            // Clear the selection after merging (removes the teal border)
            self?.selectedWindowIDs.removeAll()
            self?.updateOverlays()
        }
    }

    /// Split the selected windows into individual columns (undo the vertical split)
    func splitSelectedWindowsToColumns() {

        guard selectedWindowIDs.count >= 1 else {
            // Do nothing unless at least one item is selected
            return
        }

        // Split the selected windows into individual columns
        tilingEngine.splitWindowsToColumns(windowIDs: selectedWindowIDs)

        // Update the overlay after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            // Clear the selection after splitting
            self?.selectedWindowIDs.removeAll()
            self?.updateOverlays()
        }
    }
    
    /// Whether the window is selected
    func isSelected(_ windowID: CGWindowID) -> Bool {
        return selectedWindowIDs.contains(windowID)
    }
    
    // MARK: - Active Border Management (Normal Mode)
    
    // NOTE: Active border logic has been moved to BorderManager.swift
    
    /// Start window-selection mode
    func activate() {
        // BorderManager is responsible for hiding the normal-mode border
        isActive = true
        selectedWindowIDs.removeAll()
        updateOverlays()
    }
    
    /// End window-selection mode
    func deactivate() {
        isActive = false
        selectedWindowIDs.removeAll()
        removeAllOverlays()
        // BorderManager is responsible for restoring the normal-mode border
    }

    // MARK: - Overlay Management (visual display of selection)
    
    /// Update the overlay's display (called on focus changes, etc.)
    func updateOverlays() {
        // Guarantee execution on the main thread
        DispatchQueue.main.async { [weak self] in
            self?.performOverlayUpdate()
        }
    }
    
    private func performOverlayUpdate() {
        
        // First update the existing overlay
        let allWindows = accessibilityManager.getAllWindows()
        let windowDict = Dictionary(uniqueKeysWithValues: allWindows.map { ($0.id, $0) })
        
        // Get the currently focused window
        let focusedWindowID = accessibilityManager.getFocusedWindow()?.id
        
        // The set of window IDs that should show an overlay (selected + focused)
        var targetWindowIDs = selectedWindowIDs
        if let fid = focusedWindowID, isActive {
            targetWindowIDs.insert(fid)
        }
        
        // Collect the IDs of overlays to remove (ones not in the target set)
        let overlaysToRemove = overlayWindows.keys.filter { !targetWindowIDs.contains($0) }
        
        // Remove unneeded overlays
        for windowID in overlaysToRemove {
            overlayWindows[windowID]?.close()
            overlayWindows.removeValue(forKey: windowID)
        }
        
        // Create or update the overlay for the target window
        for windowID in targetWindowIDs {
            guard let windowInfo = windowDict[windowID] else {
                continue
            }
            
            // Decide the color: white if selected, gray if only focused
            let isSelected = selectedWindowIDs.contains(windowID)
            let color = isSelected ? NSColor.white : NSColor.lightGray
            
            if let existingOverlay = overlayWindows[windowID] {
                // Update the position
                updateOverlayPosition(existingOverlay, for: windowInfo)
                // Update the color
                if let borderView = existingOverlay.contentView?.subviews.first(where: { $0 is SelectionBorderView }) as? SelectionBorderView {
                    borderView.borderColor = color
                    borderView.fillColor = .clear // アニメーションなし
                }
            } else {
                // Create new
                let overlay = createOverlay(for: windowInfo, color: color)
                overlayWindows[windowID] = overlay
                if let borderView = overlay.contentView?.subviews.first(where: { $0 is SelectionBorderView }) as? SelectionBorderView {
                    borderView.fillColor = .clear // アニメーションなし
                }
            }
        }
    }
    
    private func createOverlay(for windowInfo: WindowInfo, color: NSColor) -> NSWindow {
        // Convert Accessibility coordinates (origin top-left) to NSWindow coordinates (origin bottom-left)
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let nsWindowY = mainScreenHeight - windowInfo.frame.origin.y - windowInfo.frame.height
        
        // Enlarge the overlay window itself so the border can be drawn outside the window edge
        let padding: CGFloat = 10
        let frame = NSRect(
            x: windowInfo.frame.origin.x - padding,
            y: nsWindowY - padding,
            width: windowInfo.frame.width + (padding * 2),
            height: windowInfo.frame.height + (padding * 2)
        )
        
        
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
        overlay.collectionBehavior = [.canJoinAllSpaces, .stationary]
        overlay.isReleasedWhenClosed = false
        
        // Add the view that draws the border and background
        let borderView = SelectionBorderView(frame: overlay.contentView!.bounds)
        borderView.mainColor = color // 初期色を設定
        borderView.autoresizingMask = [.width, .height]
        overlay.contentView?.addSubview(borderView)
        
        // Display in the background
        DispatchQueue.main.async {
            overlay.orderFront(nil)
        }
        
        return overlay
    }
    
    private func updateOverlayPosition(_ overlay: NSWindow, for windowInfo: WindowInfo) {
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let nsWindowY = mainScreenHeight - windowInfo.frame.origin.y - windowInfo.frame.height
        
        // Apply the same padding as createOverlay
        let padding: CGFloat = 10
        let frame = NSRect(
            x: windowInfo.frame.origin.x - padding,
            y: nsWindowY - padding,
            width: windowInfo.frame.width + (padding * 2),
            height: windowInfo.frame.height + (padding * 2)
        )
        
        overlay.setFrame(frame, display: true)
    }
    
    private func removeAllOverlays() {
        let overlaysCopy = overlayWindows
        overlayWindows.removeAll()
        
        DispatchQueue.main.async {
            for (_, overlay) in overlaysCopy {
                overlay.close()
            }
        }
    }
    
    // MARK: - Notifications
    
    @objc private func onModeChanged(_ notification: Notification) {
        guard let mode = notification.object as? HotkeyManager.Mode else { return }
        
        if mode == .windowSelect {
            activate()
        } else {
            deactivate()
        }
    }
}

// MARK: - Selection Border View

/// The view that draws the border around selected windows
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
        path.stroke()
    }
}
