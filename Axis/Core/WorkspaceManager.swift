//
//  WorkspaceManager.swift
//  Axis
//
//  Created on 2026/01/27.
//
//  The workspace operations the rest of the app calls by screen and workspace number. The
//  tracking state holds every workspace, its columns and its windows; this facade converts
//  screens to monitor keys and numbers to workspace ids, runs the commands, and does the focus,
//  border and cursor follow-up a switch needs.
//

import AppKit

/// Workspaces per screen (in the manner of macOS Spaces), kept in the tracking state
class WorkspaceManager {
	static let shared = WorkspaceManager()

	private let accessibilityManager = AccessibilityManager.shared
	private var coordinator: TrackingCoordinator { TrackingCoordinator.shared }
	private var state: TrackingState { coordinator.state }
	/// A workspace-change notice is on its way (several windows closing at once send one)
	private var isWorkspaceChangePosted = false

	private init() {}

	// MARK: - Start and quit

	/// Starts tracking: the workspaces and columns saved when Axis last quit come back for the
	/// windows that still exist; the other windows join the shown workspace of the display they
	/// are on (an empty workspace 0 when nothing was saved). `ready` runs once the windows are
	/// laid out.
	func start(ready: @escaping () -> Void) {
		coordinator.addEventHandler { [weak self] event in
			self?.handle(event)
		}
		coordinator.onDisplaySetChanging = { [weak self] in
			self?.closePaletteForScreenChange()
		}
		coordinator.onStarted = ready
		coordinator.start(config: TilingEngine.shared.layoutConfig)
	}

	/// Saves the layout, puts every window moved out of sight back on screen (those of Zen mode
	/// and the palette too) and stops tracking
	func prepareForQuit() {
		coordinator.prepareForQuit()
		coordinator.stop()
	}

	/// What the other components do when windows come and go or a workspace changes on its own
	private func handle(_ event: TrackingEvent) {
		switch event {
		case .admitted:
			PlacementReservationManager.shared.noteWindowAdmitted()
		case .retired:
			// Dropping an emptied workspace can renumber the others
			postWorkspaceChangedOnce()
		case .rekeyed(let old, let new):
			FocusHistoryManager.shared.replace(old, with: new)
		case .activeChanged(_, _, let workspace, let cause):
			activeWorkspaceChanged(to: workspace, cause: cause)
		case .returnFocus(let bundleID):
			LaunchAsideManager.shared.returnFocus(ifTakenBy: bundleID)
		case .zenEnded:
			ZenModeManager.shared.noteEnded()
		case .focusChanged:
			break
		}
	}

	// MARK: - Float (floating)

	/// Toggle the window's Float state
	/// A window that's Float is excluded from tiling and floats where it is put
	func toggleFloat(windowID: CGWindowID) {
		coordinator.perform("float") { state in
			state.toggleFloat(windowID)
		}
	}

	/// The windows that are Float
	var floatWindowIDs: Set<CGWindowID> {
		Set(state.records.values.filter { $0.placement == .floating }.map(\.id))
	}

	// MARK: - Screens and monitor keys

	func monitorKey(for screen: NSScreen) -> MonitorKey? {
		DisplayReader.monitorKey(for: screen)
	}

	func screen(for key: MonitorKey) -> NSScreen? {
		DisplayReader.screen(for: key)
	}

	// MARK: - Queries

	/// Get the given monitor's current workspace number
	func currentWorkspace(on screen: NSScreen) -> Int {
		guard let key = monitorKey(for: screen), let active = state.activeWorkspace(key) else { return 0 }
		return state.number(of: active) ?? 0
	}

	/// The windows of the given monitor's current workspace
	func windowIDsForCurrentWorkspace(on screen: NSScreen) -> Set<CGWindowID> {
		guard let key = monitorKey(for: screen), let active = state.activeWorkspace(key) else { return [] }
		return Set(state.members(of: active))
	}

	/// Return the monitor the given window belongs to
	func screenForWindow(_ windowID: CGWindowID) -> NSScreen? {
		state.location(windowID).flatMap { screen(for: $0.monitor) }
	}

	/// Return the monitor and workspace number the given window belongs to
	func workspaceLocation(for windowID: CGWindowID) -> (screen: NSScreen, workspace: Int)? {
		guard let location = state.location(windowID), let screen = screen(for: location.monitor) else { return nil }
		return (screen, location.number)
	}

