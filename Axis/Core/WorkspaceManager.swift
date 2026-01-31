//
//  WorkspaceManager.swift
//  Axis
//
//  Created on 2026/01/30.
//

import AppKit
import Combine

// MARK: - ScreenIdentifier

/// A struct that uniquely identifies a physical monitor
/// Uses NSScreen's displayID (CGDirectDisplayID)
struct ScreenIdentifier: Hashable {
	let displayID: CGDirectDisplayID

	init(from screen: NSScreen) {
		self.displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
	}
}

// MARK: - PerScreenSnapshot

/// A struct that saves each workspace's tiling state
struct PerScreenSnapshot {
	/// Column structure (window IDs only)
	var columns: [[CGWindowID]]
	/// Column width ratios
	var columnWidthRatios: [CGFloat]?
	/// Row height ratios (column index -> each row's ratio)
	var rowHeightRatios: [Int: [CGFloat]]?
}

// MARK: - WorkspaceManager

/// The central class for the workspace feature
/// Each monitor manages its workspace independently
class WorkspaceManager: ObservableObject {
	static let shared = WorkspaceManager()

	// MARK: - State

	/// The currently active workspace number for each monitor (initial value: 0)
	@Published var activeWorkspace: [ScreenIdentifier: Int] = [:]

	/// Whether a workspace switch is in progress (used to prevent checkForWindowChanges from misfiring)
	var isSwitching: Bool = false

	/// The window IDs belonging to each monitor x workspace pair
	/// [monitor identifier: [workspace number: set of window IDs]]
	private var workspaceWindows: [ScreenIdentifier: [Int: Set<CGWindowID>]] = [:]

	/// The original position of a window moved off screen
	private var savedFrames: [CGWindowID: CGRect] = [:]

	/// Storage of the column structure and ratios for each monitor x workspace pair
	private var tilingSnapshots: [ScreenIdentifier: [Int: PerScreenSnapshot]] = [:]

	private let accessibilityManager = AccessibilityManager.shared
	private let tilingEngine = TilingEngine.shared

	private init() {}

	// MARK: - Public Methods

	/// Get a ScreenIdentifier from an NSScreen
	func screenIdentifier(for screen: NSScreen) -> ScreenIdentifier {
		return ScreenIdentifier(from: screen)
	}

	/// Get the current NSScreen from a ScreenIdentifier
	func screen(for identifier: ScreenIdentifier) -> NSScreen? {
		return NSScreen.screens.first { screen in
			let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
			return id == identifier.displayID
		}
	}

	/// Get the given monitor's current workspace number
	func currentWorkspace(on screen: NSScreen) -> Int {
		let id = screenIdentifier(for: screen)
		return activeWorkspace[id] ?? 0
	}

	/// Return the window IDs of the given monitor's current workspace
	func windowIDsForCurrentWorkspace(on screen: NSScreen) -> Set<CGWindowID> {
		let id = screenIdentifier(for: screen)
		let workspace = activeWorkspace[id] ?? 0
		return workspaceWindows[id]?[workspace] ?? []
	}

	/// Register a new window to the current workspace
	func registerWindow(_ windowID: CGWindowID, on screen: NSScreen) {
		let id = screenIdentifier(for: screen)
		let workspace = activeWorkspace[id] ?? 0

		if workspaceWindows[id] == nil {
			workspaceWindows[id] = [:]
		}
		if workspaceWindows[id]?[workspace] == nil {
			workspaceWindows[id]?[workspace] = []
		}
		workspaceWindows[id]?[workspace]?.insert(windowID)
		print("[Axis] WorkspaceManager: Registered window \(windowID) to workspace \(workspace) on screen \(id.displayID)")
	}

	/// Check whether the window is already registered to any workspace
	/// - Parameter windowID: the window ID being checked
	/// - Returns: true if it's already registered
	func isWindowInAnyWorkspace(_ windowID: CGWindowID) -> Bool {
		for screenID in workspaceWindows.keys {
			guard let workspaces = workspaceWindows[screenID] else { continue }
			for (_, windowSet) in workspaces {
				if windowSet.contains(windowID) {
					return true
				}
			}
		}
		return false
	}

