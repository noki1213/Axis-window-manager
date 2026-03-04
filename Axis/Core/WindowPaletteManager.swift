//
//  WindowPaletteManager.swift
//  Axis
//
//  Created on 2026/01/31.
//

import AppKit

/// The window palette's core logic
/// Fetch and display the window list across all workspaces, and
/// Switch to the selected window's workspace and focus it
///
/// Layout:
///   Horizontal direction (columns) → Display (monitor)
///   Vertical direction → Space (workspace)
///   Horizontal (cards) → windows
///
/// Operations:
///   I/K → move up/down between Spaces (within the same Display)
///   J/L → move left/right between windows (moves to the neighboring Display when it hits the edge)
class WindowPaletteManager {
	static let shared = WindowPaletteManager()

	// MARK: - Properties

	/// The palette panel
	private var panel: WindowPalettePanel?

	/// Data per Display
	private var displays: [WindowPaletteDisplay] = []

	/// The currently selected Display (monitor column)
	private var selectedDisplayIndex: Int = 0

	/// The currently selected Space (workspace row)
	private var selectedSpaceIndex: Int = 0

	/// The currently selected window
	private var selectedItemIndex: Int = 0

	/// The original position of windows stashed off screen while the palette is showing
	private var hiddenWindowFrames: [CGWindowID: CGRect] = [:]

	/// Whether there's a frame carried over from Zen mode etc. (re-tiling is needed on exit)
	private var needsRetileOnClose = false

	private let workspaceManager = WorkspaceManager.shared
	private let accessibilityManager = AccessibilityManager.shared

	private init() {}

	/// Returns whether the given window is stashed off screen while the palette is showing (used to control border display)
	func isWindowHidden(_ windowID: CGWindowID) -> Bool {
		return hiddenWindowFrames[windowID] != nil
	}

	// MARK: - Public Methods

	/// Start palette mode
	/// - Parameter inheritedHiddenFrames: the original positions of windows carried over from Zen mode etc.
	func startPalette(inheritedHiddenFrames: [CGWindowID: CGRect] = [:]) {
		// Get the currently focused window's ID before opening the palette
		let focusedWindowID = accessibilityManager.getFocusedWindow()?.id

		displays = collectDisplays()

		guard !displays.isEmpty else {
			return
		}

		// Find where the focused window is within displays
		let initialSelection = focusedWindowID.flatMap { findWindowPosition(windowID: $0) }

		selectedDisplayIndex = initialSelection?.displayIndex ?? 0
		selectedSpaceIndex = initialSelection?.spaceIndex ?? 0
		selectedItemIndex = initialSelection?.itemIndex ?? 0

		// Temporarily hide the on-screen window (for visibility)
		hideOnScreenWindows()

		// Overwrite with the original position of windows carried over from Zen mode etc.
		// (Prefer the original pre-Zen position over the one the palette saved)
		needsRetileOnClose = !inheritedHiddenFrames.isEmpty
		for (id, frame) in inheritedHiddenFrames {
			hiddenWindowFrames[id] = frame
		}

		if panel == nil {
			panel = WindowPalettePanel()
		}
		panel?.showWithDisplays(
			displays,
			displayIndex: selectedDisplayIndex,
			spaceIndex: selectedSpaceIndex,
			itemIndex: selectedItemIndex
		)

	}

	/// End palette mode (cancel)
	func endPalette() {
		panel?.hidePanel()

		// Restore the window that was hidden
		restoreHiddenWindows()

		// If it was carried over from Zen mode, re-tiling and restoring the border are required
		if needsRetileOnClose {
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
				TilingEngine.shared.tileAllScreens()
				BorderManager.shared.updateBorder()
			}
			needsRetileOnClose = false
		}

