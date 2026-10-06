//
//	FocusFollower.swift
//	Axis
//
//	What happens when focus changes on its own: a window focused in another workspace brings that
//	workspace on screen, the focused window closing hands focus to a window next to it, and a
//	window that just opened takes focus. Focus changes come from the tracking coordinator;
//	`FocusRules` decides whether to follow, wait or move focus, and this class carries it out.
//

import AppKit

/// Follows focus into other workspaces and hands it on when the focused window closes.
final class FocusFollower {
	private var coordinator: TrackingCoordinator { TrackingCoordinator.shared }

	/// The tracked window that has focus (nil while focus is on a window Axis does not track, or on
	/// none), and the monitor of the last tracked window that had it.
	private var focused: WindowID?
	private var focusedMonitor: MonitorKey?
	/// The focus change waiting to settle before it is acted on.
	private var pending: FollowContext?
	/// The pending change was seen while a workspace switch settled: it belongs to the switch, so
	/// it never takes the screen to another workspace.
	private var pendingDuringTransition = false
	private var decisionWork: DispatchWorkItem?
	/// Windows that just opened, focused a moment later unless they turn out to take the place of
	/// a closed one.
	private var openedWindows: Set<WindowID> = []
	private var activationObserver: (any NSObjectProtocol)?

	/// Right after an app comes to the front its focused window can be undetermined.
	private static let activationDelay: TimeInterval = 0.05
	/// A window that just opened gets focus once it has appeared.
	private static let openedWindowFocusDelay: TimeInterval = 0.15

