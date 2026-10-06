//
//  HiddenWindowManager.swift
//  Axis
//
//  Manages the window "hide/restore" feature
//

import AppKit

/// Hides windows (native minimize) and restores them next to the neighbors they had
///
/// Hide: the window goes on the tracking state's hide stack. It leaves its column, remembering the
/// windows above, below, left and right of it, and the plan minimizes it; the remaining tiles close
/// the gap.
///
/// Restore: the window leaves the stack and goes back into its own workspace (even if that
/// workspace was renumbered meanwhile): next to a neighbor that was in its column, else as a new
/// column next to a neighboring column, else at the end. The plan unminimizes it and lays it out,
/// or parks it when its workspace is not shown. A restore from the Dock is seen in the window facts
/// (the window is no longer minimized) and handled the same way.
class HiddenWindowManager {
	static let shared = HiddenWindowManager()

	private let accessibilityManager = AccessibilityManager.shared
	private let tilingEngine = TilingEngine.shared
	private var coordinator: TrackingCoordinator { TrackingCoordinator.shared }

	private init() {}

	// MARK: - Queries

	/// Whether the given window is hidden by Axis
	func isHidden(_ windowID: CGWindowID) -> Bool {
		coordinator.state.hiddenStack.contains { $0.window == windowID }
	}

	/// The hidden windows, the most recently hidden last
	var hiddenWindowIDs: [CGWindowID] {
		coordinator.state.hiddenStack.map(\.window)
	}

	// MARK: - Hide

	/// Hide the focused window (Ctrl+Opt+X)
	func hideFocusedWindow() {
		guard let focusedWindow = accessibilityManager.getFocusedWindow() else { return }
		guard !isHidden(focusedWindow.id), let location = coordinator.state.location(focusedWindow.id) else { return }

		coordinator.perform("hide") { state in
			state.hide(focusedWindow.id)
		}

		// Move focus to a suitable remaining window in the same workspace
		focusFirstRemainingWindow(in: location.workspace)

		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
			BorderManager.shared.updateBorder()
		}
	}

	/// Right after hiding it, if that workspace is still showing, move focus to the first remaining tile
	private func focusFirstRemainingWindow(in workspace: WorkspaceID) {
		let state = coordinator.state
		guard state.isActive(workspace),
			  let firstID = state.layoutColumns(workspace).first?.first,
			  let firstWindow = coordinator.windowInfo(firstID) else { return }
		firstWindow.focus()
		tilingEngine.moveCursorToWindow(firstWindow)
	}

	// MARK: - Restore

	/// Restore the most recently hidden window (Ctrl+Opt+Shift+X)
	func unhideLast() {
		guard let last = coordinator.state.hiddenStack.last?.window else { return }
		restore(windowID: last)
	}

	/// Restore the given window (also used by the Hidden section of the window palette)
	/// - Parameter endingPalette: the palette's session ends with the same command, so the windows
	///   it took out of sight come back already in the layout with the restored window
	func restore(windowID: CGWindowID, endingPalette: Bool = false) {
		guard isHidden(windowID) else { return }
		coordinator.perform("unhide") { state in
			if endingPalette {
				state.paletteEnd()
			}
			state.restoreHidden(windowID, userInitiated: false)
		}

		// A window restored into the workspace on screen takes focus
		guard let workspace = coordinator.state.record(windowID)?.workspace, coordinator.state.isActive(workspace),
			  let window = coordinator.windowInfo(windowID) else { return }
		window.focus()
		tilingEngine.moveCursorToWindow(window)

		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
			BorderManager.shared.updateBorderExpecting(windowID: windowID)
		}
	}
}
