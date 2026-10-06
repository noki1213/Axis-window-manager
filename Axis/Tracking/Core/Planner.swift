//
//  Planner.swift
//  Axis
//
//  Compares where every managed window should be with where the window server shows it and plans
//  the writes that close the gap: layout slots, parks, Zen centring, float restores, minimizes.
//  The write ledger accepts an app's clamped result instead of fighting it.
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

	init(isCommand: Bool = false, includeHidePhase: Bool = true, mouseDown: Bool = false) {
		self.isCommand = isCommand
		self.includeHidePhase = includeHidePhase
		self.mouseDown = mouseDown
	}
}

/// Planner bookkeeping (fight timing, one-shot actions in flight, ...).
/// Fields added here need default values.
nonisolated struct PlannerState: Equatable, Sendable {
	/// Where the planner last wanted each window: its slot, Zen frame or park rect. A window found
	/// off a slot that did not change has drifted, which is an enforcement rather than a layout
	/// change; the window-server watcher checks windows against these frames too.
	var expected: [WindowID: CGRect] = [:]
	/// Windows the planner parked or found out of sight, with the state that keeps them there.
	/// Seeing one on screen again is an enforcement; showing one again is an unpark.
	var parked: [WindowID: Visibility] = [:]
	/// Windows minimized for the hide command; unminimized once they leave the hide stack.
	var minimized: Set<WindowID> = []
	/// When the hide phase a plan left out is due. The next plan clears or renews it.
	var hidePhaseDue: Time?
	/// A size the Zen window would not take, so it is centred at the size it kept.
	var zenRefusal: PlannerZenRefusal?
	/// The phantom slot of the placement reservation in the last layout, for its preview.
	var reservedSlot: CGRect?

	init() {}
}

/// The Zen window kept `size` when it was asked for `requested`.
nonisolated struct PlannerZenRefusal: Equatable, Sendable {
	var window: WindowID
	var requested: CGRect
	var size: CGSize
}

/// Tolerances and timings of planning and enforcement.
nonisolated enum PlannerPolicy {
	/// Frames this close in each origin coordinate and size dimension count as the same.
	static let tolerance: CGFloat = 2
	/// A window found off target this soon after a write of the same target is fighting it.
	static let fightWindow: Time = 1
	/// Fights in a row after which enforcement leaves the window alone for `giveUpDuration`.
	static let fightLimit = 3
	static let giveUpDuration: Time = 30
	/// How long after a plan without its hide phase that phase is planned, so the windows a
	/// workspace switch shows reach the screen before the old ones leave it.
	static let hidePhaseDelay: Time = 0.05
	/// A minimize that has not shown after this long is requested again (each retry counts as a
	/// fight).
	static let minimizeRetryDelay: Time = 1
	/// The Zen window's read-back size differing from the request by more than this in either
	/// dimension means it refused the size (fixed-size windows).
	static let zenRefusalTolerance: CGFloat = 10
	/// Space above and below the Zen window.
	static let zenVerticalPadding: CGFloat = 12
	/// Barriers that hold commands' writes back too: while the screen is locked, asleep or between
	/// display configurations, writes fail or land on stale geometry.
	static let commandHoldingBarriers: Set<BarrierReason> = [.locked, .asleep, .displayChanging]

	static func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
		abs(a.origin.x - b.origin.x) <= tolerance && abs(a.origin.y - b.origin.y) <= tolerance
			&& abs(a.size.width - b.size.width) <= tolerance && abs(a.size.height - b.size.height) <= tolerance
	}

	/// Whether two writes of `kind` aim at the same place: the frame for frame writes, the origin
	/// for parks (they move a window whatever its size).
	static func isSameTarget(_ kind: WriteKind, _ a: CGRect, _ b: CGRect) -> Bool {
		switch kind {
		case .frame:
			return isClose(a, b)
		case .park:
			return abs(a.origin.x - b.origin.x) <= tolerance && abs(a.origin.y - b.origin.y) <= tolerance
		case .minimize, .unminimize:
			return true
		}
	}

	/// The Zen frame: `widthRatio` of the visible width and the visible height less the padding
	/// above and below, centred in the visible area.
	static func zenFrame(widthRatio: CGFloat, visibleFrame: CGRect) -> CGRect {
		let width = visibleFrame.width * widthRatio
		let height = visibleFrame.height - zenVerticalPadding * 2
		return CGRect(x: visibleFrame.minX + (visibleFrame.width - width) / 2,
			y: visibleFrame.minY + (visibleFrame.height - height) / 2, width: width, height: height)
	}

	/// A frame of `size` centred in the visible area.
	static func centred(_ size: CGSize, in visibleFrame: CGRect) -> CGRect {
		CGRect(x: visibleFrame.minX + (visibleFrame.width - size.width) / 2,
			y: visibleFrame.minY + (visibleFrame.height - size.height) / 2, width: size.width, height: size.height)
	}
}