	/// Remove a closed window from every workspace
	func unregisterWindow(_ windowID: CGWindowID) {
		for screenID in workspaceWindows.keys {
			guard let workspaces = workspaceWindows[screenID]?.keys else { continue }
			for workspace in workspaces {
				workspaceWindows[screenID]?[workspace]?.remove(windowID)
			}
		}
		savedFrames.removeValue(forKey: windowID)

		// Also remove it from the tiling snapshot
		for screenID in tilingSnapshots.keys {
			guard let workspaces = tilingSnapshots[screenID]?.keys else { continue }
			for workspace in workspaces {
				if var snapshot = tilingSnapshots[screenID]?[workspace] {
					snapshot.columns = snapshot.columns.map { column in
						column.filter { $0 != windowID }
					}.filter { !$0.isEmpty }
					tilingSnapshots[screenID]?[workspace] = snapshot
				}
			}
		}
	}

	/// Return window IDs across every monitor × every workspace (for the window switcher)
	func allWindowsByWorkspace() -> [ScreenIdentifier: [Int: Set<CGWindowID>]] {
		return workspaceWindows
	}

	/// Register every window to workspace 0 at launch
	func initializeWithCurrentWindows() {
		let allWindows = accessibilityManager.getAllWindows()
		let onScreenIDs = accessibilityManager.getOnScreenWindowIDs()

		for screen in NSScreen.screens {
			let id = screenIdentifier(for: screen)
			activeWorkspace[id] = 0

			if workspaceWindows[id] == nil {
				workspaceWindows[id] = [:]
			}
			workspaceWindows[id]?[0] = []

			let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0

			for window in allWindows {
				guard window.shouldBeManaged() && !window.shouldFloat() && onScreenIDs.contains(window.id) else {
					continue
				}

				// Determine the screen from the window's center point
				let windowCenterX = window.frame.midX
				let windowCenterY = mainScreenHeight - window.frame.midY
				let windowCenter = CGPoint(x: windowCenterX, y: windowCenterY)

				if screen.frame.contains(windowCenter) {
					workspaceWindows[id]?[0]?.insert(window.id)
				}
			}

			let count = workspaceWindows[id]?[0]?.count ?? 0
			print("[Axis] WorkspaceManager: Initialized screen \(id.displayID) with \(count) windows on workspace 0")
		}
	}

	// MARK: - Workspace Switching

	/// Switch workspaces
	/// - Parameters:
	///   - workspace: the workspace number being switched to
	///   - screen: the target monitor
	func switchWorkspace(to workspace: Int, on screen: NSScreen) {
		let id = screenIdentifier(for: screen)
		let currentWS = activeWorkspace[id] ?? 0

		// Do nothing if it's the same workspace
		guard workspace != currentWS else {
			print("[Axis] WorkspaceManager: Already on workspace \(workspace)")
			return
		}

		print("[Axis] WorkspaceManager: Switching workspace \(currentWS) -> \(workspace) on screen \(id.displayID)")

		// Set the switching-in-progress flag (prevents checkForWindowChanges from misfiring)
		isSwitching = true

		// Disable Zen Mode first if it's active
		if ZenModeManager.shared.isActive {
			ZenModeManager.shared.toggle()
		}

		// 1. Save the current workspace's TilingEngine state
		saveTilingState(for: id, workspace: currentWS, on: screen)

		// 2. Move the current workspace's windows off-screen
		hideWindowsForWorkspace(currentWS, on: id)

		// 3. Update activeWorkspace
		activeWorkspace[id] = workspace

		// 4. Create the destination workspace if it doesn't exist yet
		if workspaceWindows[id]?[workspace] == nil {
			if workspaceWindows[id] == nil {
				workspaceWindows[id] = [:]
			}
			workspaceWindows[id]?[workspace] = []
			print("[Axis] WorkspaceManager: Created new workspace \(workspace)")
		}

		// 5. Restore the TilingEngine state for the destination workspace
		restoreTilingState(for: id, workspace: workspace, on: screen)

		// 6. Restore the destination workspace's windows
		showWindowsForWorkspace(workspace, on: id)

		// 7. Reapply tiling
		tilingEngine.tile(on: screen)

		// 8. Focus a window in the workspace
		focusFirstWindow(in: workspace, on: id)

		// 9. Update the border
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
			BorderManager.shared.updateBorder()
		}

