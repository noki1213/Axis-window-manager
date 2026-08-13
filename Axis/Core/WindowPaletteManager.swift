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
///   Vertical (rows) → Displays (monitors)
///   Horizontal (sections) → Spaces (workspaces)
///   Horizontal (cards) → windows
///
/// Operations:
///   I/K → move up/down between Displays (wraps around)
///   J/L → move left/right between windows (wraps to the next/previous Space on the same Display when hitting a Space edge)
class WindowPaletteManager {
	static let shared = WindowPaletteManager()

	// MARK: - Properties

	/// The palette panel
	private var panel: WindowPalettePanel?

	/// Data per Display
	private var displays: [WindowPaletteDisplay] = []

	/// The currently selected Display (monitor row)
	private var selectedDisplayIndex: Int = 0

	/// The currently selected Space (workspace column)
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
		// Close the palette (hide with animation)
		panel?.hidePanel()

		// Restore the window that was hidden (restored immediately, without waiting for the animation to finish)
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

	/// Move up (wraps to the previous Display, clamping the Space/Item index within range)
	func moveUp() {
		guard !displays.isEmpty else { return }
		let displayCount = displays.count
		selectedDisplayIndex = (selectedDisplayIndex - 1 + displayCount) % displayCount
		clampSelectionToCurrentDisplay()
		notifyPanel()
	}

	/// Move down (wraps to the next Display, clamping the Space/Item index within range)
	func moveDown() {
		guard !displays.isEmpty else { return }
		let displayCount = displays.count
		selectedDisplayIndex = (selectedDisplayIndex + 1) % displayCount
		clampSelectionToCurrentDisplay()
		notifyPanel()
	}

	/// Move left (to the previous window within the same Display; wraps to the last window of the previous Space at the left edge)
	func moveLeft() {
		guard !displays.isEmpty else { return }
		let spaces = displays[selectedDisplayIndex].spaces
		guard !spaces.isEmpty else { return }

		// Whether moving left within the current Space is possible
		if selectedItemIndex > 0 {
			selectedItemIndex -= 1
			notifyPanel()
			return
		}

		// Reached the left edge, so look for the previous non-empty Space within the same Display (wrapping around)
		var targetSpaceIndex = selectedSpaceIndex
		for _ in 0..<spaces.count {
			targetSpaceIndex = (targetSpaceIndex - 1 + spaces.count) % spaces.count
			if !spaces[targetSpaceIndex].items.isEmpty {
				selectedSpaceIndex = targetSpaceIndex
				selectedItemIndex = spaces[targetSpaceIndex].items.count - 1
				notifyPanel()
				return
			}
		}
	}

