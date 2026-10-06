//
//  FocusRules.swift
//  Axis
//
//  Whether a focus change should take the user to another workspace, and where focus goes when
//  the focused window closes. Pure: the caller passes what the state does not hold (the window
//  under the mouse, when the change was seen).
//
//  Placeholder body: the rules are not implemented yet.
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

	init(focused: WindowID?, previous: WindowID?, changedAt: Time, windowUnderMouse: WindowID? = nil) {
		self.focused = focused
		self.previous = previous
		self.changedAt = changedAt
		self.windowUnderMouse = windowUnderMouse
	}
}

nonisolated enum FocusRules {
	/// How long a focus change must hold before it switches workspaces.
	static let settleDelay: TimeInterval = 0.3

	static func followDecision(_ context: FollowContext, in state: TrackingState, now: Time) -> FollowDecision {
		.stay
	}
}
