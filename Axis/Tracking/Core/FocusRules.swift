//
//  FocusRules.swift
//  Axis
//
//  Whether a focus change should take the user to another workspace, and where focus goes when
//  the focused window closes. Pure: the caller passes what the state does not hold (the window
//  under the mouse, when the change was seen).
//

import Foundation
import CoreGraphics

/// What to do after the focused window changed.
nonisolated enum FollowDecision: Equatable, Sendable {
	/// Nothing.
	case stay
	/// Decide again at this time (the change has not settled yet).
	case wait(until: Time)
	/// The user focused a window in another workspace: switch there.
	case follow(window: WindowID, workspace: WorkspaceID)
	/// Focus this window instead (the focused window closed and macOS picked another one).
	case focus(WindowID)
}

/// Inputs to a follow decision that the core state does not hold. Fields added here need
/// default values.
nonisolated struct FollowContext: Equatable, Sendable {
	/// The newly focused window.
	var focused: WindowID?
	/// The window focused before it.
	var previous: WindowID?
	/// When the change was seen.
	var changedAt: Time
	/// The tracked window under the mouse pointer, if any.
	var windowUnderMouse: WindowID?
	/// The monitor the previous window was on.
	var previousMonitor: MonitorKey?
	/// Whether Zen mode ended because its focused window closed.
	var zenClosed: Bool

	init(
		focused: WindowID?,
		previous: WindowID?,
		changedAt: Time,
		windowUnderMouse: WindowID? = nil,
		previousMonitor: MonitorKey? = nil,
		zenClosed: Bool = false
	) {
		self.focused = focused
		self.previous = previous
		self.changedAt = changedAt
		self.windowUnderMouse = windowUnderMouse
		self.previousMonitor = previousMonitor
		self.zenClosed = zenClosed
	}
}

nonisolated enum FocusRules {
	/// How long a focus change must hold before it switches workspaces.
	static let settleDelay: TimeInterval = 0.3

	static func followDecision(_ context: FollowContext, in state: TrackingState, now: Time) -> FollowDecision {
		let previousRetired: Bool = {
			guard let previous = context.previous else { return false }
			return state.tombstones.contains(previous) || state.records[previous] == nil
		}()

		if previousRetired {
			let settleTime = context.changedAt + settleDelay
			if now < settleTime {
				return .wait(until: settleTime)
			}
			if context.zenClosed || state.events.contains(where: {
				if case .zenEnded(.focusClosed) = $0 { return true }
				return false
			}) {
				return .stay
			}
			if let target = adjacentTarget(in: state, context: context) {
				if context.focused == target {
					return .stay
				}
				return .focus(target)
			}
			return .stay
		}

		guard let focused = context.focused else {
			return .stay
		}

		guard let record = state.records[focused],
			let targetWorkspace = record.workspace,
			state.workspaces[targetWorkspace] != nil else {
			return .stay
		}

		if state.isActive(targetWorkspace) {
			return .stay
		}

		// When switching to an empty workspace, the previous window stays system-focused
		// while parked; ignore the focus handoff only when focus stayed on that parked window.
		if context.focused == context.previous,
			let host = state.workspaces[targetWorkspace]?.host,
			let active = state.activeWorkspace(host),
			!state.hasMembers(active) {
			return .stay
		}

		if context.zenClosed || state.events.contains(where: {
			if case .zenEnded(.focusClosed) = $0 { return true }
			return false
		}) {
			return .stay
		}

		if let bundleID = record.bundleID,
			let entry = state.launchAside[bundleID],
			let hold = entry.holdFocusUntil,
			hold > now {
			return .stay
		}

		let settleTime = context.changedAt + settleDelay
		if now < settleTime {
			return .wait(until: settleTime)
		}

		return .follow(window: focused, workspace: targetWorkspace)
	}

	private static func adjacentTarget(in state: TrackingState, context: FollowContext) -> WindowID? {
		if let monitor = context.previousMonitor, let active = state.activeWorkspace(monitor) {
			if let firstTile = firstFocusableTile(in: active, state: state) {
				return firstTile
			}
		}

		if let mouseID = context.windowUnderMouse,
			let record = state.records[mouseID],
			record.workspace != nil,
			record.visibility == .visible,
			state.isFocusable(mouseID) {
			return mouseID
		}

		let fallbackMonitor = state.focus.lastTrackedMonitor ?? state.primaryMonitor
		if let monitor = fallbackMonitor, let active = state.activeWorkspace(monitor) {
			if let firstTile = firstFocusableTile(in: active, state: state) {
				return firstTile
			}
		}

		for monitorKey in state.monitorOrder {
			if let active = state.activeWorkspace(monitorKey),
				let firstTile = firstFocusableTile(in: active, state: state) {
				return firstTile
			}
		}

		return nil
	}

	/// The first tile of a workspace that focus may go to: the drawable tiles left to right, else
	/// the stored columns. Windows of apps that do not answer are passed over, since focusing one
	/// only makes the main thread wait for the app.
	private static func firstFocusableTile(in workspace: WorkspaceID, state: TrackingState) -> WindowID? {
		if let tile = state.layoutColumns(workspace).joined().first(where: { state.isFocusable($0) }) {
			return tile
		}
		return state.workspaces[workspace]?.columns.joined().first(where: { state.isFocusable($0) })
	}
}
