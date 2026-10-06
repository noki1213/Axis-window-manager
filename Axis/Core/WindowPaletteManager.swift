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

	/// The windows the palette moved out of sight while it is open
	var hiddenWindowIDs: Set<CGWindowID> {
		Set(hiddenWindowFrames.keys)
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

	/// Move up to the card above (falls back to the previous Display when the layout gives no neighbor)
	func moveUp() {
		guard !displays.isEmpty else { return }
		if let target = panel?.verticalNeighbor(
			displayIndex: selectedDisplayIndex,
			spaceIndex: selectedSpaceIndex,
			itemIndex: selectedItemIndex,
			up: true
		) {
			(selectedDisplayIndex, selectedSpaceIndex, selectedItemIndex) = target
			notifyPanel()
			return
		}
		let displayCount = displays.count
		selectedDisplayIndex = (selectedDisplayIndex - 1 + displayCount) % displayCount
		clampSelectionToCurrentDisplay()
		notifyPanel()
	}

	/// Move down to the card below (falls back to the next Display when the layout gives no neighbor)
	func moveDown() {
		guard !displays.isEmpty else { return }
		if let target = panel?.verticalNeighbor(
			displayIndex: selectedDisplayIndex,
			spaceIndex: selectedSpaceIndex,
			itemIndex: selectedItemIndex,
			up: false
		) {
			(selectedDisplayIndex, selectedSpaceIndex, selectedItemIndex) = target
			notifyPanel()
			return
		}
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
		if space.kind == .hidden {
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
	private func optimalHideCorner(for screen: NSScreen) -> HideCorner {
		HideCorner.best(for: screen)
	}

	private func hidePosition(for window: WindowInfo, corner: HideCorner, on screen: NSScreen) -> CGPoint {
		corner.position(forWindowWidth: window.frame.width, on: screen)
	}

	/// Stash an on-screen window off screen (the corner approach)
	private func hideOnScreenWindows() {
		hiddenWindowFrames.removeAll()

		// Every window in view: the tiles of the workspaces shown, floating windows, dialogs
		let coordinator = TrackingCoordinator.shared
		let state = coordinator.state
		let shown = state.records.keys.filter { state.visibility($0) == .visible }.sorted()

		for window in coordinator.windowInfos(shown, onScreenOnly: true) {
			// Save the original position and size
			hiddenWindowFrames[window.id] = window.frame

			// Get the screen the window belongs to and stash it in the corner
			if let screen = window.screen ?? NSScreen.main {
				let corner = optimalHideCorner(for: screen)
				window.setPosition(hidePosition(for: window, corner: corner, on: screen))
			}
		}
	}

	/// Return the stashed window to its original position
	private func restoreHiddenWindows() {
		let coordinator = TrackingCoordinator.shared
		for (windowID, savedFrame) in hiddenWindowFrames {
			coordinator.windowInfo(windowID)?.setFrame(savedFrame)
		}
		hiddenWindowFrames.removeAll()
	}

	// MARK: - Data Collection

	/// Collect window info for every workspace, grouped by Display. The workspaces, their order and the
	/// windows' titles come from the tracking state
	private func collectDisplays() -> [WindowPaletteDisplay] {
		let coordinator = TrackingCoordinator.shared
		let state = coordinator.state

		func item(_ windowID: CGWindowID, workspace: WorkspaceID?, monitor: MonitorKey) -> WindowPaletteItem? {
			guard let record = state.record(windowID) else { return nil }
			let app = coordinator.runningApp(record.pid)
			return WindowPaletteItem(
				windowID: windowID,
				appName: app?.localizedName ?? (record.appName.isEmpty ? "Unknown App" : record.appName),
				windowTitle: record.title,
				appIcon: app?.icon,
				workspace: workspace,
				monitor: monitor
			)
		}

		var result: [WindowPaletteDisplay] = []
		for (index, monitor) in state.monitorOrder.enumerated() {
			var display = WindowPaletteDisplay(displayNumber: index + 1, monitor: monitor, spaces: [])

			// Windows the user deliberately floated with Ctrl+Option+F
			// They belong to a workspace, but are grouped into a section of their own
			var floatItems: [WindowPaletteItem] = []

			for workspace in state.workspaceOrder(on: monitor) {
				guard let number = state.number(of: workspace) else { continue }
				var items: [WindowPaletteItem] = []
				for windowID in state.orderedWindows(workspace) {
					// Windows hidden (minimized) with Ctrl+Opt+X are listed in the Hidden section
					guard !HiddenWindowManager.shared.isHidden(windowID),
						  let item = item(windowID, workspace: workspace, monitor: monitor) else { continue }
					if state.isFloating(windowID) {
						floatItems.append(item)
					} else {
						items.append(item)
					}
				}

				// Only add Spaces that have windows
				if !items.isEmpty {
					display.spaces.append(WindowPaletteSection(kind: .space(number), items: items))
				}
			}

			if !floatItems.isEmpty {
				display.spaces.append(WindowPaletteSection(kind: .float, items: floatItems))
			}
			result.append(display)
		}

		// --- Add the System section (floating windows not registered to any workspace) to the end of each Display ---
		// Since system-originated floating windows like the Settings app or dialogs aren't registered to a workspace,
		// It doesn't show up in the normal collection. Pick it up here and add it as the "System" section.
		var systemFloatItemsByMonitor: [MonitorKey: [WindowPaletteItem]] = [:]

		for windowID in state.records.keys.sorted() {
			guard let record = state.record(windowID), record.workspace == nil else { continue }
			// Only windows currently shown on screen (minimized and fullscreen ones are in other states)
			guard record.visibility == .visible, record.observed.onScreen else { continue }

			// The monitor the window is on (falls back to the main one if it can't be determined)
			guard let monitor = record.observed.frame.flatMap({ state.monitorKey(for: $0) }) ?? state.primaryMonitor,
				  let item = item(windowID, workspace: nil, monitor: monitor) else { continue }
			systemFloatItemsByMonitor[monitor, default: []].append(item)
		}

		for i in result.indices {
			if let systemFloatItems = systemFloatItemsByMonitor[result[i].monitor], !systemFloatItems.isEmpty {
				result[i].spaces.append(WindowPaletteSection(kind: .system, items: systemFloatItems))
			}
		}

		// --- Add the Hidden section (windows hidden with Ctrl+Opt+X) to the end of each Display ---
		var hiddenItemsByMonitor: [MonitorKey: [WindowPaletteItem]] = [:]
		for windowID in HiddenWindowManager.shared.hiddenWindowIDs {
			guard let location = state.location(windowID),
				  let item = item(windowID, workspace: location.workspace, monitor: location.monitor) else { continue }
			hiddenItemsByMonitor[location.monitor, default: []].append(item)
		}

		for i in result.indices {
			if let hiddenItems = hiddenItemsByMonitor[result[i].monitor], !hiddenItems.isEmpty {
				result[i].spaces.append(WindowPaletteSection(kind: .hidden, items: hiddenItems))
			}
		}

		return result
	}

	/// Switch to the selected window's workspace and focus it
	private func switchToWindowWorkspace(_ item: WindowPaletteItem) {
		// System section windows don't belong to a workspace, so they aren't switched
		if let workspace = item.workspace {
			workspaceManager.switchWorkspace(to: workspace)
		}

		// Focus the target window
		guard let window = TrackingCoordinator.shared.windowInfo(item.windowID) else { return }
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
			window.focus()

			// Move the mouse cursor to the center of the window, where the switch put it
			var current = window
			current.refreshFrame()
			CGWarpMouseCursorPosition(CGPoint(x: current.frame.midX, y: current.frame.midY))

			// Update the border
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
				BorderManager.shared.updateBorder()
			}
		}
	}
}