		// 8. Update the workspace number in the menu bar
		NotificationCenter.default.post(name: .workspaceChanged, object: nil)

		// 11. Clear the switching-in-progress flag after a short delay
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
			self?.isSwitching = false
		}

		print("[Axis] WorkspaceManager: Switched to workspace \(workspace)")
	}

	/// Move to the next workspace (+1)
	func switchToNextWorkspace(on screen: NSScreen) {
		let id = screenIdentifier(for: screen)
		let currentWS = activeWorkspace[id] ?? 0
		switchWorkspace(to: currentWS + 1, on: screen)
	}

	/// Move to the previous workspace (-1)
	func switchToPreviousWorkspace(on screen: NSScreen) {
		let id = screenIdentifier(for: screen)
		let currentWS = activeWorkspace[id] ?? 0
		switchWorkspace(to: currentWS - 1, on: screen)
	}

	// MARK: - Move Window to Workspace

	/// Move the focused window to a different workspace
	/// - Parameters:
	///   - windowID: the ID of the window being moved
	///   - workspace: the destination workspace number
	///   - screen: the target monitor
	func moveWindowToWorkspace(_ windowID: CGWindowID, workspace: Int, on screen: NSScreen) {
		let id = screenIdentifier(for: screen)
		let currentWS = activeWorkspace[id] ?? 0

		// Do nothing if it's the same workspace
		guard workspace != currentWS else { return }

		print("[Axis] WorkspaceManager: Moving window \(windowID) from workspace \(currentWS) to \(workspace)")

		// Set the switching-in-progress flag
		isSwitching = true

		// Remove the window from the current workspace
		workspaceWindows[id]?[currentWS]?.remove(windowID)

		// Create the destination workspace if it doesn't exist
		if workspaceWindows[id]?[workspace] == nil {
			if workspaceWindows[id] == nil {
				workspaceWindows[id] = [:]
			}
			workspaceWindows[id]?[workspace] = []
		}

		// Add the window to the destination workspace
		workspaceWindows[id]?[workspace]?.insert(windowID)

		// Also remove the window from TilingEngine's snapshot
		if var snapshot = tilingSnapshots[id]?[currentWS] {
			snapshot.columns = snapshot.columns.map { column in
				column.filter { $0 != windowID }
			}.filter { !$0.isEmpty }
			tilingSnapshots[id]?[currentWS] = snapshot
		}

		// Move the window off screen
		hideWindow(windowID)

		// Re-apply tiling on the current monitor
		tilingEngine.tile(on: screen)

		// Focus the remaining window
		focusFirstWindow(in: currentWS, on: id)

		// Update the border
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
			BorderManager.shared.updateBorder()
		}

		// Update the menu bar
		NotificationCenter.default.post(name: .workspaceChanged, object: nil)

		// Clear the switching-in-progress flag after a short delay
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
			self?.isSwitching = false
		}
	}

	/// Move the focused window to the next workspace
	func moveWindowToNextWorkspace(on screen: NSScreen) {
		guard let focusedWindow = accessibilityManager.getFocusedWindow() else { return }
		let id = screenIdentifier(for: screen)
		let currentWS = activeWorkspace[id] ?? 0
		let targetWS = currentWS + 1
		
		// Move the window
		moveWindowToWorkspace(focusedWindow.id, workspace: targetWS, on: screen)
		
		// Switch to the destination workspace (delayed slightly so the switch happens after the window move finishes)
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
			self?.switchWorkspace(to: targetWS, on: screen)
		}
	}

	/// Move the focused window to the previous workspace
	func moveWindowToPreviousWorkspace(on screen: NSScreen) {
		guard let focusedWindow = accessibilityManager.getFocusedWindow() else { return }
		let id = screenIdentifier(for: screen)
		let currentWS = activeWorkspace[id] ?? 0
		let targetWS = currentWS - 1
		
		// Move the window
		moveWindowToWorkspace(focusedWindow.id, workspace: targetWS, on: screen)
		
		// Switch to the destination workspace (delayed slightly so the switch happens after the window move finishes)
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
			self?.switchWorkspace(to: targetWS, on: screen)
		}
	}

	// MARK: - Hide Corner (the AeroSpace approach)

	/// The corner used to hide a window
	private enum HideCorner {
		case bottomLeft
		case bottomRight
	}

	/// Determine the best hidden corner for the given monitor
	/// Avoid the side that has a neighboring monitor
	private func optimalHideCorner(for screenID: ScreenIdentifier) -> HideCorner {
		guard let screen = screen(for: screenID) else {
			return .bottomLeft
		}

		let screenFrame = screen.frame

		// Check whether there's another monitor to the right
		var hasMonitorOnRight = false
		for otherScreen in NSScreen.screens {
			let otherId = screenIdentifier(for: otherScreen)
			if otherId == screenID { continue }

			// If another monitor's left edge is near this monitor's right edge, treat it as being "to the right"
			if otherScreen.frame.minX >= screenFrame.maxX - 10 {
				hasMonitorOnRight = true
				break
			}
		}

		// Bottom-left if there's a monitor to the right, otherwise bottom-right (default)
		return hasMonitorOnRight ? .bottomLeft : .bottomRight
	}

	/// Compute the position for hiding a window (AX coordinates: top-left origin, Y increases downward)
	/// Position it at the monitor's corner, leaving just 1 pixel inside the monitor
	private func hidePosition(for window: WindowInfo, corner: HideCorner, on screenID: ScreenIdentifier) -> CGPoint? {
		guard let screen = screen(for: screenID) else { return nil }

		// Convert NSScreen coordinates to AX coordinates
		// AX coordinate system: (0, 0) is top-left, Y increases downward
		// NSScreen coordinate system: the origin is bottom-left
		let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
		let visibleFrame = screen.visibleFrame

		// Convert visibleFrame to AX coordinates
		let axVisibleBottom = mainScreenHeight - visibleFrame.minY

		switch corner {
		case .bottomLeft:
			// Position it so the window's right edge sits 1px inside visibleFrame's left edge
			let x = visibleFrame.minX - window.frame.width + 1
			// Position it so the window's top edge sits 1px inside visibleFrame's bottom edge
			let y = axVisibleBottom - 1
			return CGPoint(x: x, y: y)

		case .bottomRight:
			// Position it so the window's left edge sits 1px inside visibleFrame's right edge
			let x = visibleFrame.maxX - 1
			// Position it so the window's top edge sits 1px inside visibleFrame's bottom edge
			let y = axVisibleBottom - 1
			return CGPoint(x: x, y: y)
		}
	}

	// MARK: - Private Helpers

	/// Move the given workspace's windows to the corner and hide them (the AeroSpace approach)
	private func hideWindowsForWorkspace(_ workspace: Int, on screenID: ScreenIdentifier) {
		guard let windowIDs = workspaceWindows[screenID]?[workspace] else { return }

		let corner = optimalHideCorner(for: screenID)
		let allWindows = accessibilityManager.getAllWindows()

		for window in allWindows {
			if windowIDs.contains(window.id) {
				// Save the original position and size
				savedFrames[window.id] = window.frame

				                // Move to the corner (position only, size unchanged)
				                if let hidePos = hidePosition(for: window, corner: corner, on: screenID) {
				                    window.setPosition(hidePos)
				                    // Because some apps don't redraw after a position change unless the size is set again too
				                    window.setSize(window.frame.size)
				                }			}
		}
		print("[Axis] WorkspaceManager: Hidden \(windowIDs.count) windows for workspace \(workspace) using corner: \(corner)")
	}

	/// Restore the given workspace's windows to their original positions
	private func showWindowsForWorkspace(_ workspace: Int, on screenID: ScreenIdentifier) {
		guard let windowIDs = workspaceWindows[screenID]?[workspace] else { return }

		let allWindows = accessibilityManager.getAllWindows()
		for window in allWindows {
			if windowIDs.contains(window.id) {
				// Restore the saved position and size
				if let savedFrame = savedFrames[window.id] {
					window.setFrame(savedFrame)
					savedFrames.removeValue(forKey: window.id)
				}
			}
		}
		print("[Axis] WorkspaceManager: Shown \(windowIDs.count) windows for workspace \(workspace)")
	}

	/// Move a single window to the corner and hide it
	private func hideWindow(_ windowID: CGWindowID) {
		let allWindows = accessibilityManager.getAllWindows()
		for window in allWindows {
			if window.id == windowID {
				savedFrames[window.id] = window.frame

				// Identify which monitor this window is on
				let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
				let windowCenterX = window.frame.midX
				let windowCenterY = mainScreenHeight - window.frame.midY
				let windowCenter = CGPoint(x: windowCenterX, y: windowCenterY)

				for screen in NSScreen.screens {
					if screen.frame.contains(windowCenter) {
						let screenID = screenIdentifier(for: screen)
						let corner = optimalHideCorner(for: screenID)
						if let hidePos = hidePosition(for: window, corner: corner, on: screenID) {
							window.setPosition(hidePos)
						}
						break
					}
				}
				break
			}
		}
	}

	/// Focus the first window of the given workspace
	private func focusFirstWindow(in workspace: Int, on screenID: ScreenIdentifier) {
		guard let windowIDs = workspaceWindows[screenID]?[workspace],
			  !windowIDs.isEmpty else {
			return
		}

		let allWindows = accessibilityManager.getAllWindows()
		for window in allWindows {
			if windowIDs.contains(window.id) {
				window.focus()
				print("[Axis] WorkspaceManager: Focused window '\(window.title)' in workspace \(workspace)")
				return
			}
		}
	}

	// MARK: - Tiling State Management

	/// Save the current TilingEngine state
	private func saveTilingState(for screenID: ScreenIdentifier, workspace: Int, on screen: NSScreen) {
		let state = tilingEngine.saveTilingStateForScreen(screen)

		if tilingSnapshots[screenID] == nil {
			tilingSnapshots[screenID] = [:]
		}
		tilingSnapshots[screenID]?[workspace] = state

		print("[Axis] WorkspaceManager: Saved tiling state for workspace \(workspace)")
	}

	/// Restore the saved TilingEngine state
	private func restoreTilingState(for screenID: ScreenIdentifier, workspace: Int, on screen: NSScreen) {
		if let snapshot = tilingSnapshots[screenID]?[workspace] {
			tilingEngine.restoreTilingStateForScreen(screen, snapshot: snapshot)
			print("[Axis] WorkspaceManager: Restored tiling state for workspace \(workspace)")
		} else {
			tilingEngine.clearTilingStateForScreen(screen)
			print("[Axis] WorkspaceManager: Cleared tiling state for new workspace \(workspace)")
		}
	}

	/// Return the focused monitor's workspace number (used for the menu bar display)
	func currentWorkspaceForFocusedScreen() -> Int {
		// The monitor the focused window is on
		if let focusedWindow = accessibilityManager.getFocusedWindow() {
			let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
			let windowCenterX = focusedWindow.frame.midX
			let windowCenterY = mainScreenHeight - focusedWindow.frame.midY
			let windowCenter = CGPoint(x: windowCenterX, y: windowCenterY)

			for screen in NSScreen.screens {
				if screen.frame.contains(windowCenter) {
					return currentWorkspace(on: screen)
				}
			}
		}

		// If there's no focused window, use the monitor the mouse cursor is on
		let mouseLocation = NSEvent.mouseLocation
		for screen in NSScreen.screens {
			if screen.frame.contains(mouseLocation) {
				return currentWorkspace(on: screen)
			}
		}

		// Otherwise, fall back to the main monitor's workspace
		if let mainScreen = NSScreen.main {
			return currentWorkspace(on: mainScreen)
		}

		return 0
	}

	/// Get the focused monitor
	func focusedScreen() -> NSScreen? {
		if let focusedWindow = accessibilityManager.getFocusedWindow() {
			let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
			let windowCenterX = focusedWindow.frame.midX
			let windowCenterY = mainScreenHeight - focusedWindow.frame.midY
			let windowCenter = CGPoint(x: windowCenterX, y: windowCenterY)

			for screen in NSScreen.screens {
				if screen.frame.contains(windowCenter) {
					return screen
				}
			}
		}

		// If there's no focused window, use the monitor the mouse cursor is on
		let mouseLocation = NSEvent.mouseLocation
		for screen in NSScreen.screens {
			if screen.frame.contains(mouseLocation) {
				return screen
			}
		}

		return NSScreen.main
	}
}

// MARK: - Notification Names

extension Notification.Name {
	static let workspaceChanged = Notification.Name("workspaceChanged")
}
