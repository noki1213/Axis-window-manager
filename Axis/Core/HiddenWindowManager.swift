//
//  HiddenWindowManager.swift
//  Axis
//
//  Manages the window "hide/restore" feature
//

import AppKit

/// A memory record for a single hidden window (used by the "neighbor memory" restoration scheme)
struct HiddenWindowRecord {
	let windowID: CGWindowID
	let screenID: ScreenIdentifier
	let workspace: Int
	/// The window above it in the same column (nil if there isn't one)
	let aboveNeighborID: CGWindowID?
	/// The window below it in the same column (nil if there isn't one)
	let belowNeighborID: CGWindowID?
	/// The representative window of the left column (nil if there isn't one)
	let leftColumnRepID: CGWindowID?
	/// The representative window of the right column (nil if there isn't one)
	let rightColumnRepID: CGWindowID?
}

/// Manages hiding (native minimize) and restoring windows
///
/// Hide: set the focused window's AXMinimized to true.
/// Since TilingEngine.tile() automatically excludes minimized windows from management,
/// The remaining tiles get repacked and repositioned (this class doesn't need to touch the column structure directly).
///
/// Restore: remember the IDs of the windows above/below/left/right at the moment it was hidden, and
/// 1. If a neighbor (above/below) that was in the same column is still there, insert next to it
/// 2. If the whole column vanished, insert as a new column next to a representative window of the left/right column
/// 3. If neighbors are also all gone, append it as a new column at the end of the original workspace
///
/// A manual restore from the Dock (AXMinimized going back to false) is caught by AppDelegate's existing
/// checkForManualRestores() rides along with the window-change watcher (checkForWindowChanges, on a 0.3s cycle)
/// Detected by piggybacking on it. No new polling timer is added.
class HiddenWindowManager {
	static let shared = HiddenWindowManager()

	/// The stack of hidden windows (the last element is the most recently hidden)
	private(set) var hiddenStack: [HiddenWindowRecord] = []

	private let accessibilityManager = AccessibilityManager.shared
	private let workspaceManager = WorkspaceManager.shared
	private let tilingEngine = TilingEngine.shared

	private init() {}

	// MARK: - Queries

	/// Whether the given window is hidden by Axis
	func isHidden(_ windowID: CGWindowID) -> Bool {
		return hiddenStack.contains { $0.windowID == windowID }
	}

	/// When a window is genuinely closed (or the whole app quits),
	/// Remove it from the hidden list if it's still there (called from AppDelegate's closed-window handling)
	func forgetIfPresent(_ windowID: CGWindowID) {
		hiddenStack.removeAll { $0.windowID == windowID }
	}

	// MARK: - Hide