/// The inputs and the actions of one plan.
private nonisolated struct PlannerPass {
	let snapshot: ServerSnapshot
	let options: PlanOptions
	let now: Time
	/// Connected monitors in display order.
	let monitors: [MonitorState]
	/// No barrier is up, so windows found off target are corrected.
	let enforcing: Bool
	/// Only the hide phase a command left for later is planned.
	let hideOnly: Bool
	/// Slots of the tiled windows of every active workspace.
	var slots: [WindowID: CGRect] = [:]
	var show: [PlanAction] = []
	var hide: [PlanAction] = []
	var deferredByMouse = false

	init(snapshot: ServerSnapshot, options: PlanOptions, now: Time, monitors: [MonitorState], enforcing: Bool, hideOnly: Bool) {
		self.snapshot = snapshot
		self.options = options
		self.now = now
		self.monitors = monitors
		self.enforcing = enforcing
		self.hideOnly = hideOnly
	}
}

nonisolated extension TrackingState {
	/// The writes that bring every managed window where its state says, judged against `snapshot`
	/// (taken after the facts of this pass were gathered).
	///
	/// Shown tiled windows get their slot, the Zen window the Zen frame, a floating window its
	/// floating frame once after it was hidden; windows out of their workspace's sight are parked
	/// at a bottom corner of their monitor; windows the hide command took are minimized. A window
	/// within 2 pt of its target, or where the app left our last write of the same target (a
	/// clamped size), needs nothing. A window found off target without its target changing is an
	/// enforcement: logged, held while the mouse button is down, given up on for a while after
	/// repeated fights, and not planned while a barrier is up. Commands are held back only while
	/// the screen is locked, asleep or reconfiguring.
	mutating func plan(snapshot: ServerSnapshot, options: PlanOptions, now: Time) -> Plan {
		let holdsCommands = !barrier.isDisjoint(with: PlannerPolicy.commandHoldingBarriers)
		var hideOnly = false
		if options.isCommand {
			if holdsCommands {
				// The pass after the barrier lifts plans everything again.
				plannerState.hidePhaseDue = nil
				return Plan(withheldByBarrier: true)
			}
		} else if !barrier.isEmpty {
			// No enforcement while a barrier is up. The hide phase a switch left for later still
			// runs, so the old workspace leaves the screen while hotkeys keep working.
			guard !holdsCommands, plannerState.hidePhaseDue != nil, options.includeHidePhase else {
				if holdsCommands {
					plannerState.hidePhaseDue = nil
				}
				return Plan()
			}
			hideOnly = true
		}

		var pass = PlannerPass(snapshot: snapshot, options: options, now: now,
			monitors: monitorOrder.compactMap { monitors[$0] }, enforcing: barrier.isEmpty, hideOnly: hideOnly)
		if let refusal = plannerState.zenRefusal, refusal.window != zen?.focus {
			plannerState.zenRefusal = nil
		}
		if !hideOnly {
			pass.slots = plannerLayOutActiveWorkspaces()
		}
		for id in records.keys.sorted() {
			guard let record = records[id] else { continue }
			plannerPlan(record, &pass)
		}
		plannerState.hidePhaseDue = options.includeHidePhase ? nil : now + PlannerPolicy.hidePhaseDelay
		return Plan(show: Self.plannerGroups(pass.show), hide: Self.plannerGroups(pass.hide),
			deferredByMouse: pass.deferredByMouse)
	}

	/// Where the planner last wanted the window, for the window-server watcher's checks.
	func expectedFrame(_ id: WindowID) -> CGRect? {
		plannerState.expected[id]
	}

	/// Takes where the shown windows are in `snapshot` as their last visible frames (and floating
	/// frames), as a plan does. Without window-move notifications the frames of the last plan can be
	/// older than where the user has put a floating window since, and a command that takes it out of
	/// sight would bring it back there. Windows with a floating-frame move still to come keep it,
	/// and so does the Zen window, which goes back there when Zen ends.
	mutating func noteVisibleFrames(snapshot: ServerSnapshot) {
		let connected = monitorOrder.compactMap { monitors[$0] }
		for id in records.keys.sorted() {
			guard let record = records[id], record.visibility == .visible, !record.pendingFloatRestore, zen?.focus != id
			else { continue }
			plannerNoteVisibleFrame(record, snapshot: snapshot, connected: connected)
		}
	}

	/// Delayed hide phases, fight retries, give-up expiries.
	func plannerFollowUps(now: Time) -> [FollowUp] {
		var followUps: [FollowUp] = []
		if let due = plannerState.hidePhaseDue {
			followUps.append(FollowUp(at: max(due, now), kind: .frames, reason: "hide phase"))
		}
		// A window corrected after a fight is checked again within the fight window, in case its
		// app moves it back without a notification.
		let checks = ledger.values
			.filter { $0.fights > 0 && $0.gaveUpUntil == nil && ($0.kind == .frame || $0.kind == .park) }
			.map { $0.at + PlannerPolicy.fightWindow / 2 }
			.filter { $0 > now }
		if let next = checks.min() {
			followUps.append(FollowUp(at: next, kind: .frames, reason: "fight check"))
		}
		let expiries = ledger.values.compactMap { $0.gaveUpUntil }.filter { $0 > now }
		if let next = expiries.min() {
			followUps.append(FollowUp(at: next, kind: .frames, reason: "enforcement resumes"))
		}
		return followUps
	}

	/// The writes that put every window back on screen when Axis quits: tiled windows into their
	/// slots, the others at their last visible frame, sessions treated as ended.
	func quitPlan() -> Plan {
		var layouts: [WorkspaceID: [WindowID: CGRect]] = [:]
		var actions: [PlanAction] = []
		for id in records.keys.sorted() {
			guard let record = records[id] else { continue }
			let isParked = record.visibility.isParkedKind
			let isZenFocus = zen?.focus == id && record.visibility == .visible
			let restoresFloat = record.visibility == .visible && record.placement != .tiled && record.pendingFloatRestore
			guard isParked || isZenFocus || restoresFloat else { continue }

			let target: CGRect?
			if record.placement == .tiled, let workspace = record.workspace {
				if layouts[workspace] == nil, let host = workspaces[workspace]?.host,
					let visibleFrame = monitors[host]?.visibleFrame, let input = layoutInput(workspace) {
					layouts[workspace] = ColumnLayout.frames(for: input, visibleFrame: visibleFrame, config: config,
						reservation: nil).frames
				}
				target = layouts[workspace]?[id]
			} else {
				target = plannerFloatTarget(record, size: record.observed.frame?.size)
			}
			guard let target else { continue }
			let reason: ActionReason = isParked
				? .unpark(from: record.visibility)
				: record.placement == .tiled ? .layout : .floatRestore
			actions.append(plannerAction(record, .setFrame(target), reason: reason, observed: record.observed.frame))
		}
		return Plan(show: Self.plannerGroups(actions))
	}

	/// Called by `retire` after the record left the state (its ledger entry is already gone).
	mutating func plannerNoteRetire(_ id: WindowID) {
		plannerState.expected[id] = nil
		plannerState.parked[id] = nil
		plannerState.minimized.remove(id)
		if plannerState.zenRefusal?.window == id {
			plannerState.zenRefusal = nil
		}
	}
}

