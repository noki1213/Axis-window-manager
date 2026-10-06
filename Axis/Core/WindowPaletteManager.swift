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
/// While the palette shows, its session in the tracking state keeps every window out of sight
/// (ending Zen mode); closing it puts them back where the layout says.
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

	private let workspaceManager = WorkspaceManager.shared
	private let accessibilityManager = AccessibilityManager.shared
	private var coordinator: TrackingCoordinator { TrackingCoordinator.shared }

	private init() {}

	// MARK: - Public Methods

	/// Start palette mode: every window leaves the screen (Zen mode ends with it) and the panel
	/// lists them. The titles are those last read from each app; every app is read again right away
	/// and the cards follow when a title changed meanwhile.
	func startPalette() {
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

		// The windows leave the screen while the palette is showing (for visibility)
		let now = ProcessInfo.processInfo.systemUptime
		coordinator.perform("palette") { state in
			state.paletteBegin(now: now)
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

		coordinator.rescanAll { [weak self] in
			self?.refreshAfterRescan()
		}
	}

	/// End palette mode (cancel): the windows come back where the layout puts them
	func endPalette() {
		dismiss()
		endSession()
	}

	/// Close the panel without touching the windows (the tracking state already ended the
	/// palette's session, as it does when the displays change)
	func dismiss() {
		// Close the palette (hide with animation)
		panel?.hidePanel()

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

		// The palette's session ends in the same command that brings the selected window on screen,
		// so the workspace being left never shows in between
		if space.kind == .hidden {
			// Selecting from the Hidden section (windows hidden with Ctrl+Opt+X)
			// Route it through the neighbor-memory restore logic instead of a normal workspace switch
			HiddenWindowManager.shared.restore(windowID: selectedItem.windowID, endingPalette: true)
		} else {
			// Switch to the selected window's workspace
			switchToWindowWorkspace(selectedItem)
		}
		// Nothing to switch or restore (the window is in a workspace shown already, or its state
		// changed meanwhile): the session still ends
		endSession()

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

	// MARK: - Session

	/// Ends the palette's session in the tracking state unless a command already did
	private func endSession() {
		guard coordinator.state.palette != nil else { return }
		coordinator.perform("palette") { state in
			state.paletteEnd()
		}
	}

	/// Every app was read again after the palette opened: show the titles that changed (and any
	/// window that came or went), keeping the selected window selected
	private func refreshAfterRescan() {
		guard !displays.isEmpty, coordinator.state.palette != nil else { return }
		let fresh = collectDisplays()
		guard !fresh.isEmpty, Self.listing(fresh) != Self.listing(displays) else { return }

		let selectedID = selectedItem()?.windowID
		displays = fresh
		if let selectedID, let position = findWindowPosition(windowID: selectedID) {
			(selectedDisplayIndex, selectedSpaceIndex, selectedItemIndex) = position
		} else {
			selectedDisplayIndex = min(selectedDisplayIndex, displays.count - 1)
			clampSelectionToCurrentDisplay()
		}
		panel?.showWithDisplays(
			displays,
			displayIndex: selectedDisplayIndex,
			spaceIndex: selectedSpaceIndex,
			itemIndex: selectedItemIndex
		)
	}

	/// What the cards show, to tell whether a fresh read changed anything
	private static func listing(_ displays: [WindowPaletteDisplay]) -> [String] {
		displays.flatMap { display in
			display.spaces.flatMap { space in
				["\(display.monitor.raw) \(space.kind)"] + space.items.map { "\($0.windowID) \($0.appName) \($0.windowTitle)" }
			}
		}
	}

	/// The window under the selection, if any
	private func selectedItem() -> WindowPaletteItem? {
		guard displays.indices.contains(selectedDisplayIndex) else { return nil }
		let spaces = displays[selectedDisplayIndex].spaces
		guard spaces.indices.contains(selectedSpaceIndex) else { return nil }
		let items = spaces[selectedSpaceIndex].items
		return items.indices.contains(selectedItemIndex) ? items[selectedItemIndex] : nil
	}

	// MARK: - Data Collection

	/// Collect window info for every workspace, grouped by Display. The workspaces, their order and the
	/// windows' titles come from the tracking state
	private func collectDisplays() -> [WindowPaletteDisplay] {
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
			// Only windows that would be on screen: shown, or out of sight for the palette (minimized
			// and fullscreen ones are in other states)
			guard record.visibility == .visible || record.visibility == .paletteHidden, record.observed.onScreen else { continue }

			// The monitor the window is on, or was on before the palette took it out of sight (falls
			// back to the main one if it can't be determined)
			let shownFrame = record.visibility == .visible ? record.observed.frame : record.lastVisibleFrame ?? record.observed.frame
			guard let monitor = shownFrame.flatMap({ state.monitorKey(for: $0) }) ?? state.primaryMonitor,
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

	/// Switch to the selected window's workspace (ending the palette's session in the same command)
	/// and focus it
	private func switchToWindowWorkspace(_ item: WindowPaletteItem) {
		// System section windows don't belong to a workspace, so they aren't switched
		if let workspace = item.workspace, !coordinator.state.isActive(workspace) {
			workspaceManager.switchWorkspace(to: workspace, endingPalette: true)
		}

		// Focus the target window
		guard let window = coordinator.windowInfo(item.windowID) else { return }
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
