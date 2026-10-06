//
//  FocusHistoryManager.swift
//  Axis
//
//  Remembers the windows the user settled on, so one key jumps back to the previous one.
//  Focus moves one step at a time, so it passes through windows on the way to where it is going;
//  a window only counts once it has kept focus for a while, or when the jump itself leaves or reaches it.
//  Only windows Axis manages are remembered, so popups and panels that briefly take focus never count.
//

import AppKit
import Combine

class FocusHistoryManager: ObservableObject {
	static let shared = FocusHistoryManager()

	// MARK: - Settings (persisted to UserDefaults)

	private static let settleSecondsKey = "focusHistorySettleSeconds"

	/// How long a window must keep focus before it is remembered (seconds)
	@Published var settleSeconds: Double {
		didSet {
			UserDefaults.standard.set(settleSeconds, forKey: Self.settleSecondsKey)
		}
	}

	// MARK: - Internal state

	/// Remembered windows, most recent last
	private var history: [CGWindowID] = []
	private static let maxHistory = 30
	/// The managed window focus last landed on
	private var currentID: CGWindowID?
	/// Remembers currentID once it has kept focus for settleSeconds
	private var pendingSettle: DispatchWorkItem?

	private init() {
		if UserDefaults.standard.object(forKey: Self.settleSecondsKey) == nil {
			UserDefaults.standard.set(10.0, forKey: Self.settleSecondsKey)
		}
		self.settleSeconds = UserDefaults.standard.double(forKey: Self.settleSecondsKey)
	}

	// MARK: - Tracking

	/// Called when focus lands on a window Axis manages
	func focusChanged(to windowID: CGWindowID) {
		guard windowID != currentID else { return }
		pendingSettle?.cancel()
		currentID = windowID
		let work = DispatchWorkItem { [weak self] in
			self?.remember(windowID)
		}
		pendingSettle = work
		DispatchQueue.main.asyncAfter(deadline: .now() + settleSeconds, execute: work)
	}

	private func remember(_ windowID: CGWindowID) {
		history.removeAll { $0 == windowID }
		history.append(windowID)
		if history.count > Self.maxHistory {
			history.removeFirst(history.count - Self.maxHistory)
		}
	}

	/// A window that came back under a new ID (same app and title) keeps its place in the history
	func replace(_ oldID: CGWindowID, with newID: CGWindowID) {
		history = history.map { $0 == oldID ? newID : $0 }
		if currentID == oldID {
			currentID = newID
		}
	}

	// MARK: - Jumping back

	/// Focus the most recently remembered window other than the current one,
	/// switching to its workspace if needed. Pressing it again returns to where it started.
	func jumpBack() {
		let workspaces = WorkspaceManager.shared
		let focused = AccessibilityManager.shared.getFocusedWindow()
		let leavingID = focused.flatMap { workspaces.isWindowInAnyWorkspace($0.id) ? $0.id : nil } ?? currentID
		if let leavingID {
			remember(leavingID)
		}

		// Closed windows are no longer tracked; hidden ones stay out of sight on purpose
		history.removeAll { !workspaces.isTracked($0) }
		guard let targetID = history.last(where: { $0 != leavingID && !HiddenWindowManager.shared.isHidden($0) }),
		      let target = TrackingCoordinator.shared.windowInfo(targetID)
		else { return }
		PerfLog.event("focus history: jump back to \(PerfLog.describe(target))")

		remember(targetID)
		pendingSettle?.cancel()
		currentID = targetID

		if TrackingCoordinator.shared.state.visibility(targetID) == .zenHidden {
			ZenModeManager.shared.exit()
		}

		if let location = workspaces.workspaceLocation(for: targetID),
		   location.workspace != workspaces.currentWorkspace(on: location.screen) {
			workspaces.switchWorkspace(to: location.workspace, on: location.screen, focusWindowID: targetID)
		} else {
			target.focus()
			TilingEngine.shared.moveCursorToWindow(target)
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
				BorderManager.shared.updateBorderExpecting(windowID: targetID)
			}
		}
	}
}
