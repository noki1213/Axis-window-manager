//
//  Planner.swift
//  Axis
//
//  Compares where every managed window should be with where the window server shows it and plans
//  the writes that close the gap: layout slots, parks, Zen centring, float restores, minimizes.
//  The write ledger accepts an app's clamped result instead of fighting it.
//
//  Placeholder bodies: planning is not implemented yet.
//

import Foundation
import CoreGraphics

/// How a plan is made. Fields added here need default values.
nonisolated struct PlanOptions: Equatable, Sendable {
	/// A user command (switch, move, Zen, ...) rather than an enforcement pass.
	var isCommand: Bool
	/// Plan the hide phase too. A workspace switch plans it 50 ms later from fresh state, so the
	/// new windows are on screen before the old ones leave.
	var includeHidePhase: Bool
	/// The left mouse button is down: enforcement writes wait for its release.
	var mouseDown: Bool
	/// Windows another component still positions itself while features move over to the core.
	var externallyPositioned: Set<WindowID>

	init(isCommand: Bool = false, includeHidePhase: Bool = true, mouseDown: Bool = false, externallyPositioned: Set<WindowID> = []) {
		self.isCommand = isCommand
		self.includeHidePhase = includeHidePhase
		self.mouseDown = mouseDown
		self.externallyPositioned = externallyPositioned
	}
}

/// Planner bookkeeping (fight timing, one-shot actions in flight, ...).
/// Fields added here need default values.
nonisolated struct PlannerState: Equatable, Sendable {
	init() {}
}

nonisolated extension TrackingState {
	/// The writes that bring every managed window where its state says, judged against `snapshot`
	/// (taken after the facts of this pass were gathered).
	mutating func plan(snapshot: ServerSnapshot, options: PlanOptions, now: Time) -> Plan {
		Plan()
	}

	/// Where the planner last wanted the window, for the window-server watcher's checks.
	func expectedFrame(_ id: WindowID) -> CGRect? {
		nil
	}

	/// Delayed hide phases, fight retries, give-up expiries.
	func plannerFollowUps(now: Time) -> [FollowUp] {
		[]
	}

	/// The writes that put every window back on screen when Axis quits: tiled windows into their
	/// slots, the others at their last visible frame, sessions treated as ended.
	func quitPlan() -> Plan {
		Plan()
	}

	/// Called by `retire` after the record left the state (its ledger entry is already gone).
	mutating func plannerNoteRetire(_ id: WindowID) {}
}