	func start() {
		coordinator.addEventHandler { [weak self] event in
			self?.handle(event)
		}
		let ownPID = ProcessInfo.processInfo.processIdentifier
		activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
			forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
		) { [weak self] notification in
			guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
			      app.processIdentifier != ownPID
			else { return }
			let pid = app.processIdentifier
			let name = app.localizedName ?? app.bundleIdentifier ?? "?"
			MainActor.assumeIsolated {
				self?.appActivated(pid: pid, name: name)
			}
		}
	}

	// MARK: - Tracking events

	private func handle(_ event: TrackingEvent) {
		switch event {
		case .focusChanged(let from, let to):
			focusChanged(from: from, to: to)
		case .retired(let id, _):
			openedWindows.remove(id)
			if id == focused {
				// The focused window closed. macOS picks the next one, which can sit out of sight in
				// another workspace, or leaves nothing focused.
				focused = nil
				expect(FollowContext(focused: coordinator.state.focus.current, previous: id, changedAt: Self.uptime(),
					previousMonitor: focusedMonitor), duringTransition: false)
			}
		case .admitted(let id):
			noteOpened(id)
		case .rekeyed(let old, let new):
			// The window did not close; it only came back under a new id.
			openedWindows.remove(new)
			if focused == old {
				focused = new
			}
			if pending?.previous == old {
				cancelPending()
			}
		case .activeChanged(_, _, _, let cause):
			// A switch by a command takes care of focus itself; a change waiting from before it is stale.
			if cause == .command {
				cancelPending()
			}
		case .zenEnded, .returnFocus:
			break
		}
	}

	private func focusChanged(from: WindowID?, to: WindowID?) {
		let state = coordinator.state
		let previousMonitor = focusedMonitor
		focused = to
		if let to, let record = state.record(to) {
			focusedMonitor = state.location(to)?.monitor ?? record.observed.frame.flatMap { state.monitorKey(for: $0) }
			if record.workspace != nil {
				FocusHistoryManager.shared.focusChanged(to: to)
			}
			// Whenever a tiled window takes focus, macOS raises it over everything, which buries any
			// floating window overlapping it. The floats on its screen come back to the front
			// (raised only, focus untouched).
			if record.placement == .tiled, let screen = WorkspaceManager.shared.screenForWindow(to) {
				PerfLog.measure("focusChange.raiseFloatingWindows", threshold: 0.005) {
					TilingEngine.shared.raiseFloatingWindows(on: screen)
				}
			}
		}

		if var context = pending, let previous = context.previous, !state.isTracked(previous) {
			// A closed window is handing focus on: it now weighs the window macOS picked.
			context.focused = to
			pending = context
			decide()
			return
		}
		expect(FollowContext(focused: to, previous: from, changedAt: Self.uptime(),
			previousMonitor: from.flatMap { state.location($0)?.monitor } ?? previousMonitor),
			duringTransition: coordinator.isInTransition)
	}

	// MARK: - Decisions

	private func expect(_ context: FollowContext, duringTransition: Bool) {
		pending = context
		pendingDuringTransition = duringTransition
		decide()
	}

	private func decide() {
		decisionWork?.cancel()
		decisionWork = nil
		guard var context = pending else { return }
		let state = coordinator.state
		if let previous = context.previous, !state.isTracked(previous) {
			context.windowUnderMouse = windowUnderMouse()
		}
		let now = Self.uptime()
		switch FocusRules.followDecision(context, in: state, now: now) {
		case .wait(let until):
			let work = DispatchWorkItem { [weak self] in
				self?.decide()
			}
			decisionWork = work
			DispatchQueue.main.asyncAfter(deadline: .now() + max(0, until - now), execute: work)
		case .stay:
			pending = nil
			BorderManager.shared.notifyFocusedWindowChanged()
		case .follow(let window, let workspace):
			let duringTransition = pendingDuringTransition
			pending = nil
			if duringTransition {
				BorderManager.shared.notifyFocusedWindowChanged()
			} else {
				follow(window, into: workspace)
			}
		case .focus(let window):
			pending = nil
			coordinator.windowInfo(window)?.focus()
		}
	}

	private func cancelPending() {
		pending = nil
		decisionWork?.cancel()
		decisionWork = nil
	}

	/// The decision was made on the focus the coordinator last read; it is followed only while the
	/// window still has focus.
	private func follow(_ windowID: WindowID, into workspace: WorkspaceID) {
		guard AccessibilityManager.shared.getFocusedWindowID() == windowID else { return }
		WorkspaceManager.shared.switchWorkspace(to: workspace, focusWindowID: windowID)
	}

	/// The tracked window under the mouse pointer, the frontmost one where windows overlap.
	private func windowUnderMouse() -> WindowID? {
		guard let primaryHeight = NSScreen.screens.first?.frame.height,
		      let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
		else { return nil }
		let mouse = NSEvent.mouseLocation
		let point = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
		let state = coordinator.state
		for entry in list {
			guard let id = entry[kCGWindowNumber as String] as? CGWindowID, state.isTracked(id),
			      let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat]
			else { continue }
			let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
				width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
			if frame.contains(point) {
				return id
			}
		}
		return nil
	}

	// MARK: - Windows that just opened

	/// A window that just opened takes focus, as it does when it opens in front: one that opened
	/// behind another app's window would otherwise wait there unseen. Windows set aside by a launch
	/// and windows out of sight stay where they are.
	private func noteOpened(_ id: WindowID) {
		guard let record = coordinator.state.record(id), record.source == .created, record.visibility == .visible,
		      openedWindows.insert(id).inserted
		else { return }
		DispatchQueue.main.asyncAfter(deadline: .now() + Self.openedWindowFocusDelay) { [weak self] in
			guard let self, self.openedWindows.remove(id) != nil else { return }
			let state = self.coordinator.state
			guard state.visibility(id) == .visible, state.focus.current != id,
			      let window = self.coordinator.windowInfo(id)
			else { return }
			window.focus()
		}
	}

	// MARK: - Apps coming to the front

	/// An app came to the front (Cmd+Tab, a Dock click, a link opening in it). When its focused
	/// window, or failing that one of its windows, is in a workspace out of sight, that workspace
	/// comes on screen right away rather than after the settle delay of other focus changes.
	private func appActivated(pid: PID, name: String) {
		guard !coordinator.isInTransition else { return }
		PerfLog.event("app activated: \(name)")
		DispatchQueue.main.asyncAfter(deadline: .now() + Self.activationDelay) { [weak self] in
			self?.followActivatedApp(pid)
		}
	}

	private func followActivatedApp(_ pid: PID) {
		let state = coordinator.state
		var target: WindowID?
		if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
		   let focused = AccessibilityManager.shared.getFocusedWindowID(), state.record(focused)?.workspace != nil {
			target = focused
		} else {
			target = AccessibilityManager.shared.getWindows(forPID: pid).first { state.record($0.id)?.workspace != nil }?.id
		}
		guard let target, let record = state.record(target), let workspace = record.workspace,
		      !state.isActive(workspace)
		else { return }
		// A window just set aside by a launch keeps its distance: focus goes back instead
		if let bundleID = record.bundleID, LaunchAsideManager.shared.holdsFocus(bundleID: bundleID) {
			return
		}
		cancelPending()
		WorkspaceManager.shared.switchWorkspace(to: workspace, focusWindowID: target)
	}

	private static func uptime() -> Time {
		ProcessInfo.processInfo.systemUptime
	}
}