// MARK: - One window

nonisolated extension TrackingState {
	/// Lays out every monitor's active workspace (with the reservation's phantom slot on its
	/// monitor), stores the normalized ratios back and returns the slots of the tiled windows.
	private mutating func plannerLayOutActiveWorkspaces() -> [WindowID: CGRect] {
		var slots: [WindowID: CGRect] = [:]
		plannerState.reservedSlot = nil
		for key in monitorOrder {
			guard let monitor = monitors[key], let input = layoutInput(monitor.active) else { continue }
			let reservation = self.reservation?.monitor == key ? self.reservation : nil
			let result = ColumnLayout.frames(for: input, visibleFrame: monitor.visibleFrame, config: config,
				reservation: reservation)
			workspaces[monitor.active]?.widthRatios = result.widthRatios
			workspaces[monitor.active]?.rowRatios = result.rowRatios
			slots.merge(result.frames) { current, _ in current }
			if reservation != nil {
				plannerState.reservedSlot = result.reservedSlot
			}
		}
		return slots
	}

	private mutating func plannerPlan(_ record: WindowRecord, _ pass: inout PlannerPass) {
		let id = record.id
		// An app that does not answer keeps its windows' slots; writes to it wait until a scan of
		// it succeeds again.
		let writable = apps[record.pid]?.unresponsiveSince == nil
		let observed = plannerObservedFrame(id, snapshot: pass.snapshot)

		// A window the hide command minimized comes back once it left the hide stack. Restored from
		// the Dock it is on screen already and needs nothing.
		if !pass.hideOnly, writable, record.visibility != .axisMinimized, plannerState.minimized.contains(id) {
			plannerState.minimized.remove(id)
			if record.observed.isMinimized || pass.snapshot.windows[id] == nil {
				pass.show.append(plannerAction(record, .unminimize, reason: .restore, observed: observed))
			}
		}

		switch record.visibility {
		case .visible:
			if !pass.hideOnly {
				plannerPlanShown(record, observed: observed, writable: writable, &pass)
			}
		case .parked, .zenHidden, .paletteHidden:
			if pass.options.includeHidePhase {
				plannerPlanParked(record, observed: observed, writable: writable, &pass)
			}
		case .axisMinimized:
			if pass.options.includeHidePhase {
				plannerPlanMinimized(record, writable: writable, &pass)
			}
		case .nativeMinimized, .nativeFullscreen, .otherSpace, .appHidden:
			// Never written: the user, the app or macOS put it there.
			plannerState.expected[id] = nil
			plannerState.parked[id] = nil
		}
	}

	/// A shown window: a tiled one into its slot, the Zen window into the Zen frame.
	private mutating func plannerPlanShown(_ record: WindowRecord, observed: CGRect?, writable: Bool, _ pass: inout PlannerPass) {
		let id = record.id
		let isZenFocus = zen?.focus == id
		let desired: CGRect
		if isZenFocus, let zen, let visibleFrame = monitors[zen.monitor]?.visibleFrame {
			desired = plannerZenFrame(id, session: zen, visibleFrame: visibleFrame)
		} else if record.placement == .tiled {
			guard let slot = pass.slots[id] else {
				plannerState.expected[id] = nil
				return
			}
			desired = slot
		} else {
			plannerPlanFloating(record, observed: observed, writable: writable, &pass)
			return
		}
		guard writable else { return }

		if plannerIsSettled(id, kind: .frame, target: desired, observed: observed) {
			plannerState.expected[id] = desired
			plannerState.parked[id] = nil
			if !isZenFocus {
				plannerNoteVisibleFrame(record, snapshot: pass.snapshot, connected: pass.monitors)
			}
			return
		}
		let reason: ActionReason
		if let from = plannerState.parked[id] {
			reason = .unpark(from: from)
		} else if let observed, let previous = plannerState.expected[id], PlannerPolicy.isClose(previous, desired) {
			reason = .enforce(observed: observed, expected: .visible)
		} else {
			reason = isZenFocus ? .zenCentre : .layout
		}
		guard plannerMayWrite(record, kind: .frame, target: desired, reason: reason, &pass) else { return }
		if case .enforce(let observed, _) = reason {
			let what = isZenFocus ? "zen frame" : "slot"
			log("enforce: \(describe(record)) \(what) drift \(Self.describeFrame(observed)) vs \(Self.describeFrame(desired)); re-applying")
		}
		plannerState.expected[id] = desired
		plannerState.parked[id] = nil
		pass.show.append(plannerAction(record, .setFrame(desired), reason: reason, observed: observed))
	}

	/// A shown floating or unmanaged window stays where the user puts it, apart from one move to
	/// its floating frame after it was hidden or moved to another monitor.
	private mutating func plannerPlanFloating(_ record: WindowRecord, observed: CGRect?, writable: Bool, _ pass: inout PlannerPass) {
		let id = record.id
		guard record.pendingFloatRestore else {
			plannerState.expected[id] = nil
			plannerState.parked[id] = nil
			plannerNoteVisibleFrame(record, snapshot: pass.snapshot, connected: pass.monitors)
			return
		}
		guard writable else { return }
		records[id]?.pendingFloatRestore = false
		let from = plannerState.parked[id]
		plannerState.expected[id] = nil
		plannerState.parked[id] = nil
		guard let target = plannerFloatTarget(record, size: observed?.size ?? record.observed.frame?.size) else { return }
		if let observed, PlannerPolicy.isClose(observed, target) { return }
		let reason: ActionReason = from.map { .unpark(from: $0) } ?? .floatRestore
		pass.show.append(plannerAction(record, .setFrame(target), reason: reason, observed: observed))
	}

	/// A window out of its workspace's sight (inactive workspace, Zen, palette): parked at its
	/// monitor's corner unless it is out of sight already.
	private mutating func plannerPlanParked(_ record: WindowRecord, observed: CGRect?, writable: Bool, _ pass: inout PlannerPass) {
		let id = record.id
		guard let key = plannerMonitor(of: record), let monitor = monitors[key] else { return }
		let corner = ParkGeometry.corner(for: monitor, monitors: pass.monitors)
		let size = observed?.size ?? record.observed.frame?.size ?? record.lastVisibleFrame?.size
		let target = size.map {
			CGRect(origin: ParkGeometry.parkOrigin(size: $0, visibleFrame: monitor.visibleFrame, corner: corner), size: $0)
		}

		if plannerIsOutOfSight(id, observed: observed, target: target, monitors: pass.monitors) {
			plannerEndFights(id)
			plannerState.parked[id] = record.visibility
			plannerState.expected[id] = target
			return
		}
		guard writable, let observed, let target else { return }
		let reason: ActionReason = plannerState.parked[id] != nil
			? .enforce(observed: observed, expected: record.visibility)
			: .park(record.visibility)
		guard plannerMayWrite(record, kind: .park, target: target, reason: reason, &pass) else { return }
		if case .enforce = reason {
			let expected = Self.plannerExpectationText(record.visibility)
			log("enforce: \(describe(record)) found at \(Self.describeFrame(observed)), expected \(expected); re-parking")
		}
		plannerState.parked[id] = record.visibility
		plannerState.expected[id] = target
		pass.hide.append(plannerAction(record, .park(target.origin), reason: reason, observed: observed))
	}

	/// A window the hide command took: minimized, and asked again after a while when it did not go
	/// (each retry counts as a fight). Seen minimized, or restored by the user, it needs nothing.
	private mutating func plannerPlanMinimized(_ record: WindowRecord, writable: Bool, _ pass: inout PlannerPass) {
		let id = record.id
		plannerState.expected[id] = nil
		plannerState.parked[id] = nil
		guard writable, !record.observed.isMinimized,
			hiddenStack.first(where: { $0.window == id })?.minimizeConfirmed != true
		else { return }
		if var entry = ledger[id], entry.kind == .minimize {
			if let until = entry.gaveUpUntil {
				guard pass.now >= until else { return }
				entry.fights = 0
				entry.gaveUpUntil = nil
			}
			guard pass.now - entry.at >= PlannerPolicy.minimizeRetryDelay else { return }
			entry.fights += 1
			if entry.fights >= PlannerPolicy.fightLimit {
				entry.gaveUpUntil = pass.now + PlannerPolicy.giveUpDuration
				ledger[id] = entry
				plannerLogGivingUp(record, fights: entry.fights)
				return
			}
			ledger[id] = entry
		}
		plannerState.minimized.insert(id)
		pass.hide.append(plannerAction(record, .minimize, reason: .hide, observed: nil))
	}

	/// The Zen window's frame, centred at the size it kept when it refused the requested one.
	private mutating func plannerZenFrame(_ id: WindowID, session: ZenSession, visibleFrame: CGRect) -> CGRect {
		let requested = PlannerPolicy.zenFrame(widthRatio: session.widthRatio, visibleFrame: visibleFrame)
		if let refusal = plannerState.zenRefusal, refusal.window == id, PlannerPolicy.isClose(refusal.requested, requested) {
			return PlannerPolicy.centred(refusal.size, in: visibleFrame)
		}
		if let entry = ledger[id], entry.kind == .frame, PlannerPolicy.isClose(entry.target, requested), let result = entry.result,
			abs(result.width - requested.width) > PlannerPolicy.zenRefusalTolerance
				|| abs(result.height - requested.height) > PlannerPolicy.zenRefusalTolerance {
			plannerState.zenRefusal = PlannerZenRefusal(window: id, requested: requested, size: result.size)
			return PlannerPolicy.centred(result.size, in: visibleFrame)
		}
		return requested
	}

	// MARK: Comparison and the fight budget

	/// The window's frame as of this pass: what a write made after the snapshot was taken left
	/// (its read-back, else its target), else the window server's bounds. Nil when the snapshot
	/// does not show the window.
	private func plannerObservedFrame(_ id: WindowID, snapshot: ServerSnapshot) -> CGRect? {
		if let entry = ledger[id], entry.at > snapshot.takenAt, entry.kind == .frame || entry.kind == .park {
			return entry.result ?? entry.target
		}
		return snapshot.windows[id]?.bounds
	}

	/// Whether a window at `observed` needs no write of `target`: it is there, or where the app left
	/// our last write of the same target (a size it clamped). Settling ends a run of fights.
	private mutating func plannerIsSettled(_ id: WindowID, kind: WriteKind, target: CGRect, observed: CGRect?) -> Bool {
		guard let observed else { return false }
		var settled = PlannerPolicy.isClose(observed, target)
		if !settled, let entry = ledger[id], entry.kind == kind, PlannerPolicy.isSameTarget(kind, entry.target, target),
			let result = entry.result, PlannerPolicy.isClose(observed, result) {
			settled = true
		}
		if settled {
			plannerEndFights(id)
		}
		return settled
	}

	/// Whether a parked window needs no write: not on screen, at most a sliver of it on any visible
	/// area, or where macOS left our last park at the same corner.
	private mutating func plannerIsOutOfSight(_ id: WindowID, observed: CGRect?, target: CGRect?, monitors: [MonitorState]) -> Bool {
		guard let observed else { return true }
		if ParkGeometry.isEffectivelyHidden(observed, monitors: monitors) {
			return true
		}
		guard let target, let entry = ledger[id], entry.kind == .park, PlannerPolicy.isSameTarget(.park, entry.target, target),
			let result = entry.result
		else { return false }
		return PlannerPolicy.isClose(observed, result)
	}

	/// Whether a write of `target` may go out now. Given up windows are left alone; enforcements
	/// wait while a barrier is up or the mouse button is down. A window found off the same target
	/// within the fight window of our write is fighting it, and after `fightLimit` fights in a row
	/// enforcement leaves it alone for `giveUpDuration`. Moves spaced further apart are always
	/// corrected.
	private mutating func plannerMayWrite(_ record: WindowRecord, kind: WriteKind, target: CGRect, reason: ActionReason,
		_ pass: inout PlannerPass) -> Bool {
		let id = record.id
		let previous = ledger[id].flatMap { $0.kind == kind && PlannerPolicy.isSameTarget(kind, $0.target, target) ? $0 : nil }
		if let until = previous?.gaveUpUntil, pass.now < until {
			return false
		}
		if case .enforce = reason {
			guard pass.enforcing else { return false }
			if pass.options.mouseDown {
				pass.deferredByMouse = true
				return false
			}
		}
		guard var entry = previous else { return true }
		if pass.now - entry.at <= PlannerPolicy.fightWindow {
			entry.fights += 1
			if entry.fights >= PlannerPolicy.fightLimit {
				entry.gaveUpUntil = pass.now + PlannerPolicy.giveUpDuration
				ledger[id] = entry
				plannerLogGivingUp(record, fights: entry.fights)
				return false
			}
		} else {
			entry.fights = 0
			entry.gaveUpUntil = nil
		}
		ledger[id] = entry
		return true
	}

	private mutating func plannerEndFights(_ id: WindowID) {
		guard var entry = ledger[id], entry.fights != 0 || entry.gaveUpUntil != nil else { return }
		entry.fights = 0
		entry.gaveUpUntil = nil
		ledger[id] = entry
	}

	private mutating func plannerLogGivingUp(_ record: WindowRecord, fights: Int) {
		log("enforce: giving up on \(describe(record)) for \(Int(PlannerPolicy.giveUpDuration))s (\(fights) fights)")
	}

	// MARK: Geometry helpers

	/// The monitor a window belongs to: its workspace's host; for an unmanaged window the monitor
	/// of its floating frame, else the one holding its last known frame.
	private func plannerMonitor(of record: WindowRecord) -> MonitorKey? {
		if let workspace = record.workspace, let host = workspaces[workspace]?.host {
			return host
		}
		if let monitor = record.floatingFrame?.monitor, monitors[monitor] != nil {
			return monitor
		}
		if let frame = record.observed.frame ?? record.lastVisibleFrame, let monitor = monitorKey(for: frame) {
			return monitor
		}
		return primaryMonitor
	}

	/// Where a floating or unmanaged window goes when it is shown again: its floating frame on that
	/// monitor's current visible area (its own monitor's when that one is gone), else its last
	/// visible frame, else centred on its monitor at `size`.
	private func plannerFloatTarget(_ record: WindowRecord, size: CGSize?) -> CGRect? {
		let home = plannerMonitor(of: record)
		if let floating = record.floatingFrame {
			let monitor = monitors[floating.monitor] != nil ? floating.monitor : home
			if let monitor, let visibleFrame = monitors[monitor]?.visibleFrame {
				return floating.frame(in: visibleFrame)
			}
		}
		if let last = record.lastVisibleFrame {
			return last
		}
		guard let size, let home, let visibleFrame = monitors[home]?.visibleFrame else { return nil }
		return RelativeFrame.centred(size: size, monitor: home, visibleFrame: visibleFrame).frame(in: visibleFrame)
	}

	/// Keeps a shown window's last visible frame, and a floating or unmanaged window's floating
	/// frame, current from the window server's bounds, unless a write of ours is newer than them or
	/// the window is out of sight.
	private mutating func plannerNoteVisibleFrame(_ record: WindowRecord, snapshot: ServerSnapshot, connected: [MonitorState]) {
		let id = record.id
		guard let bounds = snapshot.windows[id]?.bounds,
			ledger[id].map({ $0.at <= snapshot.takenAt }) ?? true,
			!ParkGeometry.isEffectivelyHidden(bounds, monitors: connected)
		else { return }
		if record.lastVisibleFrame != bounds {
			records[id]?.lastVisibleFrame = bounds
		}
		guard record.placement != .tiled,
			let monitor = record.workspace.flatMap({ workspaces[$0]?.host }) ?? monitorKey(for: bounds),
			let visibleFrame = monitors[monitor]?.visibleFrame
		else { return }
		let floating = RelativeFrame(frame: bounds, monitor: monitor, visibleFrame: visibleFrame)
		if record.floatingFrame != floating {
			records[id]?.floatingFrame = floating
		}
	}

	// MARK: Output

	private func plannerAction(_ record: WindowRecord, _ kind: PlanAction.Kind, reason: ActionReason, observed: CGRect?) -> PlanAction {
		PlanAction(window: record.id, pid: record.pid, kind: kind, reason: reason, observed: observed, label: describe(record))
	}

	/// Actions grouped per app, apps in the order their first action came up.
	private static func plannerGroups(_ actions: [PlanAction]) -> [PlanGroup] {
		var order: [PID] = []
		var byApp: [PID: [PlanAction]] = [:]
		for action in actions {
			if byApp[action.pid] == nil {
				order.append(action.pid)
			}
			byApp[action.pid, default: []].append(action)
		}
		return order.map { PlanGroup(pid: $0, actions: byApp[$0] ?? []) }
	}

	/// How enforcement lines name a hidden state: "parked (workspaceInactive)", "zenHidden", ...
	private static func plannerExpectationText(_ visibility: Visibility) -> String {
		if case .parked(let reason) = visibility {
			switch reason {
			case .workspaceInactive: return "parked (workspaceInactive)"
			}
		}
		return visibility.logName
	}
}