	/// Whether the window belongs to a workspace (tiled or Float)
	func isWindowInAnyWorkspace(_ windowID: CGWindowID) -> Bool {
		state.record(windowID)?.workspace != nil
	}

	/// Whether the window is tracked at all, including windows that float on their own (dialogs,
	/// small windows) and belong to no workspace
	func isTracked(_ windowID: CGWindowID) -> Bool {
		state.isTracked(windowID)
	}

	// MARK: - Workspace Switching

	/// Switch workspaces
	/// - Parameters:
	///   - workspace: the workspace number being switched to
	///   - screen: the target monitor
	///   - focusWindowID: the window ID to focus after switching (defaults to the first window if omitted)
	func switchWorkspace(to workspace: Int, on screen: NSScreen, focusWindowID: CGWindowID? = nil) {
		switchWorkspace(.number(workspace), number: workspace, on: screen, focusWindowID: focusWindowID)
	}

	/// Switch to a workspace by its id, on the monitor that shows it (the palette lists workspaces
	/// by id, so a renumbering while it was open does not send it elsewhere)
	/// - Parameter endingPalette: the palette's session ends with the same command, so the windows
	///   it took out of sight come back already in the new layout
	func switchWorkspace(to workspace: WorkspaceID, focusWindowID: CGWindowID? = nil, endingPalette: Bool = false) {
		guard let host = state.workspaces[workspace]?.host, let screen = screen(for: host),
			  let number = state.number(of: workspace) else { return }
		switchWorkspace(.id(workspace), number: number, on: screen, focusWindowID: focusWindowID, endingPalette: endingPalette)
	}

	/// Move to the next workspace (+1), created past the last one
	func switchToNextWorkspace(on screen: NSScreen) {
		switchWorkspace(.next, number: currentWorkspace(on: screen) + 1, on: screen)
	}

	/// Move to the previous workspace (-1), created before the first one
	func switchToPreviousWorkspace(on screen: NSScreen) {
		switchWorkspace(.prev, number: currentWorkspace(on: screen) - 1, on: screen)
	}

	/// `number`: the workspace number the target has before the switch, for the log
	private func switchWorkspace(_ target: WorkspaceTarget, number: Int, on screen: NSScreen, focusWindowID: CGWindowID? = nil,
		endingPalette: Bool = false) {
		guard let key = monitorKey(for: screen) else { return }
		let current = currentWorkspace(on: screen)
		guard number != current else { return }

		coordinator.beginTransition()
		PerfLog.event("workspace: switch \(PerfLog.describe(screen)) ws\(current + 1) -> ws\(number + 1)"
			+ (focusWindowID.map { " (focus #\($0))" } ?? ""))

		// The new workspace's windows come on screen first; the old ones leave a moment later,
		// so an empty screen never shows
		var destination: WorkspaceID?
		coordinator.perform("switch", delaysHidePhase: true) { state in
			if endingPalette {
				state.paletteEnd()
			}
			destination = state.switchWorkspace(on: key, to: target)
		}
		finishSwitch(to: destination, focusWindowID: focusWindowID)
	}

	// MARK: - Move Window to Workspace

	/// Move the focused window to the next workspace (the space switches immediately too)
	func moveWindowToNextWorkspace(on screen: NSScreen) {
		moveFocusedWindow(to: .next, number: currentWorkspace(on: screen) + 1, on: screen)
	}

	/// Move the focused window to the previous workspace (the space switches immediately too)
	func moveWindowToPreviousWorkspace(on screen: NSScreen) {
		moveFocusedWindow(to: .prev, number: currentWorkspace(on: screen) - 1, on: screen)
	}

	/// The window joins the destination and the screen switches there with it, so it stays in view.
	/// The workspace it left is dropped when it became empty.
	private func moveFocusedWindow(to target: WorkspaceTarget, number: Int, on screen: NSScreen) {
		guard let focusedID = accessibilityManager.getFocusedWindowID(), state.isTracked(focusedID),
			  let key = monitorKey(for: screen) else { return }

		coordinator.beginTransition()
		PerfLog.event("workspace: switch \(PerfLog.describe(screen)) ws\(currentWorkspace(on: screen) + 1) -> ws\(number + 1)"
			+ " (focus #\(focusedID))")

		var destination: WorkspaceID?
		coordinator.perform("move to workspace", delaysHidePhase: true) { state in
			destination = state.moveWindowToWorkspace(focusedID, on: key, to: target)
		}
		finishSwitch(to: destination, focusWindowID: focusedID)
	}

