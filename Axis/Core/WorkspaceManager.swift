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

	/// Whether a workspace switch is in progress (used to prevent checkForWindowChanges from misfiring)
	var isSwitching: Bool = false

	private let accessibilityManager = AccessibilityManager.shared
	private var coordinator: TrackingCoordinator { TrackingCoordinator.shared }
	private var state: TrackingState { coordinator.state }

	private init() {}

	// MARK: - Start and quit

	/// Starts the tracking state with the connected displays, each showing an empty workspace 0
	func start() {
		coordinator.onActiveChanged = { [weak self] _, _, workspace, cause in
			self?.activeWorkspaceChanged(to: workspace, cause: cause)
		}
		coordinator.externallyPositioned = { [weak self] in
			self?.externallyPositionedWindows() ?? []
		}
		coordinator.start(mode: .stateOnly, config: TilingEngine.shared.layoutConfig, relaunchTiled: Self.tiledAtLastQuit())
	}

	/// Puts every window moved out of sight back on screen and stops tracking
	func prepareForQuit() {
		coordinator.prepareForQuit()
		coordinator.stop()
	}

	// MARK: - Float (floating)

	/// Toggle the window's Float state
	/// A window that's Float is excluded from tiling and floats where it is put
	func toggleFloat(windowID: CGWindowID) {
		coordinator.perform("float") { state in
			state.toggleFloat(windowID)
		}
	}

	/// Returns whether the window is currently Float
	func isFloating(_ windowID: CGWindowID) -> Bool {
		state.isFloating(windowID)
	}

	/// The windows that are Float
	var floatWindowIDs: Set<CGWindowID> {
		Set(state.records.values.filter { $0.placement == .floating }.map(\.id))
	}

	// MARK: - Tiled windows across a relaunch

	private static let tiledAtQuitKey = "tiledWindowIDsAtQuit"

	/// Windows that were tiled when Axis last quit. Their windows outlive Axis, so on the next
	/// launch these are tiled again even when a stacked column left them small enough to look
	/// like dialogs.
	private static func tiledAtLastQuit() -> Set<WindowID> {
		let ids = UserDefaults.standard.array(forKey: tiledAtQuitKey) as? [UInt32] ?? []
		return Set(ids)
	}

	func wasTiledBeforeRelaunch(_ windowID: CGWindowID) -> Bool {
		state.relaunchTiled.contains(windowID)
	}

	/// Record the tiled windows so the next launch can tell them from genuinely small windows
	func rememberTiledWindowsForRelaunch() {
		let ids = state.records.values.filter { $0.workspace != nil && $0.placement == .tiled }.map(\.id)
		UserDefaults.standard.set(ids.map { UInt32($0) }, forKey: Self.tiledAtQuitKey)
	}

	// MARK: - Screens and monitor keys

	func monitorKey(for screen: NSScreen) -> MonitorKey? {
		DisplayReader.monitorKey(for: screen)
	}

	func screen(for key: MonitorKey) -> NSScreen? {
		DisplayReader.screen(for: key)
	}

	/// The connected monitors in screen order
	var monitorKeys: [MonitorKey] {
		state.monitorOrder
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

	/// Whether the window is out of sight: in another workspace, minimized or otherwise not shown
	/// according to the tracking state, or parked by Zen or the palette
	func isWindowHidden(_ windowID: CGWindowID) -> Bool {
		state.isHidden(windowID)
			|| ZenModeManager.shared.hiddenWindowIDs.contains(windowID)
			|| WindowPaletteManager.shared.isWindowHidden(windowID)
	}

	/// One line per monitor describing its workspaces, for diagnosing monitor-change layouts
	func layoutSummaryLines() -> [String] {
		state.monitorOrder.compactMap { key in
			guard let monitor = state.monitors[key] else { return nil }
			let spaces = monitor.order.map { workspace in
				let ids = state.orderedWindows(workspace).map(String.init).joined(separator: ",")
				return "\(state.describeWorkspace(workspace))=[\(ids)]"
			}.joined(separator: " ")
			return "\(monitor.name) active=\(state.describeWorkspace(monitor.active)) \(spaces)"
		}
	}

	// MARK: - Windows found by the window list

	/// Starts tracking the windows on screen when window management starts: each joins the
	/// active workspace (number 0) of the monitor holding it
	func registerCurrentWindows() {
		let onScreenIDs = accessibilityManager.getOnScreenWindowIDs()
		let windows = accessibilityManager.getAllWindows().filter {
			onScreenIDs.contains($0.id) && $0.shouldBeManaged() && !state.isTracked($0.id)
		}
		guard !windows.isEmpty else { return }
		let now = Self.uptime()
		for window in windows {
			ElementCache.shared.store(window: window.id, pid: window.app.processIdentifier, element: window.axElement)
		}
		coordinator.perform("startup") { state in
			for window in windows {
				state.admit(WindowFacts(info: window, takenAt: now), app: Self.appFacts(window.app), source: .startup, now: now)
			}
		}
	}

	/// Starts tracking a window the window list found. Where it goes follows the tracking state's
	/// rules: a just-opened window (`.created`) joins the monitor that had focus or a placement
	/// reservation, any other the monitor holding it; dialogs and small windows float on their own.
	/// Returns whether it is tracked now.
	@discardableResult
	func register(_ window: WindowInfo, source: AdmissionSource) -> Bool {
		guard !state.isTracked(window.id) else { return true }
		let now = Self.uptime()
		ElementCache.shared.store(window: window.id, pid: window.app.processIdentifier, element: window.axElement)
		coordinator.perform("register") { state in
			Self.forgetRetirement(of: window.id, in: &state)
			state.admit(WindowFacts(info: window, takenAt: now), app: Self.appFacts(window.app), source: source, now: now)
		}
		PlacementReservationManager.shared.noteWindowRegistered()
		return state.isTracked(window.id)
	}

	/// Starts tracking a window of an app launched aside: it joins `workspace` (a new one at the
	/// end of `monitor` when nil or gone) out of sight, floating when it would not tile.
	/// Returns the workspace it joined.
	func registerOutOfSight(_ window: WindowInfo, on monitor: MonitorKey, workspace: WorkspaceID?) -> WorkspaceID? {
		guard let bundleID = window.app.bundleIdentifier, !state.isTracked(window.id) else { return nil }
		let now = Self.uptime()
		ElementCache.shared.store(window: window.id, pid: window.app.processIdentifier, element: window.axElement)
		var joined: WorkspaceID?
		coordinator.perform("launch-aside") { state in
			Self.forgetRetirement(of: window.id, in: &state)
			let existing = workspace.flatMap { state.workspaces[$0] != nil ? $0 : nil }
			// The launch-aside manager keeps the app's entry and its timing; the state's entry
			// lives only while this window is placed by it.
			state.launchAside[bundleID] = LaunchAsideEntry(bundleID: bundleID, monitor: monitor, deadline: now + 1,
				workspace: existing)
			if let id = state.admit(WindowFacts(info: window, takenAt: now), app: Self.appFacts(window.app),
				source: .created, now: now) {
				joined = state.record(id)?.workspace
			}
			state.launchAside[bundleID] = nil
		}
		return joined
	}

	/// Stops tracking windows the window list no longer shows (closed, or their app quit)
	func retire(_ windowIDs: [CGWindowID]) {
		let tracked = windowIDs.filter { state.isTracked($0) }
		guard !tracked.isEmpty else { return }
		let now = Self.uptime()
		coordinator.perform("retire") { state in
			for id in tracked {
				state.retire(id, reason: .destroyed, now: now)
			}
		}
		NotificationCenter.default.post(name: .workspaceChanged, object: nil)
	}

	/// After waking from sleep: windows the window server no longer has are retired, and windows
	/// on screen that are not tracked are admitted. A window that came back under a new ID with the
	/// same app and title takes the old one's place.
	func rematchAfterWake() {
		let onScreenIDs = accessibilityManager.getOnScreenWindowIDs()
		let windows = accessibilityManager.getAllWindows().filter {
			onScreenIDs.contains($0.id) && $0.shouldBeManaged() && !state.isTracked($0.id)
		}
		let now = Self.uptime()
		for window in windows {
			ElementCache.shared.store(window: window.id, pid: window.app.processIdentifier, element: window.axElement)
		}
		coordinator.perform("wake") { state in
			Self.retireVanishedWindows(in: &state, keepingActive: false, now: now)
			for window in windows {
				state.admit(WindowFacts(info: window, takenAt: now), app: Self.appFacts(window.app), source: .discovered, now: now)
			}
		}
		NotificationCenter.default.post(name: .workspaceChanged, object: nil)
	}

	/// Facts of tracked windows from a full window-list reading: minimized, fullscreen, restored
	/// from the Dock, titles
	func ingestWindowList(_ windows: [WindowInfo]) {
		let now = Self.uptime()
		let facts = windows.filter { state.isTracked($0.id) }.map { WindowFacts(info: $0, takenAt: now) }
		guard !facts.isEmpty else { return }
		coordinator.ingestWindowFacts(facts)
	}

	/// The focused window as the window list saw it. A tracked one decides the monitor windows
	/// opened from now on join.
	func noteFocusedWindow(_ window: WindowInfo) {
		let state = self.state
		let current: WindowID? = state.isTracked(window.id) ? window.id : nil
		let monitor = state.location(window.id)?.monitor
			?? state.record(window.id)?.observed.frame.flatMap { state.monitorKey(for: $0) }
		guard state.focus.current != current || state.focus.currentMonitor != monitor else { return }
		let now = Self.uptime()
		let facts = FocusFacts(frontmostPID: window.app.processIdentifier, frontmostBundleID: window.app.bundleIdentifier,
			focused: window.id)
		coordinator.note { state in
			state.ingestFocus(facts, now: now)
		}
	}

	/// Re-reads the connected displays. Workspaces of a display that went away move to another
	/// one and come back when it returns; a new display starts with an empty workspace
	func reconcileDisplays() {
		let displays = DisplayReader.read()
		if Set(displays.map(\.key)) != Set(state.monitorOrder) {
			exitSpecialModesForScreenChange()
		}
		let now = Self.uptime()
		coordinator.perform("topology") { state in
			state.reconcileTopology(displays, now: now)
		}
		NotificationCenter.default.post(name: .workspaceChanged, object: nil)
	}

	/// A window seen on screen again after the window list took it for closed (an app that
	/// answered late, a window missing from one reading) is alive after all.
	private static func forgetRetirement(of id: WindowID, in state: inout TrackingState) {
		guard state.tombstones.contains(id) else { return }
		var kept = TombstoneSet(capacity: state.tombstones.capacity)
		for other in state.tombstones.ids.sorted() where other != id {
			kept.insert(other)
		}
		state.tombstones = kept
	}

	/// Retires tracked windows the window server no longer has. A close the window list missed
	/// (a floating window, an app too busy to answer when it went) would otherwise keep its
	/// workspace from ever counting as empty. The monitors that lost windows drop their empty
	/// workspaces afterwards (keeping the shown one with `keepingActive`).
	private static func retireVanishedWindows(in state: inout TrackingState, keepingActive: Bool, now: Time) {
		let ids = Set(state.records.keys)
		guard !ids.isEmpty else { return }
		let existing = ServerProbe.exists(ids, now: now).windows
		// An empty answer says more about the window server than about the windows.
		guard !existing.isEmpty else { return }
		var hosts = Set<MonitorKey>()
		for id in ids.sorted() where existing[id] == nil {
			if let host = state.location(id)?.monitor {
				hosts.insert(host)
			}
			state.retire(id, reason: .destroyed, now: now, compacting: false)
		}
		for host in hosts.sorted() {
			state.compact(host, keepingActive: keepingActive)
		}
	}

	private static func appFacts(_ app: NSRunningApplication) -> AppFacts {
		AppFacts(pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: app.localizedName ?? "", isHidden: app.isHidden)
	}

	private static func uptime() -> Time {
		ProcessInfo.processInfo.systemUptime
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
	func switchWorkspace(to workspace: WorkspaceID, focusWindowID: CGWindowID? = nil) {
		guard let host = state.workspaces[workspace]?.host, let screen = screen(for: host),
			  let number = state.number(of: workspace) else { return }
		switchWorkspace(.id(workspace), number: number, on: screen, focusWindowID: focusWindowID)
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
	private func switchWorkspace(_ target: WorkspaceTarget, number: Int, on screen: NSScreen, focusWindowID: CGWindowID? = nil) {
		guard let key = monitorKey(for: screen) else { return }
		let current = currentWorkspace(on: screen)
		guard number != current else { return }

		// Set the switching-in-progress flag (prevents checkForWindowChanges from misfiring)
		isSwitching = true
		PerfLog.event("workspace: switch \(PerfLog.describe(screen)) ws\(current + 1) -> ws\(number + 1)"
			+ (focusWindowID.map { " (focus #\($0))" } ?? ""))
		endZenForSwitch(on: screen)

		// The new workspace's windows come on screen first; the old ones leave a moment later,
		// so an empty screen never shows
		let now = Self.uptime()
		var destination: WorkspaceID?
		coordinator.perform("switch", delaysHidePhase: true) { state in
			destination = state.switchWorkspace(on: key, to: target)
			Self.retireVanishedWindows(in: &state, keepingActive: true, now: now)
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
		guard let focusedWindow = accessibilityManager.getFocusedWindow(), let key = monitorKey(for: screen) else { return }
		if !state.isTracked(focusedWindow.id) {
			register(focusedWindow, source: .discovered)
		}
		guard state.isTracked(focusedWindow.id) else { return }

		isSwitching = true
		PerfLog.event("workspace: switch \(PerfLog.describe(screen)) ws\(currentWorkspace(on: screen) + 1) -> ws\(number + 1)"
			+ " (focus #\(focusedWindow.id))")
		endZenForSwitch(on: screen)

		let now = Self.uptime()
		var destination: WorkspaceID?
		coordinator.perform("move to workspace", delaysHidePhase: true) { state in
			destination = state.moveWindowToWorkspace(focusedWindow.id, on: key, to: target)
			Self.retireVanishedWindows(in: &state, keepingActive: true, now: now)
		}
		finishSwitch(to: destination, focusWindowID: focusedWindow.id)
	}

	/// Zen mode is per monitor: a switch on its monitor ends it, one on another monitor does not
	private func endZenForSwitch(on screen: NSScreen) {
		if ZenModeManager.shared.isActive, let monitor = ZenModeManager.shared.activeMonitor, monitor == monitorKey(for: screen) {
			ZenModeManager.shared.toggle()
		}
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

		// Clear the switching-in-progress flag after a short delay
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
			self?.isSwitching = false
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

	/// Focus the first window shown in the workspace: the first tile, else a Float window
	/// - Returns: the ID of the window that was actually focused (nil if there was no target)
	@discardableResult
	private func focusFirstWindow(in workspace: WorkspaceID) -> CGWindowID? {
		for id in state.orderedWindows(workspace) where !state.isHidden(id) {
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

	// MARK: - Windows other components move

	/// Windows Zen mode and the palette park and restore by themselves
	private func externallyPositionedWindows() -> Set<WindowID> {
		var ids = ZenModeManager.shared.hiddenWindowIDs.union(WindowPaletteManager.shared.hiddenWindowIDs)
		if ZenModeManager.shared.isActive, let focused = ZenModeManager.shared.focusedWindowID {
			ids.insert(focused)
		}
		return ids
	}

	/// Zen mode and the palette are laid out for the old screens, so leave them before the screens change
	private func exitSpecialModesForScreenChange() {
		if ZenModeManager.shared.isActive {
			ZenModeManager.shared.toggle()
		}
		if HotkeyManager.shared.currentMode == .windowPalette {
			WindowPaletteManager.shared.endPalette()
			HotkeyManager.shared.currentMode = .normal
			NotificationCenter.default.post(name: .modeChanged, object: HotkeyManager.Mode.normal)
		}
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