		displays.removeAll()
		selectedDisplayIndex = 0
		selectedSpaceIndex = 0
		selectedItemIndex = 0
	}

	/// Move up (to the previous Space within the same Display)
	func moveUp() {
		guard !displays.isEmpty else { return }
		let spaceCount = displays[selectedDisplayIndex].spaces.count
		guard spaceCount > 0 else { return }
		selectedSpaceIndex = (selectedSpaceIndex - 1 + spaceCount) % spaceCount
		clampItemIndex()
		notifyPanel()
	}

	/// Move down (to the next Space within the same Display)
	func moveDown() {
		guard !displays.isEmpty else { return }
		let spaceCount = displays[selectedDisplayIndex].spaces.count
		guard spaceCount > 0 else { return }
		selectedSpaceIndex = (selectedSpaceIndex + 1) % spaceCount
		clampItemIndex()
		notifyPanel()
	}

	/// Move left (to the previous window; moves to the previous Display if at the edge)
	func moveLeft() {
		guard !displays.isEmpty else { return }

		if selectedItemIndex > 0 {
			// Move left within the same Space
			selectedItemIndex -= 1
		} else if selectedDisplayIndex > 0 {
			// Move to the previous Display
			selectedDisplayIndex -= 1
			// Clamp the Space index to a valid range
			let newSpaceCount = displays[selectedDisplayIndex].spaces.count
			if selectedSpaceIndex >= newSpaceCount {
				selectedSpaceIndex = max(newSpaceCount - 1, 0)
			}
			// Select the last window on the destination Space
			let newItemCount = displays[selectedDisplayIndex].spaces[selectedSpaceIndex].items.count
			selectedItemIndex = max(newItemCount - 1, 0)
		} else {
			// Already at the first Display, so wrap around (to the last Display)
			selectedDisplayIndex = displays.count - 1
			let newSpaceCount = displays[selectedDisplayIndex].spaces.count
			if selectedSpaceIndex >= newSpaceCount {
				selectedSpaceIndex = max(newSpaceCount - 1, 0)
			}
			let newItemCount = displays[selectedDisplayIndex].spaces[selectedSpaceIndex].items.count
			selectedItemIndex = max(newItemCount - 1, 0)
		}
		notifyPanel()
	}

	/// Move right (to the next window; moves to the next Display if at the edge)
	func moveRight() {
		guard !displays.isEmpty else { return }
		let itemCount = displays[selectedDisplayIndex].spaces[selectedSpaceIndex].items.count

		if selectedItemIndex < itemCount - 1 {
			// Move right within the same Space
			selectedItemIndex += 1
		} else if selectedDisplayIndex < displays.count - 1 {
			// Move to the next Display
			selectedDisplayIndex += 1
			// Clamp the Space index to a valid range
			let newSpaceCount = displays[selectedDisplayIndex].spaces.count
			if selectedSpaceIndex >= newSpaceCount {
				selectedSpaceIndex = max(newSpaceCount - 1, 0)
			}
			selectedItemIndex = 0
		} else {
			// Already at the last Display, so wrap around (to the first Display)
			selectedDisplayIndex = 0
			let newSpaceCount = displays[selectedDisplayIndex].spaces.count
			if selectedSpaceIndex >= newSpaceCount {
				selectedSpaceIndex = max(newSpaceCount - 1, 0)
			}
			selectedItemIndex = 0
		}
		notifyPanel()
	}

	/// Confirm the selection and switch to the window
	/// Automatically returns to normal mode after switching
	func confirmSelection() {
		guard selectedDisplayIndex >= 0 && selectedDisplayIndex < displays.count else { return }
		let display = displays[selectedDisplayIndex]
		guard selectedSpaceIndex >= 0 && selectedSpaceIndex < display.spaces.count else { return }
		let space = display.spaces[selectedSpaceIndex]
		guard selectedItemIndex >= 0 && selectedItemIndex < space.items.count else { return }

		let selectedItem = space.items[selectedItemIndex]

		// Close the panel
		panel?.hidePanel()

		// Restore the window that was hidden
		restoreHiddenWindows()

		// If it was carried over from Zen mode, re-tiling and restoring the border are required
		if needsRetileOnClose {
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
				TilingEngine.shared.tileAllScreens()
				BorderManager.shared.updateBorder()
			}
			needsRetileOnClose = false
		}

		// Switch to the selected window's workspace
		switchToWindowWorkspace(selectedItem)

		// Clear the data
		displays.removeAll()
		selectedDisplayIndex = 0
		selectedSpaceIndex = 0
		selectedItemIndex = 0

		// Return to normal mode
		DispatchQueue.main.async {
			HotkeyManager.shared.currentMode = .normal
			NotificationCenter.default.post(name: .modeChanged, object: HotkeyManager.Mode.normal)
		}

	}

	// MARK: - Private Methods

	/// Return the position within displays where the given window ID is found
	private func findWindowPosition(windowID: CGWindowID) -> (displayIndex: Int, spaceIndex: Int, itemIndex: Int)? {
		for (dIndex, display) in displays.enumerated() {
			for (sIndex, space) in display.spaces.enumerated() {
				for (iIndex, item) in space.items.enumerated() {
					if item.windowID == windowID {
						return (dIndex, sIndex, iIndex)
					}
				}
			}
		}
		return nil
	}

	/// Update the panel's selection display
	private func notifyPanel() {
		panel?.updateSelection(
			displayIndex: selectedDisplayIndex,
			spaceIndex: selectedSpaceIndex,
			itemIndex: selectedItemIndex
		)
	}

	/// Clamp the window index to the current Space's range
	private func clampItemIndex() {
		let itemCount = displays[selectedDisplayIndex].spaces[selectedSpaceIndex].items.count
		if selectedItemIndex >= itemCount {
			selectedItemIndex = max(itemCount - 1, 0)
		}
	}

	// MARK: - Window Hide / Restore (the corner approach)

	/// The corner used to hide a window
	private enum HideCorner {
		case bottomLeft
		case bottomRight
	}

	/// Determine the best hidden corner for the given monitor
	/// Avoid the side that has a neighboring monitor
	private func optimalHideCorner(for screen: NSScreen) -> HideCorner {
		let screenFrame = screen.frame

		// Check whether there's another monitor to the right
		var hasMonitorOnRight = false
		for otherScreen in NSScreen.screens {
			if otherScreen == screen { continue }
			if otherScreen.frame.minX >= screenFrame.maxX - 10 {
				hasMonitorOnRight = true
				break
			}
		}

		// Bottom-left if there's a monitor to the right, otherwise bottom-right
		return hasMonitorOnRight ? .bottomLeft : .bottomRight
	}

	/// Compute the position for hiding a window (AX coordinates: top-left origin, Y increases downward)
	/// Position it at the monitor's corner, leaving just 1 pixel inside the monitor
	private func hidePosition(for window: WindowInfo, corner: HideCorner, on screen: NSScreen) -> CGPoint {
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

	/// Determine which screen a window is on
	private func screenForWindow(_ window: WindowInfo) -> NSScreen? {
		let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
		let windowCenterX = window.frame.midX
		let windowCenterY = mainScreenHeight - window.frame.midY
		let center = CGPoint(x: windowCenterX, y: windowCenterY)

		return NSScreen.screens.first { $0.frame.contains(center) }
	}

	/// Stash an on-screen window off screen (the corner approach)
	/// By shrinking the window down to a tiny size before stashing it in the corner,
	/// Prevents the shadow or corner areas from being visible
	private func hideOnScreenWindows() {
		hiddenWindowFrames.removeAll()

		let onScreenIDs = accessibilityManager.getOnScreenWindowIDs()
		let allWindows = accessibilityManager.getAllWindows()

		for window in allWindows {
			// Only targets managed windows currently shown on screen
			guard onScreenIDs.contains(window.id) else { continue }
			guard window.shouldBeManaged() else { continue }

			// Save the original position and size
			hiddenWindowFrames[window.id] = window.frame

			// Get the screen the window belongs to and stash it in the corner
			if let screen = screenForWindow(window) {
				let corner = optimalHideCorner(for: screen)
				let hidePos = hidePosition(for: window, corner: corner, on: screen)
				window.setPosition(hidePos)
			} else {
				// Fall back to the main screen's corner if the screen can't be determined
				if let mainScreen = NSScreen.main {
					let corner = optimalHideCorner(for: mainScreen)
					let hidePos = hidePosition(for: window, corner: corner, on: mainScreen)
					window.setPosition(hidePos)
				}
			}
		}

	}

	/// Return the stashed window to its original position
	private func restoreHiddenWindows() {
		let allWindows = accessibilityManager.getAllWindows()

		for window in allWindows {
			if let savedFrame = hiddenWindowFrames[window.id] {
				window.setFrame(savedFrame)
			}
		}

		hiddenWindowFrames.removeAll()
	}

	// MARK: - Data Collection

	/// Collect window info for every workspace, grouped by Display
	private func collectDisplays() -> [WindowPaletteDisplay] {
		// Get every workspace's window IDs in tiling order (left-to-right, top-to-bottom)
		let allWorkspaces = workspaceManager.windowIDsInTilingOrder()

		// Get info for every current window (via the AX API)
		let allWindows = accessibilityManager.getAllWindows()

		// Build a dictionary of window ID -> WindowInfo (for fast lookup)
		var windowInfoMap: [CGWindowID: WindowInfo] = [:]
		for window in allWindows {
			windowInfoMap[window.id] = window
		}

		// Lookup table from ScreenIdentifier to monitor number (1-based)
		var displayNumberMap: [ScreenIdentifier: Int] = [:]
		for (index, screen) in NSScreen.screens.enumerated() {
			let sid = ScreenIdentifier(from: screen)
			displayNumberMap[sid] = index + 1
		}

		// Build the data per Display
		var displayMap: [ScreenIdentifier: WindowPaletteDisplay] = [:]

		for (screenID, workspaces) in allWorkspaces {
			let displayNumber = displayNumberMap[screenID] ?? 1

			// Create an entry for this Display if one doesn't exist
			if displayMap[screenID] == nil {
				displayMap[screenID] = WindowPaletteDisplay(
					displayNumber: displayNumber,
					screenID: screenID,
					spaces: []
				)
			}

			let sortedWorkspaces = workspaces.keys.sorted()

			for workspace in sortedWorkspaces {
				guard let windowIDs = workspaces[workspace] else { continue }

				var items: [WindowPaletteItem] = []
				for windowID in windowIDs {
					guard let windowInfo = windowInfoMap[windowID] else { continue }

					let item = WindowPaletteItem(
						windowID: windowID,
						appName: windowInfo.app.localizedName ?? "不明なアプリ",
						windowTitle: windowInfo.title,
						appIcon: windowInfo.app.icon,
						workspace: workspace,
						screenID: screenID
					)
					items.append(item)
				}

				// Only add Spaces that have windows
				if !items.isEmpty {
					let section = WindowPaletteSection(workspace: workspace, items: items)
					displayMap[screenID]?.spaces.append(section)
				}
			}
		}

		// Sort by Display number
		var result = Array(displayMap.values)
		result.sort { $0.displayNumber < $1.displayNumber }

		// Sort the Spaces within each Display by number
		for i in result.indices {
			result[i].spaces.sort { $0.workspace < $1.workspace }
		}

		return result
	}

	/// Switch to the selected window's workspace and focus it
	private func switchToWindowWorkspace(_ item: WindowPaletteItem) {
		guard let screen = workspaceManager.screen(for: item.screenID) else {
			return
		}

		let currentWS = workspaceManager.currentWorkspace(on: screen)

		// Switch if it's on a different workspace
		if item.workspace != currentWS {
			workspaceManager.switchWorkspace(to: item.workspace, on: screen)
		}

		// Focus the target window
		let allWindows = accessibilityManager.getAllWindows()
		for window in allWindows {
			if window.id == item.windowID {
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
					window.focus()

					// Move the mouse cursor to the center of the window
					let centerX = window.frame.midX
					let centerY = window.frame.midY
					CGWarpMouseCursorPosition(CGPoint(x: centerX, y: centerY))

					// Update the border
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
						BorderManager.shared.updateBorder()
					}
				}
				break
			}
		}
	}
}