	/// Hide the focused window (Ctrl+Opt+X)
	func hideFocusedWindow() {
		guard let focusedWindow = accessibilityManager.getFocusedWindow() else { return }
		guard !isHidden(focusedWindow.id) else { return }

		guard let screen = workspaceManager.screenForWindow(focusedWindow.id) else { return }
		let screenID = workspaceManager.screenIdentifier(for: screen)
		let workspace = workspaceManager.currentWorkspace(on: screen)

		// Record neighbor info from the column structure before hiding it
		let columns = tilingEngine.tiledWindows[screenID] ?? []
		var aboveID: CGWindowID?
		var belowID: CGWindowID?
		var leftRepID: CGWindowID?
		var rightRepID: CGWindowID?

		if let (columnIndex, rowIndex) = tilingEngine.findWindowPosition(window: focusedWindow, in: columns) {
			let column = columns[columnIndex]
			if rowIndex > 0 { aboveID = column[rowIndex - 1].id }
			if rowIndex < column.count - 1 { belowID = column[rowIndex + 1].id }
			if columnIndex > 0 { leftRepID = columns[columnIndex - 1].first?.id }
			if columnIndex < columns.count - 1 { rightRepID = columns[columnIndex + 1].first?.id }
		}

		hiddenStack.append(HiddenWindowRecord(
			windowID: focusedWindow.id,
			screenID: screenID,
			workspace: workspace,
			aboveNeighborID: aboveID,
			belowNeighborID: belowID,
			leftColumnRepID: leftRepID,
			rightColumnRepID: rightRepID
		))

		// Native minimize (AXMinimized). It moves outside of tiling, so drop the cache
		focusedWindow.minimize()
		accessibilityManager.invalidateWindowCache()

		// Compact and rearrange the remaining tiles (tile() automatically excludes minimized windows)
		tilingEngine.tile(on: screen)

		// Move focus to a suitable remaining window in the same workspace
		focusFirstRemainingWindow(screenID: screenID, workspace: workspace)

		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
			BorderManager.shared.updateBorder()
		}
	}

	/// Right after hiding it, if that workspace is still showing, move focus to the first remaining window
	private func focusFirstRemainingWindow(screenID: ScreenIdentifier, workspace: Int) {
		guard let screen = workspaceManager.screen(for: screenID) else { return }
		guard workspaceManager.currentWorkspace(on: screen) == workspace else { return }

		let columns = tilingEngine.tiledWindows[screenID] ?? []
		guard let firstWindow = columns.first?.first else { return }
		firstWindow.focus()
		tilingEngine.moveCursorToWindow(firstWindow)
	}

	// MARK: - Restore

	/// Restore the most recently hidden window (Ctrl+Opt+Shift+X)
	func unhideLast() {
		guard let record = hiddenStack.last else { return }
		restore(record: record)
	}

	/// Restore the given window. Used by selecting the Hidden section in the window palette,
	/// The shared path for manual-restore detection from the Dock (checkForManualRestores)
	func restore(windowID: CGWindowID) {
		guard let record = hiddenStack.first(where: { $0.windowID == windowID }) else { return }
		restore(record: record)
	}

	/// Check whether the user manually unminimized it, e.g. via the Dock.
	/// Intended to be called every cycle, piggybacking on AppDelegate's existing window-change monitoring (a 0.3s interval), and
	/// This class doesn't keep a new timer of its own
	func checkForManualRestores(allWindows: [WindowInfo]) {
		guard !hiddenStack.isEmpty else { return }
		let windowsByID = Dictionary(uniqueKeysWithValues: allWindows.map { ($0.id, $0) })

		// Since restore() rewrites the stack, pin down the target first before processing
		let targets = hiddenStack.filter { record in
			guard let window = windowsByID[record.windowID] else { return false }
			return !window.isMinimized
		}
		for record in targets {
			restore(record: record)
		}
	}

	private func restore(record: HiddenWindowRecord) {
		hiddenStack.removeAll { $0.windowID == record.windowID }

		let allWindows = accessibilityManager.getAllWindows()
		guard let window = allWindows.first(where: { $0.id == record.windowID }) else { return }

		// Unminimize it (harmless no-op if called from manual-restore detection via the Dock, since it's already unminimized)
		window.unminimize()
		accessibilityManager.invalidateWindowCache()

		guard let screen = workspaceManager.screen(for: record.screenID) else {
			// Give up on restoring if the monitor isn't connected
			return
		}

		if workspaceManager.currentWorkspace(on: screen) == record.workspace {
			restoreIntoActiveWorkspace(window: window, record: record, screen: screen)
		} else {
			// For restoring into a workspace that isn't currently shown, just update the column structure.
			// The window is still visible on screen right after being unminimized, but
			// The AppDelegate.checkForWindowChanges that runs right after this
			// hideStrayVisibleWindows (for windows whose registered workspace is inactive
			// the existing mechanism that stashes on-screen windows into a hidden corner)
			// It gets picked up within the same cycle, so don't place it manually here
			restoreIntoInactiveWorkspace(record: record)
		}
	}

	/// Restore into the currently active workspace (insert directly into tiling and show it)
	private func restoreIntoActiveWorkspace(window: WindowInfo, record: HiddenWindowRecord, screen: NSScreen) {
		var columns = tilingEngine.tiledWindows[record.screenID] ?? []
		let idColumns = columns.map { $0.map { $0.id } }
		let insertion = HiddenWindowManager.computeInsertion(current: idColumns, record: record)

		switch insertion {
		case .intoColumn(let columnIndex, let rowIndex):
			if columnIndex >= 0 && columnIndex < columns.count {
				let clampedRow = min(max(rowIndex, 0), columns[columnIndex].count)
				columns[columnIndex].insert(window, at: clampedRow)
			} else {
				columns.append([window])
			}
		case .newColumn(let index):
			let clampedIndex = min(max(index, 0), columns.count)
			columns.insert([window], at: clampedIndex)
		}

		tilingEngine.tiledWindows[record.screenID] = columns
		tilingEngine.tile(on: screen)

		window.focus()
		tilingEngine.moveCursorToWindow(window)

		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [windowID = window.id] in
			BorderManager.shared.updateBorderExpecting(windowID: windowID)
		}
	}

	/// Restore into a workspace that isn't currently active (only update the ID-based column structure)
	private func restoreIntoInactiveWorkspace(record: HiddenWindowRecord) {
		let idColumns = workspaceManager.columnsSnapshot(on: record.screenID, workspace: record.workspace) ?? []
		let insertion = HiddenWindowManager.computeInsertion(current: idColumns, record: record)
		var newColumns = idColumns

		switch insertion {
		case .intoColumn(let columnIndex, let rowIndex):
			if columnIndex >= 0 && columnIndex < newColumns.count {
				let clampedRow = min(max(rowIndex, 0), newColumns[columnIndex].count)
				newColumns[columnIndex].insert(record.windowID, at: clampedRow)
			} else {
				newColumns.append([record.windowID])
			}
		case .newColumn(let index):
			let clampedIndex = min(max(index, 0), newColumns.count)
			newColumns.insert([record.windowID], at: clampedIndex)
		}

		workspaceManager.updateColumnsSnapshot(newColumns, on: record.screenID, workspace: record.workspace)
	}

	// MARK: - Determining the restore position (the neighbor-memory approach)

	/// The result of deciding the restore position
	private enum Insertion {
		/// Insert it at the given row of the given column (when the original column still exists)
		case intoColumn(columnIndex: Int, rowIndex: Int)
		/// Insert it at the given index as a new standalone column
		case newColumn(index: Int)
	}

	/// Decide the restore position based on neighbor memory. Since it's built on an ID basis,
	/// The same logic can be used for the column structure of both active and inactive workspaces
	private static func computeInsertion(current columns: [[CGWindowID]], record: HiddenWindowRecord) -> Insertion {
		func position(of id: CGWindowID) -> (columnIndex: Int, rowIndex: Int)? {
			for (columnIndex, column) in columns.enumerated() {
				if let rowIndex = column.firstIndex(of: id) {
					return (columnIndex, rowIndex)
				}
			}
			return nil
		}

		// 1. The original column still exists (the up/down neighbor that was in the same column is still there) -> insert next to it
		if let aboveID = record.aboveNeighborID, let pos = position(of: aboveID) {
			return .intoColumn(columnIndex: pos.columnIndex, rowIndex: pos.rowIndex + 1)
		}
		if let belowID = record.belowNeighborID, let pos = position(of: belowID) {
			return .intoColumn(columnIndex: pos.columnIndex, rowIndex: pos.rowIndex)
		}

		// 2. The column is gone, but a representative window in a neighboring column still exists -> insert a new column next to it
		if let leftRepID = record.leftColumnRepID, let pos = position(of: leftRepID) {
			return .newColumn(index: pos.columnIndex + 1)
		}
		if let rightRepID = record.rightColumnRepID, let pos = position(of: rightRepID) {
			return .newColumn(index: pos.columnIndex)
		}

		// 3. No neighbors survived either -> append a new column to the end of the original workspace
		return .newColumn(index: columns.count)
	}
}