	/// Focus, border, cursor and menu bar after a switch
	private func finishSwitch(to destination: WorkspaceID?, focusWindowID: CGWindowID?) {
		var focusedID: CGWindowID?
		if let focusWindowID, let window = coordinator.windowInfo(focusWindowID) {
			window.focus()
			focusedID = focusWindowID
		} else if let destination {
			focusedID = focusFirstWindow(in: destination)
		}
		syncBorderAndCursor(to: focusedID)
		NotificationCenter.default.post(name: .workspaceChanged, object: nil)
	}

	private func postWorkspaceChangedOnce() {
		guard !isWorkspaceChangePosted else { return }
		isWorkspaceChangePosted = true
		DispatchQueue.main.async { [weak self] in
			self?.isWorkspaceChangePosted = false
			NotificationCenter.default.post(name: .workspaceChanged, object: nil)
		}
	}

	/// The state switched a monitor to another workspace on its own: the active one emptied and
	/// was dropped (its neighbour is shown now), or a display came or went
	private func activeWorkspaceChanged(to workspace: WorkspaceID, cause: ActiveChangeCause) {
		guard cause != .command else { return }
		if cause == .compaction {
			focusFirstWindow(in: workspace)
		}
		NotificationCenter.default.post(name: .workspaceChanged, object: nil)
		DispatchQueue.main.async {
			BorderManager.shared.updateBorder()
		}
	}

	/// Focus the first window shown in the workspace: the first tile, else a Float window. Windows of
	/// an app that is not answering are passed over: focusing one would keep the main thread waiting
	/// for the app, and the old workspace's windows would stay on screen meanwhile.
	/// - Returns: the ID of the window that was actually focused (nil if there was no target)
	@discardableResult
	private func focusFirstWindow(in workspace: WorkspaceID) -> CGWindowID? {
		for id in state.orderedWindows(workspace) where !state.isHidden(id) {
			guard state.isFocusable(id) else {
				PerfLog.event("focus: skip \(state.describe(id)) (its app is not answering)")
				continue
			}
			if let window = coordinator.windowInfo(id) {
				window.focus()
				return id
			}
		}
		return nil
	}

	/// Handle the post-focus-move border update and cursor movement together
	/// - Border: retries until focus actually moves to the target window before updating
	///   (Prevents the border from landing on the wrong window when macOS is slow to reflect focus)
	/// - Cursor: moves to the center of the window, same as JKLI focus movement
	/// - Parameter windowID: the ID of the window that was focused (nil just updates the border once)
	private func syncBorderAndCursor(to windowID: CGWindowID?) {
		guard let windowID = windowID else {
			// If there's nothing to focus (e.g. an empty workspace), just update the border
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
				BorderManager.shared.updateBorder()
			}
			return
		}

		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
			guard let self = self else { return }

			// Retry until focus actually moves to the target window before updating the border
			BorderManager.shared.updateBorderExpecting(windowID: windowID)

			// Move the mouse cursor to the center of the focused window
			if let window = self.coordinator.windowInfo(windowID) {
				TilingEngine.shared.moveCursorToWindow(window)
			}
		}
	}

	// MARK: - Display changes

	/// The palette is laid out for the old screens, so it closes before the screens change (the
	/// tracking state ended its session, and the windows come back with the next layout)
	private func closePaletteForScreenChange() {
		guard HotkeyManager.shared.currentMode == .windowPalette else { return }
		WindowPaletteManager.shared.dismiss()
		HotkeyManager.shared.currentMode = .normal
		NotificationCenter.default.post(name: .modeChanged, object: HotkeyManager.Mode.normal)
	}

	// MARK: - Focused monitor

	/// Return the focused monitor's workspace number (used for the menu bar display)
	func currentWorkspaceForFocusedScreen() -> Int {
		guard let screen = focusedScreen() else { return 0 }
		return currentWorkspace(on: screen)
	}

	/// Get the focused monitor: the one holding the focused window, else the one under the mouse
	func focusedScreen() -> NSScreen? {
		if let focusedWindow = accessibilityManager.getFocusedWindow(),
		   let screen = NSScreen.screens.first(where: { $0.frame.contains(focusedWindow.centerInScreenCoordinates) }) {
			return screen
		}

		// If there's no focused window, use the monitor the mouse cursor is on
		let mouseLocation = NSEvent.mouseLocation
		if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
			return screen
		}

		return NSScreen.main
	}
}

// MARK: - Notification Names

extension Notification.Name {
	static let workspaceChanged = Notification.Name("workspaceChanged")
}