	/// Move right (to the next window within the same Display; wraps to the first window of the next Space at the right edge)
	func moveRight() {
		guard !displays.isEmpty else { return }
		let spaces = displays[selectedDisplayIndex].spaces
		guard !spaces.isEmpty else { return }

		let currentItemCount = spaces[selectedSpaceIndex].items.count

		// Whether moving right within the current Space is possible
		if selectedItemIndex < currentItemCount - 1 {
			selectedItemIndex += 1
			notifyPanel()
			return
		}

		// Reached the right edge, so look for the next non-empty Space within the same Display (wrapping around)
		var targetSpaceIndex = selectedSpaceIndex
		for _ in 0..<spaces.count {
			targetSpaceIndex = (targetSpaceIndex + 1) % spaces.count
			if !spaces[targetSpaceIndex].items.isEmpty {
				selectedSpaceIndex = targetSpaceIndex
				selectedItemIndex = 0
				notifyPanel()
				return
			}
		}
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

		// Selecting from the Hidden section (windows hidden with Ctrl+Opt+X)
		// Route it through the neighbor-memory restore logic instead of a normal workspace switch
		if selectedItem.workspace == -3 {
			HiddenWindowManager.shared.restore(windowID: selectedItem.windowID)
		} else {
			// Switch to the selected window's workspace
			switchToWindowWorkspace(selectedItem)
		}

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

	/// Clamp the window/Space index within the current Display's range
	private func clampSelectionToCurrentDisplay() {
		guard !displays.isEmpty else { return }
		let spaces = displays[selectedDisplayIndex].spaces
		guard !spaces.isEmpty else {
			selectedSpaceIndex = 0
			selectedItemIndex = 0
			return
		}
		if selectedSpaceIndex >= spaces.count {
			selectedSpaceIndex = max(spaces.count - 1, 0)
		}
		// If the destination Space is empty the selection would vanish, so shift to a Space that has content
		if spaces[selectedSpaceIndex].items.isEmpty,
		   let nearest = spaces.indices
			.filter({ !spaces[$0].items.isEmpty })
			.min(by: { abs($0 - selectedSpaceIndex) < abs($1 - selectedSpaceIndex) }) {
			selectedSpaceIndex = nearest
			selectedItemIndex = 0
		}
		let items = spaces[selectedSpaceIndex].items
		if selectedItemIndex >= items.count {
			selectedItemIndex = max(items.count - 1, 0)
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

		// Windows the user deliberately floated with Ctrl+Option+F (per Display)
		// It normally appears in its own workspace's section, but pull it out here and group it into a separate section
		var userFloatItemsByScreen: [ScreenIdentifier: [WindowPaletteItem]] = [:]

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
					// Windows hidden (minimized) with Ctrl+Opt+X are excluded from the normal Space section, and
					// Add them together later as the Hidden section
					guard !HiddenWindowManager.shared.isHidden(windowID) else { continue }

					guard let windowInfo = windowInfoMap[windowID] else { continue }

					let item = WindowPaletteItem(
						windowID: windowID,
						appName: windowInfo.app.localizedName ?? "Unknown App",
						windowTitle: windowInfo.title,
						appIcon: windowInfo.app.icon,
						workspace: workspace,
						screenID: screenID
					)

					// Windows the user has floated are excluded from the normal Space section, and
					// Add them together later as the Float section
					if workspaceManager.isFloating(windowID) {
						userFloatItemsByScreen[screenID, default: []].append(item)
					} else {
						items.append(item)
					}
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

		// --- Add the Float section (windows the user deliberately floated) to each Display ---
		// Use workspace = -2 as a dedicated section marker (the real workspace number is kept on each item)
		for i in result.indices {
			if let floatItems = userFloatItemsByScreen[result[i].screenID], !floatItems.isEmpty {
				result[i].spaces.append(WindowPaletteSection(workspace: -2, items: floatItems))
			}
		}

		// --- Add the System section (floating windows not registered to any workspace) to the end of each Display ---
		// Since system-originated floating windows like the Settings app or dialogs aren't registered to a workspace,
		// It doesn't show up in the normal collection. Pick it up here and add it as the "System" section (workspace = -1).
		let onScreenIDs = accessibilityManager.getOnScreenWindowIDs()
		let myPID = ProcessInfo.processInfo.processIdentifier
		var systemFloatItemsByScreen: [ScreenIdentifier: [WindowPaletteItem]] = [:]

		for window in allWindows {
			// Excludes Axis's own windows (palette, border, etc.)
			guard window.app.processIdentifier != myPID else { continue }
			// Only windows currently shown on screen
			guard onScreenIDs.contains(window.id) else { continue }
			// Excluded if it's already registered to some workspace, since it already shows up in the normal section
			guard !workspaceManager.isWindowInAnyWorkspace(window.id) else { continue }
			// Minimized and fullscreen windows are excluded
			guard !window.isMinimized && !window.isFullscreen else { continue }
			// Only targets real windows (standard windows or dialogs)
			// (So invisible helper windows, like the ones Arc has, don't show up in the list)
			guard window.shouldBeManaged()
				|| window.subrole == kAXDialogSubrole as String
				|| window.subrole == kAXSystemDialogSubrole as String else { continue }

			// Identify the screen the window is on (falls back to the main screen if it can't be determined)
			let screen = screenForWindow(window) ?? NSScreen.screens.first
			guard let targetScreen = screen else { continue }
			let screenID = ScreenIdentifier(from: targetScreen)

			let item = WindowPaletteItem(
				windowID: window.id,
				appName: window.app.localizedName ?? "Unknown App",
				windowTitle: window.title,
				appIcon: window.app.icon,
				workspace: -1,
				screenID: screenID
			)
			systemFloatItemsByScreen[screenID, default: []].append(item)
		}

		for i in result.indices {
			if let systemFloatItems = systemFloatItemsByScreen[result[i].screenID], !systemFloatItems.isEmpty {
				result[i].spaces.append(WindowPaletteSection(workspace: -1, items: systemFloatItems))
			}
		}

		// --- Add the Hidden section (windows hidden with Ctrl+Opt+X) to the end of each Display ---
		// Use workspace = -3 as a dedicated section marker
		var hiddenItemsByScreen: [ScreenIdentifier: [WindowPaletteItem]] = [:]
		for record in HiddenWindowManager.shared.hiddenStack {
			guard let windowInfo = windowInfoMap[record.windowID] else { continue }
			let item = WindowPaletteItem(
				windowID: record.windowID,
				appName: windowInfo.app.localizedName ?? "Unknown App",
				windowTitle: windowInfo.title,
				appIcon: windowInfo.app.icon,
				workspace: -3,
				screenID: record.screenID
			)
			hiddenItemsByScreen[record.screenID, default: []].append(item)
		}

		for i in result.indices {
			if let hiddenItems = hiddenItemsByScreen[result[i].screenID], !hiddenItems.isEmpty {
				result[i].spaces.append(WindowPaletteSection(workspace: -3, items: hiddenItems))
			}
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
		// (System section windows (workspace == -1) don't belong to a workspace, so they aren't switched)
		if item.workspace != -1 && item.workspace != currentWS {
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
