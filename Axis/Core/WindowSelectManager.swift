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
    
    /// Start window-selection mode
    func activate() {
        isActive = true
        selectedWindowIDs.removeAll()
        updateOverlays()
    }
    
    /// End window-selection mode
    func deactivate() {
        isActive = false
        selectedWindowIDs.removeAll()
        removeAllOverlays()
    }
    
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
        print("[Axis] moveSelectedWindows called, direction: \(direction), selected: \(selectedWindowIDs.count)")

        guard !selectedWindowIDs.isEmpty else {
            // Fall back to normal movement if nothing is selected
            print("[Axis] No selection, using normal move")
            tilingEngine.moveWindow(direction: direction)
            return
        }

        // Move the selected windows
        tilingEngine.moveWindows(windowIDs: selectedWindowIDs, direction: direction)
        print("[Axis] moveSelectedWindows: completed")

        // Update the overlay after a short delay (waiting for the window move to finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.updateOverlays()
        }
    }

    /// Merge the selected windows into a single column (stack them vertically)
    func mergeSelectedWindowsVertically() {
        print("[Axis] mergeSelectedWindowsVertically called, selected: \(selectedWindowIDs.count)")

        guard selectedWindowIDs.count >= 2 else {
            // Do nothing unless at least two items are selected
            print("[Axis] Need at least 2 windows to merge")
            return
        }

        // Merge the selected windows
        tilingEngine.mergeWindowsIntoColumn(windowIDs: selectedWindowIDs)
        print("[Axis] mergeSelectedWindowsVertically: completed")

        // Update the overlay after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.updateOverlays()
        }
    }
    
    /// Whether the window is selected
    func isSelected(_ windowID: CGWindowID) -> Bool {
        return selectedWindowIDs.contains(windowID)
    }
    
    // MARK: - Overlay Management (visual display of selection)
    
    private func updateOverlays() {
        // Guarantee execution on the main thread
        DispatchQueue.main.async { [weak self] in
            self?.performOverlayUpdate()
        }
    }
    
    private func performOverlayUpdate() {
        print("[Axis] Updating overlays, selected count: \(selectedWindowIDs.count)")
        
        // First update the existing overlay
        let allWindows = accessibilityManager.getAllWindows()
        let windowDict = Dictionary(uniqueKeysWithValues: allWindows.map { ($0.id, $0) })
        
        // Collect the IDs of overlays to remove
        let overlaysToRemove = overlayWindows.keys.filter { !selectedWindowIDs.contains($0) }
        
        // Remove overlays for windows that aren't selected
        for windowID in overlaysToRemove {
            overlayWindows[windowID]?.close()
            overlayWindows.removeValue(forKey: windowID)
        }
        
        // Create or update overlays for the selected windows
        for windowID in selectedWindowIDs {
            guard let windowInfo = windowDict[windowID] else {
                print("[Axis] Window not found for ID: \(windowID)")
                continue
            }
            
            if let existingOverlay = overlayWindows[windowID] {
                // Update the position
                updateOverlayPosition(existingOverlay, for: windowInfo)
            } else {
                // Create new
                let overlay = createOverlay(for: windowInfo)
                overlayWindows[windowID] = overlay
            }
        }
    }
    
    private func createOverlay(for windowInfo: WindowInfo) -> NSWindow {
        // Convert Accessibility coordinates (origin top-left) to NSWindow coordinates (origin bottom-left)
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let nsWindowY = mainScreenHeight - windowInfo.frame.origin.y - windowInfo.frame.height
        
        let frame = NSRect(
            x: windowInfo.frame.origin.x,
            y: nsWindowY,
            width: windowInfo.frame.width,
            height: windowInfo.frame.height
        )
        
        print("[Axis] Creating overlay at frame: \(frame)")
        
        let overlay = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        
        overlay.isOpaque = false
        overlay.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.15)
        overlay.level = .floating
        overlay.ignoresMouseEvents = true
        overlay.collectionBehavior = [.canJoinAllSpaces, .stationary]
        overlay.isReleasedWhenClosed = false
        
        // Add the border
        let borderView = SelectionBorderView(frame: overlay.contentView!.bounds)
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
        
        let frame = NSRect(
            x: windowInfo.frame.origin.x,
            y: nsWindowY,
            width: windowInfo.frame.width,
            height: windowInfo.frame.height
        )
        
        overlay.setFrame(frame, display: true)
    }
    
    private func removeAllOverlays() {
        print("[Axis] Removing all overlays")
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
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        let borderColor = NSColor.systemBlue
        borderColor.setStroke()
        
        let borderPath = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
        borderPath.lineWidth = 4
        borderPath.stroke()
    }
}
