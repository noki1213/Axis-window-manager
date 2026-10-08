//
//  PlannerTests.swift
//  Axis core tests
//
//  The planner that turns desired and observed frames into writes, and the write ledger
//  that limits repeated corrections.
//

import Foundation
import CoreGraphics

let plannerTests: [TestCase] = comparisonTests + fightTests + parkTests + barrierTests + mouseTests
	+ switchTests + appTests + sessionTests + minimizeTests + layoutStateTests + quitTests + bookkeepingTests
	+ visibleFrameTests

private let main = testKey("Main")

// Slots on the default main display (visible area 0,25 1440x875, gap and padding 12).
private let fullSlot = CGRect(x: 12, y: 37, width: 1416, height: 851)
private let leftSlot = CGRect(x: 12, y: 37, width: 702, height: 851)
private let rightSlot = CGRect(x: 726, y: 37, width: 702, height: 851)
/// Where windows park on the main display alone: its bottom-right corner.
private let parkPoint = CGPoint(x: 1439, y: 899)
/// Window 3 of `twoWorkspaces()` parked.
private let parkedThree = CGRect(x: 1439, y: 899, width: 600, height: 400)
/// Window 3 brought on screen by something else.
private let shownThree = CGRect(x: 190, y: 190, width: 600, height: 400)

/// The window server showing these windows at these frames (pid 100 unless given).
private func showing(_ frames: [WindowID: CGRect], pids: [WindowID: PID] = [:], at time: Time) -> ServerSnapshot {
	ServerSnapshot(frames.map { ServerWindow(id: $0.key, pid: pids[$0.key] ?? 100, bounds: $0.value) }, takenAt: time)
}

/// What the actuator reports after carrying out `plan`: every write lands on its target unless
/// `results` gives where the window ended up.
private func landed(_ plan: Plan, results: [WindowID: CGRect] = [:]) -> [WriteResult] {
	plan.actions.map { action in
		switch action.kind {
		case .setFrame(let frame):
			return WriteResult(window: action.window, pid: action.pid, kind: .frame, target: frame,
				result: results[action.window] ?? frame)
		case .park(let origin):
			let target = CGRect(origin: origin, size: action.observed?.size ?? .zero)
			return WriteResult(window: action.window, pid: action.pid, kind: .park, target: target,
				result: results[action.window] ?? target)
		case .minimize:
			return WriteResult(window: action.window, pid: action.pid, kind: .minimize, target: .zero)
		case .unminimize:
			return WriteResult(window: action.window, pid: action.pid, kind: .unminimize, target: .zero)
		}
	}
}

private func setFrame(_ id: WindowID, _ frame: CGRect, _ reason: ActionReason, observed: CGRect?, pid: PID = 100,
	label: String? = nil) -> PlanAction {
	PlanAction(window: id, pid: pid, kind: .setFrame(frame), reason: reason, observed: observed, label: label ?? "App/W\(id)#\(id)")
}

private func park(_ id: WindowID, at origin: CGPoint = parkPoint, _ reason: ActionReason, observed: CGRect?, pid: PID = 100,
	label: String? = nil) -> PlanAction {
	PlanAction(window: id, pid: pid, kind: .park(origin), reason: reason, observed: observed, label: label ?? "App/W\(id)#\(id)")
}

private let inactive = Visibility.parked(.workspaceInactive)

/// Main with two workspaces: the active one holds windows 1 and 2 side by side, the other one
/// window 3 (app "Other", pid 200), parked.
private func twoWorkspaces() -> (state: TrackingState, active: WorkspaceID, other: WorkspaceID) {
	var state = testState()
	let row = state.testSetRow(nonNegatives: 2, active: 0)
	state.testSetColumns(row[0], [[1], [2]])
	state.testAddWindow(3, workspace: row[1], visibility: inactive, pid: 200, app: "Other")
	state.testSetColumns(row[1], [[3]])
	return (state, row[0], row[1])
}

/// Everything of `twoWorkspaces()` where it belongs.
private func settled(at time: Time) -> ServerSnapshot {
	showing([1: leftSlot, 2: rightSlot, 3: parkedThree], pids: [3: 200], at: time)
}

/// Switches Main to `workspace` and gives the members of both workspaces the visibility normalize
/// would (records are rebuilt, so session fields such as floating frames start over).
private func switchTo(_ workspace: WorkspaceID, from previous: WorkspaceID, _ state: inout TrackingState) {
	state.switchWorkspace(on: main, to: .id(workspace))
	for (members, visibility) in [(state.members(of: previous), inactive), (state.members(of: workspace), .visible)] {
		for id in members {
			let record = state.records[id]!
			state.testAddWindow(id, placement: record.placement, workspace: record.workspace, visibility: visibility,
				pid: record.pid, app: record.appName, title: record.title, frame: record.observed.frame)
		}
	}
}

/// Fails unless the follow-ups are frame passes with these times (within a nanosecond) and reasons.
private func expectFollowUps(_ actual: [FollowUp], _ expected: [(at: Time, reason: String)],
	file: StaticString = #filePath, line: UInt = #line) {
	expectEqual(actual.map(\.reason), expected.map(\.reason), file: file, line: line)
	expect(actual.allSatisfy { $0.kind == .frames }, "\(actual)", file: file, line: line)
	for (followUp, target) in zip(actual, expected) {
		expectEqual(followUp.at, target.at, accuracy: 1e-9, followUp.reason, file: file, line: line)
	}
}

// MARK: - Comparison

private let comparisonTests: [TestCase] = [
	TestCase("nothing is written while every window is in its slot") {
		var (state, _, _) = twoWorkspaces()
		let plan = state.plan(snapshot: settled(at: 1), options: PlanOptions(), now: 1)
		expect(plan.isEmpty, "\(plan)")
		expectEqual(state.expectedFrame(1), leftSlot)
		expectEqual(state.expectedFrame(2), rightSlot)
		expectEqual(state.expectedFrame(3), parkedThree)
		expectEqual(state.log, [])
		expectInvariants(state)
	},

	TestCase("a window away from a new slot is laid out, a drift from an unchanged slot is enforced") {
		var (state, _, _) = twoWorkspaces()
		let opened = CGRect(x: 300, y: 200, width: 500, height: 400)
		var plan = state.plan(snapshot: showing([1: leftSlot, 2: opened, 3: parkedThree], pids: [3: 200], at: 1),
			options: PlanOptions(), now: 1)
		expectEqual(plan.show, [PlanGroup(pid: 100, actions: [setFrame(2, rightSlot, .layout, observed: opened)])])
		expectEqual(plan.hide, [])
		expectEqual(state.log, [])
		state.recordWrites(landed(plan), now: 1.01)

		let dragged = CGRect(x: 700, y: 300, width: 702, height: 851)
		plan = state.plan(snapshot: showing([1: leftSlot, 2: dragged, 3: parkedThree], pids: [3: 200], at: 5),
			options: PlanOptions(), now: 5)
		expectEqual(plan.actions, [setFrame(2, rightSlot, .enforce(observed: dragged, expected: .visible), observed: dragged)])
		expectEqual(state.drainLog(), [TrackingLog("enforce: App/W2#2 slot drift 700,300 702x851 vs 726,37 702x851; re-applying")])
		expectInvariants(state)
	},

	TestCase("frames within 2 points of the slot need no write") {
		var (state, _, _) = twoWorkspaces()
		let near = CGRect(x: 14, y: 35, width: 704, height: 849)
		var plan = state.plan(snapshot: showing([1: near, 2: rightSlot, 3: parkedThree], pids: [3: 200], at: 1),
			options: PlanOptions(), now: 1)
		expect(plan.isEmpty, "\(plan)")
		let off = CGRect(x: 15, y: 37, width: 702, height: 851)
		plan = state.plan(snapshot: showing([1: off, 2: rightSlot, 3: parkedThree], pids: [3: 200], at: 2),
			options: PlanOptions(), now: 2)
		expectEqual(plan.actions.map(\.window), [1])
	},

	TestCase("a size the app clamped after a write of the same slot is accepted") {
		var (state, active, _) = twoWorkspaces()
		let opened = CGRect(x: 300, y: 200, width: 500, height: 400)
		var plan = state.plan(snapshot: showing([1: leftSlot, 2: opened, 3: parkedThree], pids: [3: 200], at: 1),
			options: PlanOptions(), now: 1)
		// The app snaps its size to whole text cells.
		let snapped = CGRect(x: 726, y: 37, width: 696, height: 840)
		state.recordWrites(landed(plan, results: [2: snapped]), now: 1.01)
		expectEqual(state.ledger[2], LastWrite(target: rightSlot, kind: .frame, result: snapped, at: 1.01))

		plan = state.plan(snapshot: showing([1: leftSlot, 2: snapped, 3: parkedThree], pids: [3: 200], at: 1.5),
			options: PlanOptions(), now: 1.5)
		expect(plan.isEmpty, "\(plan)")
		expectEqual(state.ledger[2]?.fights, 0)

		// A new column gives it another slot: the old result no longer counts.
		state.testSetColumns(active, [[1], [2], [4]])
		plan = state.plan(snapshot: showing([1: leftSlot, 2: snapped, 3: parkedThree, 4: opened], pids: [3: 200], at: 2),
			options: PlanOptions(), now: 2)
		let middle = CGRect(x: 488, y: 37, width: 464, height: 851)
		expectEqual(plan.actions.first { $0.window == 2 }, setFrame(2, middle, .layout, observed: snapped))
		expectEqual(plan.actions.map(\.window), [1, 2, 4])
	},

	TestCase("a window whose last write was its slot is rewritten when it is seen elsewhere") {
		var (state, _, _) = twoWorkspaces()
		var plan = state.plan(snapshot: settled(at: 1), options: PlanOptions(), now: 1)
		state.recordWrites([WriteResult(window: 1, pid: 100, kind: .frame, target: leftSlot, result: leftSlot)], now: 1.2)
		// Something else moved it to the corner; the ledger still says it is in its slot.
		let cornered = CGRect(x: 1439, y: 899, width: 702, height: 851)
		plan = state.plan(snapshot: showing([1: cornered, 2: rightSlot, 3: parkedThree], pids: [3: 200], at: 3),
			options: PlanOptions(), now: 3)
		expectEqual(plan.actions, [setFrame(1, leftSlot, .enforce(observed: cornered, expected: .visible), observed: cornered)])
	},

	TestCase("a write newer than the snapshot is judged by its read-back") {
		var (state, _, _) = twoWorkspaces()
		let opened = CGRect(x: 300, y: 200, width: 500, height: 400)
		let before = showing([1: leftSlot, 2: opened, 3: parkedThree], pids: [3: 200], at: 1)
		let plan = state.plan(snapshot: before, options: PlanOptions(), now: 1)
		state.recordWrites(landed(plan), now: 1.01)
		// A command planned right after, from the same snapshot, does not write again.
		expect(state.plan(snapshot: before, options: PlanOptions(isCommand: true), now: 1.02).isEmpty)
	},

	TestCase("a window its app announced as destroyed gets no writes until the doubt is cleared") {
		var (state, _, _) = twoWorkspaces()
		_ = state.plan(snapshot: settled(at: 1), options: PlanOptions(), now: 1)
		// Window 2 shrinks while its close animation runs, and window 3 is seen on screen while it closes.
		let closing = CGRect(x: 730, y: 40, width: 690, height: 840)
		state.records[2]?.liveness.pendingDestroySince = 1.9
		state.records[3]?.liveness.pendingDestroySince = 1.9
		var plan = state.plan(snapshot: showing([1: leftSlot, 2: closing, 3: shownThree], pids: [3: 200], at: 2),
			options: PlanOptions(), now: 2)
		expect(plan.isEmpty, "\(plan)")
		expectEqual(state.log, [])

		// A scan lists them again: they are corrected like any window off its place.
		state.records[2]?.liveness.pendingDestroySince = nil
		state.records[3]?.liveness.pendingDestroySince = nil
		plan = state.plan(snapshot: showing([1: leftSlot, 2: closing, 3: shownThree], pids: [3: 200], at: 3),
			options: PlanOptions(), now: 3)
		expectEqual(plan.show, [PlanGroup(pid: 100, actions: [
			setFrame(2, rightSlot, .enforce(observed: closing, expected: .visible), observed: closing),
		])])
		expectEqual(plan.hide.flatMap(\.actions).map(\.window), [3])
		expectEqual(state.log.map(\.message), [
			"enforce: App/W2#2 slot drift 730,40 690x840 vs 726,37 702x851; re-applying",
			"enforce: Other/W3#3 found at 190,190 600x400, expected parked (workspaceInactive); re-parking",
		])
	},

	TestCase("a destroy that is never confirmed does not leave the window unplaced for good") {
		var (state, _, _) = twoWorkspaces()
		_ = state.plan(snapshot: settled(at: 1), options: PlanOptions(), now: 1)
		let away = CGRect(x: 730, y: 40, width: 690, height: 840)
		state.records[2]?.liveness.pendingDestroySince = 2
		let snapshot = { (time: Time) in showing([1: leftSlot, 2: away, 3: parkedThree], pids: [3: 200], at: time) }
		expect(state.plan(snapshot: snapshot(3.9), options: PlanOptions(), now: 3.9).isEmpty)
		let plan = state.plan(snapshot: snapshot(4), options: PlanOptions(), now: 4)
		expectEqual(plan.actions.map(\.window), [2])
	},

]

// MARK: - Fights

private let fightTests: [TestCase] = [
	TestCase("a window moved back within a second of each write is given up on for 30 seconds") {
		var state = testState()
		state.testSetColumns(state.testActive(), [[1]])
		let away = CGRect(x: 100, y: 100, width: 600, height: 400)
		var plan = state.plan(snapshot: showing([1: away], at: 0), options: PlanOptions(), now: 0)
		expectEqual(plan.actions, [setFrame(1, fullSlot, .layout, observed: away)])
		state.recordWrites(landed(plan), now: 0.01)

		for (index, (time, written)) in [(0.5, 0.51), (1.0, 1.01)].enumerated() {
			plan = state.plan(snapshot: showing([1: away], at: time), options: PlanOptions(), now: time)
			expectEqual(plan.actions, [setFrame(1, fullSlot, .enforce(observed: away, expected: .visible), observed: away)], "fight \(index + 1)")
			expectEqual(state.ledger[1]?.fights, index + 1)
			state.recordWrites(landed(plan), now: written)
			expectEqual(state.ledger[1]?.fights, index + 1, "kept by the write of the same target")
		}
		expectFollowUps(state.plannerFollowUps(now: 1.01), [(1.51, "fight check")])
		_ = state.drainLog()

		plan = state.plan(snapshot: showing([1: away], at: 1.5), options: PlanOptions(), now: 1.5)
		expect(plan.isEmpty, "third fight gives up")
		expectEqual(state.drainLog(), [TrackingLog("enforce: giving up on App/W1#1 for 30s (3 fights)")])
		expectEqual(state.ledger[1]?.gaveUpUntil, 31.5)

		plan = state.plan(snapshot: showing([1: away], at: 10), options: PlanOptions(), now: 10)
		expect(plan.isEmpty, "left alone while given up")
		expectEqual(state.log, [])
		expectFollowUps(state.plannerFollowUps(now: 10), [(31.5, "enforcement resumes")])

		plan = state.plan(snapshot: showing([1: away], at: 32), options: PlanOptions(), now: 32)
		expectEqual(plan.actions, [setFrame(1, fullSlot, .enforce(observed: away, expected: .visible), observed: away)])
		expectEqual(state.ledger[1]?.fights, 0)
		expectEqual(state.ledger[1]?.gaveUpUntil, nil)
		expectEqual(state.plannerFollowUps(now: 32), [])
	},

	TestCase("a parked window that comes back after each park is given up on within a second") {
		var (state, _, _) = twoWorkspaces()
		_ = state.plan(snapshot: settled(at: 1), options: PlanOptions(), now: 1)

		// The app puts window 3 back on screen a moment after every park, so the passes in between
		// find it out of sight.
		var parks: [Time] = []
		var time: Time = 2
		for step in 0..<12 {
			let shown = step % 2 == 0
			let plan = state.plan(snapshot: showing([1: leftSlot, 2: rightSlot, 3: shown ? shownThree : parkedThree],
				pids: [3: 200], at: time), options: PlanOptions(), now: time)
			if !plan.isEmpty {
				parks.append(time)
				state.recordWrites(landed(plan), now: time + 0.005)
			}
			time += 0.05
		}
		expectEqual(parks.count, 3, "corrected at \(parks)")
		expectEqual(state.log.filter { $0.message.hasPrefix("enforce: giving up") }.map(\.message),
			["enforce: giving up on Other/W3#3 for 30s (3 fights)"])
		expectEqual(state.ledger[3]?.gaveUpUntil, 2.3 + 30)

		// Once the pause is over it is corrected again.
		let plan = state.plan(snapshot: showing([1: leftSlot, 2: rightSlot, 3: shownThree], pids: [3: 200], at: 40),
			options: PlanOptions(), now: 40)
		expectEqual(plan.actions.map(\.kind), [.park(parkPoint)])
		expectEqual(state.ledger[3]?.fights, 0)
		expectEqual(state.ledger[3]?.gaveUpUntil, nil)
	},

	TestCase("a window back in place ends its run of fights") {
		var state = testState()
		state.testSetColumns(state.testActive(), [[1]])
		let away = CGRect(x: 100, y: 100, width: 600, height: 400)
		var plan = state.plan(snapshot: showing([1: away], at: 0), options: PlanOptions(), now: 0)
		state.recordWrites(landed(plan), now: 0.01)
		plan = state.plan(snapshot: showing([1: away], at: 0.5), options: PlanOptions(), now: 0.5)
		state.recordWrites(landed(plan), now: 0.51)
		expectEqual(state.ledger[1]?.fights, 1)
		plan = state.plan(snapshot: showing([1: fullSlot], at: 0.8), options: PlanOptions(), now: 0.8)
		expect(plan.isEmpty)
		expectEqual(state.ledger[1]?.fights, 0)
	},
]

// MARK: - Parking

private let parkTests: [TestCase] = [
	TestCase("a parked window seen on screen is parked again with an enforcement line") {
		var (state, _, _) = twoWorkspaces()
		_ = state.plan(snapshot: settled(at: 1), options: PlanOptions(), now: 1)
		let plan = state.plan(snapshot: showing([1: leftSlot, 2: rightSlot, 3: shownThree], pids: [3: 200], at: 2),
			options: PlanOptions(), now: 2)
		expectEqual(plan.show, [])
		expectEqual(plan.hide, [PlanGroup(pid: 200, actions: [
			park(3, .enforce(observed: shownThree, expected: inactive), observed: shownThree, pid: 200, label: "Other/W3#3"),
		])])
		expectEqual(state.drainLog(), [
			TrackingLog("enforce: Other/W3#3 found at 190,190 600x400, expected parked (workspaceInactive); re-parking"),
		])
		expectEqual(state.expectedFrame(3), parkedThree)
	},

	TestCase("moves of a parked window spaced over a second apart are always corrected") {
		var (state, _, _) = twoWorkspaces()
		_ = state.plan(snapshot: settled(at: 1), options: PlanOptions(), now: 1)
		var plan = state.plan(snapshot: showing([1: leftSlot, 2: rightSlot, 3: shownThree], pids: [3: 200], at: 2),
			options: PlanOptions(), now: 2)
		state.recordWrites(landed(plan), now: 2.01)
		let movedAgain = CGRect(x: 300, y: 250, width: 600, height: 400)
		plan = state.plan(snapshot: showing([1: leftSlot, 2: rightSlot, 3: movedAgain], pids: [3: 200], at: 4),
			options: PlanOptions(), now: 4)
		expectEqual(plan.actions.map(\.kind), [.park(parkPoint)])
		expectEqual(state.ledger[3]?.fights, 0)
		state.recordWrites(landed(plan), now: 4.01)
		// Back on screen within a second: a fight, still corrected.
		plan = state.plan(snapshot: showing([1: leftSlot, 2: rightSlot, 3: movedAgain], pids: [3: 200], at: 4.5),
			options: PlanOptions(), now: 4.5)
		expectEqual(plan.actions.map(\.kind), [.park(parkPoint)])
		expectEqual(state.ledger[3]?.fights, 1)
	},

	TestCase("the palette parks the managed windows and writes nothing to an unmanaged one") {
		var (state, _, _) = twoWorkspaces()
		// An overlay no workspace owns, which refuses to move.
		let overlay = CGRect(x: 415, y: 636, width: 640, height: 320)
		state.testAddWindow(4, placement: .unmanaged, workspace: nil, pid: 300, app: "Overlay", frame: overlay)
		let snapshot = showing([1: leftSlot, 2: rightSlot, 3: parkedThree, 4: overlay], pids: [3: 200, 4: 300], at: 1)
		_ = state.plan(snapshot: snapshot, options: PlanOptions(), now: 1)

		state.paletteBegin(now: 2)
		state.normalize(now: 2)
		var plan = state.plan(snapshot: snapshot, options: PlanOptions(isCommand: true), now: 2)
		expectEqual(plan.show, [])
		expectEqual(plan.hide, [PlanGroup(pid: 100, actions: [
			park(1, .park(.paletteHidden), observed: leftSlot),
			park(2, .park(.paletteHidden), observed: rightSlot),
		])])
		state.recordWrites(landed(plan), now: 2.01)

		// Passes while the palette is open leave it alone.
		for step in 1...5 {
			let time = 2 + Time(step) * 0.1
			plan = state.plan(snapshot: showing([1: CGRect(origin: parkPoint, size: leftSlot.size),
				2: CGRect(origin: parkPoint, size: rightSlot.size), 3: parkedThree, 4: overlay], pids: [3: 200, 4: 300], at: time),
				options: PlanOptions(), now: time)
			expect(plan.isEmpty, "\(plan)")
		}
		expectEqual(state.records[4]?.visibility, .visible)
		expectEqual(state.log.filter { $0.message.contains("Overlay") }, [])
	},

	TestCase("a window entering a parked state is parked in the hide phase without an enforcement line") {
		var (state, active, other) = twoWorkspaces()
		_ = state.plan(snapshot: settled(at: 1), options: PlanOptions(), now: 1)
		switchTo(other, from: active, &state)
		let plan = state.plan(snapshot: settled(at: 2), options: PlanOptions(isCommand: true), now: 2)
		expectEqual(plan.show, [PlanGroup(pid: 200, actions: [
			setFrame(3, fullSlot, .unpark(from: inactive), observed: parkedThree, pid: 200, label: "Other/W3#3"),
		])])
		expectEqual(plan.hide, [PlanGroup(pid: 100, actions: [
			park(1, .park(inactive), observed: leftSlot),
			park(2, .park(inactive), observed: rightSlot),
		])])
		expectEqual(state.log.filter { $0.message.hasPrefix("enforce:") }, [])
		expectEqual(state.expectedFrame(1), CGRect(origin: parkPoint, size: leftSlot.size))
		expectInvariants(state)
	},

	TestCase("where macOS left the last park is accepted at the same corner, not after the corner moved") {
		var (state, _, _) = twoWorkspaces()
		_ = state.plan(snapshot: settled(at: 1), options: PlanOptions(), now: 1)
		var plan = state.plan(snapshot: showing([1: leftSlot, 2: rightSlot, 3: shownThree], pids: [3: 200], at: 2),
			options: PlanOptions(), now: 2)
		// macOS keeps more of it on screen than asked.
		let nudged = CGRect(x: 1430, y: 890, width: 600, height: 400)
		state.recordWrites(landed(plan, results: [3: nudged]), now: 2.01)
		plan = state.plan(snapshot: showing([1: leftSlot, 2: rightSlot, 3: nudged], pids: [3: 200], at: 3),
			options: PlanOptions(), now: 3)
		expect(plan.isEmpty, "\(plan)")
		expectEqual(state.log.count, 1)

		// A display on the right moves parking to the left corner.
		state.addMonitor(testDisplay("Right", x: 1440, width: 1920, height: 1080, displayID: 2))
		plan = state.plan(snapshot: showing([1: leftSlot, 2: rightSlot, 3: nudged], pids: [3: 200], at: 4),
			options: PlanOptions(), now: 4)
		expectEqual(plan.actions.map(\.kind), [.park(CGPoint(x: -599, y: 899))])
	},

	TestCase("parking uses the corner away from a neighbouring display") {
		var state = testState([testDisplay("Main", primary: true), testDisplay("Right", x: 1440, width: 1920, height: 1080, displayID: 2)])
		let row = state.testSetRow(nonNegatives: 2, active: 0)
		state.testAddWindow(3, workspace: row[1], visibility: inactive)
		state.testSetColumns(row[1], [[3]])
		let plan = state.plan(snapshot: showing([3: shownThree], at: 1), options: PlanOptions(), now: 1)
		expectEqual(plan.actions.map(\.kind), [.park(CGPoint(x: -599, y: 899))])
		expectEqual(state.expectedFrame(3), CGRect(x: -599, y: 899, width: 600, height: 400))
	},

	TestCase("a parked window not on screen needs nothing") {
		var (state, _, _) = twoWorkspaces()
		let plan = state.plan(snapshot: showing([1: leftSlot, 2: rightSlot], at: 1), options: PlanOptions(), now: 1)
		expect(plan.isEmpty)
		expectEqual(state.plannerState.parked[3], inactive)
	},
]

// MARK: - Barriers

private let barrierTests: [TestCase] = [
	TestCase("enforcement plans nothing while any barrier is up") {
		for reason in BarrierReason.allCases {
			var (state, _, _) = twoWorkspaces()
			_ = state.plan(snapshot: settled(at: 1), options: PlanOptions(), now: 1)
			state.barrier = [reason]
			let drifted = CGRect(x: 40, y: 60, width: 702, height: 851)
			let plan = state.plan(snapshot: showing([1: drifted, 2: rightSlot, 3: shownThree], pids: [3: 200], at: 2),
				options: PlanOptions(), now: 2)
			expectEqual(plan, Plan(), reason.logName)
			expectEqual(state.log, [], reason.logName)
		}
	},

	TestCase("commands are held while locked, asleep or reconfiguring, not for Mission Control or startup") {
		for reason in BarrierReason.allCases {
			var (state, active, other) = twoWorkspaces()
			_ = state.plan(snapshot: settled(at: 1), options: PlanOptions(), now: 1)
			state.barrier = [reason]
			switchTo(other, from: active, &state)
			let plan = state.plan(snapshot: settled(at: 2), options: PlanOptions(isCommand: true), now: 2)
			switch reason {
			case .locked, .asleep, .displayChanging:
				expectEqual(plan, Plan(withheldByBarrier: true), reason.logName)
			case .starting, .missionControl:
				expectEqual(plan.actions.map(\.window), [3, 1, 2], reason.logName)
				expect(!plan.withheldByBarrier, reason.logName)
			}
		}
	},

	TestCase("a command under Mission Control does not enforce drifted windows") {
		var (state, _, _) = twoWorkspaces()
		_ = state.plan(snapshot: settled(at: 1), options: PlanOptions(), now: 1)
		state.barrier = [.missionControl]
		let drifted = CGRect(x: 40, y: 60, width: 702, height: 851)
		let plan = state.plan(snapshot: showing([1: drifted, 2: rightSlot, 3: shownThree], pids: [3: 200], at: 2),
			options: PlanOptions(isCommand: true), now: 2)
		expect(plan.isEmpty, "\(plan)")
		expectEqual(state.log, [])
	},

	TestCase("the hide phase a switch left for later runs under Mission Control but not while locked") {
		var (state, active, other) = twoWorkspaces()
		_ = state.plan(snapshot: settled(at: 1), options: PlanOptions(), now: 1)
		switchTo(other, from: active, &state)
		var plan = state.plan(snapshot: settled(at: 2), options: PlanOptions(isCommand: true, includeHidePhase: false), now: 2)
		state.recordWrites(landed(plan), now: 2.01)
		state.barrier = [.missionControl]
		let snapshot = showing([1: leftSlot, 2: rightSlot, 3: fullSlot], pids: [3: 200], at: 2.05)
		plan = state.plan(snapshot: snapshot, options: PlanOptions(), now: 2.05)
		expectEqual(plan.show, [])
		expectEqual(plan.actions.map(\.window), [1, 2])
		expectEqual(state.plannerState.hidePhaseDue, nil)

		var locked = state
		locked.plannerState.hidePhaseDue = 3
		locked.barrier = [.locked]
		expect(locked.plan(snapshot: snapshot, options: PlanOptions(), now: 3).isEmpty)
		expectEqual(locked.plannerState.hidePhaseDue, nil, "the pass after the barrier plans everything")
	},
]

// MARK: - Mouse button

private let mouseTests: [TestCase] = [
	TestCase("enforcement waits while the mouse button is down and goes out on release") {
		var (state, _, _) = twoWorkspaces()
		_ = state.plan(snapshot: settled(at: 1), options: PlanOptions(), now: 1)
		let dragged = CGRect(x: 760, y: 120, width: 702, height: 851)
		let snapshot = showing([1: leftSlot, 2: dragged, 3: shownThree], pids: [3: 200], at: 2)
		var plan = state.plan(snapshot: snapshot, options: PlanOptions(mouseDown: true), now: 2)
		expect(plan.isEmpty, "\(plan)")
		expect(plan.deferredByMouse)
		expectEqual(state.log, [])

		plan = state.plan(snapshot: snapshot, options: PlanOptions(), now: 2.5)
		expectEqual(plan.show, [PlanGroup(pid: 100, actions: [
			setFrame(2, rightSlot, .enforce(observed: dragged, expected: .visible), observed: dragged),
		])])
		expectEqual(plan.hide.flatMap(\.actions).map(\.window), [3])
		expect(!plan.deferredByMouse)
	},

	TestCase("command writes do not wait for the mouse button") {
		var (state, active, other) = twoWorkspaces()
		_ = state.plan(snapshot: settled(at: 1), options: PlanOptions(), now: 1)
		switchTo(other, from: active, &state)
		let plan = state.plan(snapshot: settled(at: 2), options: PlanOptions(isCommand: true, mouseDown: true), now: 2)
		expectEqual(plan.actions.map(\.window), [3, 1, 2])
		expect(!plan.deferredByMouse)
	},
]

// MARK: - Workspace switch

private let switchTests: [TestCase] = [
	TestCase("a switch plans its hide phase 50 ms later from the state at that time") {
		var (state, active, other) = twoWorkspaces()
		_ = state.plan(snapshot: settled(at: 1), options: PlanOptions(), now: 1)
		switchTo(other, from: active, &state)
		var plan = state.plan(snapshot: settled(at: 2), options: PlanOptions(isCommand: true, includeHidePhase: false), now: 2)
		expectEqual(plan.actions.map(\.window), [3])
		expectEqual(plan.hide, [])
		expectFollowUps(state.plannerFollowUps(now: 2), [(2.05, "hide phase")])
		state.recordWrites(landed(plan), now: 2.01)

		// Back before the hide phase ran: the first workspace's windows never left their slots.
		switchTo(active, from: other, &state)
		let snapshot = showing([1: leftSlot, 2: rightSlot, 3: fullSlot], pids: [3: 200], at: 2.03)
		plan = state.plan(snapshot: snapshot, options: PlanOptions(isCommand: true, includeHidePhase: false), now: 2.03)
		expect(plan.isEmpty, "\(plan)")
		expectFollowUps(state.plannerFollowUps(now: 2.03), [(2.08, "hide phase")])

		// The delayed hide phase parks only what is out of sight now.
		plan = state.plan(snapshot: showing([1: leftSlot, 2: rightSlot, 3: fullSlot], pids: [3: 200], at: 2.08),
			options: PlanOptions(), now: 2.08)
		expectEqual(plan.show, [])
		expectEqual(plan.hide, [PlanGroup(pid: 200, actions: [
			park(3, .park(inactive), observed: fullSlot, pid: 200, label: "Other/W3#3"),
		])])
		expectEqual(state.plannerFollowUps(now: 2.08), [])
		expectInvariants(state)
	},

	TestCase("confirming the palette into another workspace brings only that workspace on screen") {
		var (state, _, other) = twoWorkspaces()
		state.paletteBegin(now: 1)
		state.normalize(now: 1)
		var plan = state.plan(snapshot: settled(at: 1), options: PlanOptions(isCommand: true), now: 1)
		expectEqual(plan.actions, [
			park(1, .park(.paletteHidden), observed: leftSlot),
			park(2, .park(.paletteHidden), observed: rightSlot),
		])
		state.recordWrites(landed(plan), now: 1.01)
		let parkedOne = CGRect(origin: parkPoint, size: leftSlot.size)
		let parkedTwo = CGRect(origin: parkPoint, size: rightSlot.size)

		// The session ends and the workspace switches in one command.
		state.paletteEnd()
		state.switchWorkspace(on: main, to: .id(other))
		state.normalize(now: 2)
		plan = state.plan(snapshot: showing([1: parkedOne, 2: parkedTwo, 3: parkedThree], pids: [3: 200], at: 2),
			options: PlanOptions(isCommand: true, includeHidePhase: false), now: 2)
		expectEqual(plan.actions, [
			setFrame(3, fullSlot, .unpark(from: inactive), observed: parkedThree, pid: 200, label: "Other/W3#3"),
		])
		state.recordWrites(landed(plan), now: 2.01)

		// The hide phase that follows has nothing to park: the palette parked those windows already.
		plan = state.plan(snapshot: showing([1: parkedOne, 2: parkedTwo, 3: fullSlot], pids: [3: 200], at: 2.05),
			options: PlanOptions(), now: 2.05)
		expect(plan.isEmpty, "\(plan)")
		expectEqual(state.records[1]?.visibility, inactive)
		expectInvariants(state)
	},
]

// MARK: - Apps

private let appTests: [TestCase] = [
	TestCase("actions are grouped per app in the order their windows come") {
		var state = testState()
		let home = state.testActive()
		state.testSetColumns(home, [[1], [2], [3]])
		state.testAddWindow(2, workspace: home, pid: 200, app: "Other")
		let away = CGRect(x: 100, y: 100, width: 300, height: 300)
		let plan = state.plan(snapshot: showing([1: away, 2: away, 3: away], pids: [2: 200], at: 1), options: PlanOptions(), now: 1)
		expectEqual(plan.show.map(\.pid), [100, 200])
		expectEqual(plan.show.map { $0.actions.map(\.window) }, [[1, 3], [2]])
	},

	TestCase("windows of an unresponsive app keep their slots and get no writes") {
		var (state, _, _) = twoWorkspaces()
		state.testAddWindow(2, workspace: state.testActive(), pid: 300, app: "Busy")
		state.apps[300] = AppState(pid: 300, name: "Busy", unresponsiveSince: 5)
		let away = CGRect(x: 100, y: 100, width: 300, height: 300)
		let plan = state.plan(snapshot: showing([1: away, 2: away, 3: shownThree], pids: [2: 300, 3: 200], at: 6),
			options: PlanOptions(), now: 6)
		// Window 1 keeps the left half: the busy window's slot stays.
		expectEqual(plan.show, [PlanGroup(pid: 100, actions: [setFrame(1, leftSlot, .layout, observed: away)])])
		expectEqual(plan.hide.map(\.pid), [200])
	},

	TestCase("a shown window out of sight while its app does not answer is left out of the layout until it answers") {
		var (state, active, _) = twoWorkspaces()
		state.testAddWindow(2, workspace: active, pid: 300, app: "Busy")
		state.workspaces[active]?.widthRatios = [0.3, 0.7]
		state.apps[300] = AppState(pid: 300, name: "Busy", unresponsiveSince: 5)
		let parkedTwo = CGRect(origin: parkPoint, size: rightSlot.size)
		var plan = state.plan(snapshot: showing([1: leftSlot, 2: parkedTwo, 3: parkedThree], pids: [2: 300, 3: 200], at: 6),
			options: PlanOptions(), now: 6)
		expectEqual(plan.actions, [setFrame(1, fullSlot, .layout, observed: leftSlot)])
		expectEqual(state.workspaces[active]?.widthRatios, [0.3, 0.7])
		expectEqual(state.drainLog(), [TrackingLog("layout: leave out Busy/W2#2 (app not answering, window out of sight)")])
		state.recordWrites(landed(plan), now: 6.01)

		// Answering again, it takes its slot back with the stored widths.
		state.ingestScan(pid: 300, result: .complete([WindowFacts(id: 2, pid: 300, title: "W2", frame: parkedTwo)]),
			serverHas: [], now: 7)
		_ = state.drainLog()
		plan = state.plan(snapshot: showing([1: fullSlot, 2: parkedTwo, 3: parkedThree], pids: [2: 300, 3: 200], at: 7),
			options: PlanOptions(), now: 7)
		let stored = ColumnLayout.frames(for: LayoutInput(columns: [[1], [2]], widthRatios: [0.3, 0.7]),
			visibleFrame: state.monitors[main]!.visibleFrame, config: state.config, reservation: nil).frames
		expectEqual(plan.actions, [
			setFrame(1, stored[1]!, .layout, observed: fullSlot),
			setFrame(2, stored[2]!, .layout, observed: parkedTwo, pid: 300, label: "Busy/W2#2"),
		])
		expectEqual(state.drainLog(), [TrackingLog("layout: Busy/W2#2 no longer left out")])
		expectInvariants(state)
	},

	TestCase("a window of an unanswering app that is on screen keeps its slot") {
		var (state, active, _) = twoWorkspaces()
		state.testAddWindow(2, workspace: active, pid: 300, app: "Busy")
		state.apps[300] = AppState(pid: 300, name: "Busy", unresponsiveSince: 5)
		let plan = state.plan(snapshot: showing([1: leftSlot, 2: rightSlot, 3: parkedThree], pids: [2: 300, 3: 200], at: 6),
			options: PlanOptions(), now: 6)
		expect(plan.isEmpty, "\(plan)")
		expectEqual(state.log, [])
	},

	TestCase("an app that did not answer a write is scanned again a second later and its windows are written once it answers") {
		var (state, _, _) = twoWorkspaces()
		state.apps[100] = AppState(pid: 100, name: "App")
		_ = state.plan(snapshot: settled(at: 1), options: PlanOptions(), now: 1)

		let away = CGRect(x: 100, y: 100, width: 300, height: 300)
		var plan = state.plan(snapshot: showing([1: away, 2: rightSlot, 3: parkedThree], pids: [3: 200], at: 2),
			options: PlanOptions(), now: 2)
		expectEqual(plan.actions.map(\.window), [1])
		// The write waits out its timeout.
		state.recordWrites([WriteResult(window: 1, pid: 100, kind: .frame, target: leftSlot, error: AXErrorCode.cannotComplete)], now: 2.3)
		expectEqual(state.apps[100]?.unresponsiveSince, 2.3)
		expectEqual(state.followUps(now: 2.3).filter { $0.kind == .scan(100) },
			[FollowUp(at: 3.3, kind: .scan(100), reason: "unreadable retry")])

		// Until the scan its windows get no writes.
		plan = state.plan(snapshot: showing([1: away, 2: rightSlot, 3: parkedThree], pids: [3: 200], at: 3),
			options: PlanOptions(), now: 3)
		expect(plan.isEmpty, "\(plan)")

		// The scan finds the app answering: the window is put where it belongs in the same pass.
		let listed = [WindowFacts(id: 1, pid: 100, title: "W1", frame: away), WindowFacts(id: 2, pid: 100, title: "W2", frame: rightSlot)]
		state.ingestScan(pid: 100, result: .complete(listed), serverHas: [], now: 3.3)
		expectEqual(state.apps[100]?.unresponsiveSince, nil)
		expectEqual(state.followUps(now: 3.3).filter { $0.kind == .scan(100) }, [])
		plan = state.plan(snapshot: showing([1: away, 2: rightSlot, 3: parkedThree], pids: [3: 200], at: 3.3),
			options: PlanOptions(), now: 3.3)
		expectEqual(plan.show, [PlanGroup(pid: 100, actions: [
			setFrame(1, leftSlot, .enforce(observed: away, expected: .visible), observed: away),
		])])
	},

	TestCase("rescans after writes the app keeps not answering come further apart, and an answered write starts over") {
		var (state, _, _) = twoWorkspaces()
		state.apps[100] = AppState(pid: 100, name: "App")
		let failure = WriteResult(window: 1, pid: 100, kind: .frame, target: leftSlot, error: AXErrorCode.cannotComplete)
		let listed = [WindowFacts(id: 1, pid: 100, title: "W1"), WindowFacts(id: 2, pid: 100, title: "W2")]
		var now: Time = 10
		var delays: [Time] = []
		for _ in 0..<6 {
			state.recordWrites([failure], now: now)
			delays.append((state.apps[100]?.nextRetryAt ?? 0) - now)
			// The app answers the scan but not the next write.
			now = state.apps[100]?.nextRetryAt ?? now
			state.ingestScan(pid: 100, result: .complete(listed), serverHas: [], now: now)
			expectEqual(state.apps[100]?.unresponsiveSince, nil)
		}
		expectEqual(delays, [1, 2, 4, 5, 5, 5])

		state.recordWrites([WriteResult(window: 1, pid: 100, kind: .frame, target: leftSlot, result: leftSlot)], now: now + 0.1)
		expectEqual(state.apps[100]?.writeFailures, 0)
		state.recordWrites([failure], now: now + 0.2)
		expectEqual(state.apps[100]?.nextRetryAt, now + 1.2)
	},

	TestCase("a write the app could not complete marks it unresponsive and is not recorded") {
		var (state, _, _) = twoWorkspaces()
		state.apps[200] = AppState(pid: 200, name: "Other")
		state.recordWrites([
			WriteResult(window: 3, pid: 200, kind: .park, target: parkedThree, error: AXErrorCode.cannotComplete),
			WriteResult(window: 3, pid: 200, kind: .park, target: parkedThree, error: AXErrorCode.cannotComplete),
		], now: 3)
		expectEqual(state.apps[200]?.unresponsiveSince, 3)
		expectEqual(state.ledger[3], nil)
		expectEqual(state.drainLog(), [TrackingLog("enforce: app Other did not answer a write; skipping its windows until it answers")])

		// Other failures are recorded without a read-back; writes to untracked windows are dropped.
		state.recordWrites([
			WriteResult(window: 1, pid: 100, kind: .frame, target: leftSlot, error: AXErrorCode.failure),
			WriteResult(window: 99, pid: 100, kind: .frame, target: leftSlot, result: leftSlot),
		], now: 4)
		expectEqual(state.ledger[1], LastWrite(target: leftSlot, kind: .frame, result: nil, at: 4))
		expectEqual(state.ledger[99], nil)
	},
]

// MARK: - Zen and floating windows

private let sessionTests: [TestCase] = [
	TestCase("the Zen window is centred and re-centred at the size it keeps") {
		var state = testState()
		let home = state.testActive()
		state.testSetColumns(home, [[1], [2]], visibility: [2: .zenHidden])
		state.zen = ZenSession(monitor: main, workspace: home, focus: 1)
		let zenFrame = CGRect(x: 180, y: 37, width: 1080, height: 851)
		var plan = state.plan(snapshot: showing([1: leftSlot, 2: rightSlot], at: 1), options: PlanOptions(isCommand: true), now: 1)
		expectEqual(plan.show, [PlanGroup(pid: 100, actions: [setFrame(1, zenFrame, .zenCentre, observed: leftSlot)])])
		expectEqual(plan.hide, [PlanGroup(pid: 100, actions: [park(2, .park(.zenHidden), observed: rightSlot)])])

		// A fixed-size window keeps 800x600 at the requested origin.
		let kept = CGRect(x: 180, y: 37, width: 800, height: 600)
		state.recordWrites(landed(plan, results: [1: kept]), now: 1.01)
		let parkedTwo = CGRect(origin: parkPoint, size: rightSlot.size)
		plan = state.plan(snapshot: showing([1: kept, 2: parkedTwo], at: 2), options: PlanOptions(), now: 2)
		let centred = CGRect(x: 320, y: 162.5, width: 800, height: 600)
		expectEqual(plan.actions, [setFrame(1, centred, .zenCentre, observed: kept)])
		state.recordWrites(landed(plan), now: 2.01)

		plan = state.plan(snapshot: showing([1: centred, 2: parkedTwo], at: 3), options: PlanOptions(), now: 3)
		expect(plan.isEmpty, "\(plan)")
		expectEqual(state.expectedFrame(1), centred)

		// Dragged off centre: back on release.
		let dragged = CGRect(x: 500, y: 200, width: 800, height: 600)
		plan = state.plan(snapshot: showing([1: dragged, 2: parkedTwo], at: 5), options: PlanOptions(), now: 5)
		expectEqual(plan.actions, [setFrame(1, centred, .enforce(observed: dragged, expected: .visible), observed: dragged)])
		expectEqual(state.drainLog().last, TrackingLog("enforce: App/W1#1 zen frame drift 500,200 800x600 vs 320,163 800x600; re-applying"))

		// Zen ends: the refused size is forgotten and the window returns to its slot.
		state.zen = nil
		state.testAddWindow(2, workspace: home)
		plan = state.plan(snapshot: showing([1: centred, 2: parkedTwo], at: 6), options: PlanOptions(isCommand: true), now: 6)
		expectEqual(state.plannerState.zenRefusal, nil)
		expectEqual(plan.actions.map(\.kind), [.setFrame(leftSlot), .setFrame(rightSlot)])
		expectInvariants(state)
	},

	TestCase("a floating Zen window keeps its floating frame while centred and returns to it when Zen ends") {
		var state = testState()
		let home = state.testActive()
		state.testSetColumns(home, [[1]])
		state.testAddWindow(5, placement: .floating, workspace: home)
		state.records[5]!.floatingFrame = RelativeFrame(monitor: main, offset: CGPoint(x: 100, y: 50), size: CGSize(width: 500, height: 300))
		let floated = CGRect(x: 100, y: 75, width: 500, height: 300)
		let zenFrame = CGRect(x: 180, y: 37, width: 1080, height: 851)
		let parkedOne = CGRect(origin: parkPoint, size: fullSlot.size)

		expect(state.zenEnter(5, now: 1))
		state.normalize(now: 1)
		expectEqual(state.records[1]?.visibility, .zenHidden)
		var plan = state.plan(snapshot: showing([1: fullSlot, 5: floated], at: 1), options: PlanOptions(isCommand: true), now: 1)
		expectEqual(plan.actions, [
			setFrame(5, zenFrame, .zenCentre, observed: floated),
			park(1, .park(.zenHidden), observed: fullSlot),
		])
		state.recordWrites(landed(plan), now: 1.01)

		// Commands note where shown windows are; the centred window keeps the frame it floated at.
		state.noteVisibleFrames(snapshot: showing([1: parkedOne, 5: zenFrame], at: 2))
		expectEqual(state.records[5]?.floatingFrame?.frame(in: CGRect(x: 0, y: 25, width: 1440, height: 875)), floated)

		state.zenExit(reason: .user)
		state.normalize(now: 3)
		plan = state.plan(snapshot: showing([1: parkedOne, 5: zenFrame], at: 3), options: PlanOptions(isCommand: true), now: 3)
		expectEqual(plan.actions, [
			setFrame(1, fullSlot, .unpark(from: .zenHidden), observed: parkedOne),
			setFrame(5, floated, .floatRestore, observed: zenFrame),
		])
		expectEqual(state.records[5]?.pendingFloatRestore, false)
		expectInvariants(state)
	},

	TestCase("a floating window moves to its floating frame once and then follows the user") {
		var state = testState()
		let home = state.testActive()
		state.testAddWindow(5, placement: .floating, workspace: home)
		state.records[5]!.floatingFrame = RelativeFrame(monitor: main, offset: CGPoint(x: 100, y: 50), size: CGSize(width: 500, height: 300))
		state.records[5]!.pendingFloatRestore = true
		let cornered = CGRect(x: 1439, y: 899, width: 500, height: 300)
		let restored = CGRect(x: 100, y: 75, width: 500, height: 300)
		var plan = state.plan(snapshot: showing([5: cornered], at: 1), options: PlanOptions(), now: 1)
		expectEqual(plan.actions, [setFrame(5, restored, .floatRestore, observed: cornered)])
		expectEqual(state.records[5]?.pendingFloatRestore, false)
		state.recordWrites(landed(plan), now: 1.01)

		// A snapshot older than the write does not overwrite the floating frame.
		plan = state.plan(snapshot: showing([5: cornered], at: 1), options: PlanOptions(), now: 1.02)
		expect(plan.isEmpty)
		expectEqual(state.records[5]?.floatingFrame?.offset, CGPoint(x: 100, y: 50))

		let moved = CGRect(x: 400, y: 300, width: 520, height: 310)
		plan = state.plan(snapshot: showing([5: moved], at: 2), options: PlanOptions(), now: 2)
		expect(plan.isEmpty)
		expectEqual(state.records[5]?.floatingFrame, RelativeFrame(monitor: main, offset: CGPoint(x: 400, y: 275), size: moved.size))
		expectEqual(state.records[5]?.lastVisibleFrame, moved)
		expectEqual(state.expectedFrame(5), nil)
	},

	TestCase("a floating window shown again after a park is unparked to its floating frame") {
		var (state, active, other) = twoWorkspaces()
		state.testAddWindow(5, placement: .floating, workspace: other, visibility: inactive)
		state.records[5]!.floatingFrame = RelativeFrame(monitor: main, offset: CGPoint(x: 100, y: 50), size: CGSize(width: 500, height: 300))
		let cornered = CGRect(x: 1439, y: 899, width: 500, height: 300)
		_ = state.plan(snapshot: showing([1: leftSlot, 2: rightSlot, 3: parkedThree, 5: cornered], pids: [3: 200], at: 1),
			options: PlanOptions(), now: 1)
		switchTo(other, from: active, &state)
		state.records[5]!.floatingFrame = RelativeFrame(monitor: main, offset: CGPoint(x: 100, y: 50), size: CGSize(width: 500, height: 300))
		state.records[5]!.pendingFloatRestore = true
		let plan = state.plan(snapshot: showing([1: leftSlot, 2: rightSlot, 3: parkedThree, 5: cornered], pids: [3: 200], at: 2),
			options: PlanOptions(isCommand: true, includeHidePhase: false), now: 2)
		expectEqual(plan.actions.first { $0.window == 5 },
			setFrame(5, CGRect(x: 100, y: 75, width: 500, height: 300), .unpark(from: inactive), observed: cornered))
	},
]

// MARK: - Hide command

private let minimizeTests: [TestCase] = [
	TestCase("a hidden window is minimized once and unminimized after it leaves the hide stack") {
		var state = testState()
		let home = state.testActive()
		state.testSetColumns(home, [[1]])
		state.testAddWindow(2, workspace: home, visibility: .axisMinimized)
		state.hiddenStack = [HiddenEntry(window: 2)]
		let minimize = PlanAction(window: 2, pid: 100, kind: .minimize, reason: .hide, label: "App/W2#2")
		var plan = state.plan(snapshot: showing([1: fullSlot, 2: rightSlot], at: 1), options: PlanOptions(), now: 1)
		expectEqual(plan.hide, [PlanGroup(pid: 100, actions: [minimize])])
		state.recordWrites(landed(plan), now: 1.01)
		plan = state.plan(snapshot: showing([1: fullSlot, 2: rightSlot], at: 1.5), options: PlanOptions(), now: 1.5)
		expect(plan.isEmpty, "not asked again while the minimize is under way")

		state.records[2]!.observed.isMinimized = true
		plan = state.plan(snapshot: showing([1: fullSlot], at: 2), options: PlanOptions(), now: 2)
		expect(plan.isEmpty)

		// The unhide command takes it off the stack; it shows as minimized until it is seen again.
		state.hiddenStack = []
		state.testAddWindow(2, workspace: home, visibility: .nativeMinimized)
		state.records[2]!.observed.isMinimized = true
		plan = state.plan(snapshot: showing([1: fullSlot], at: 3), options: PlanOptions(isCommand: true), now: 3)
		expectEqual(plan.show, [PlanGroup(pid: 100, actions: [
			PlanAction(window: 2, pid: 100, kind: .unminimize, reason: .restore, label: "App/W2#2"),
		])])
		plan = state.plan(snapshot: showing([1: fullSlot], at: 3.5), options: PlanOptions(), now: 3.5)
		expect(plan.isEmpty, "once only")
	},

	TestCase("a window restored from the Dock needs no unminimize") {
		var state = testState()
		let home = state.testActive()
		state.testSetColumns(home, [[1]])
		state.testAddWindow(2, workspace: home, visibility: .axisMinimized)
		state.hiddenStack = [HiddenEntry(window: 2)]
		var plan = state.plan(snapshot: showing([1: fullSlot, 2: rightSlot], at: 1), options: PlanOptions(), now: 1)
		state.recordWrites(landed(plan), now: 1.01)
		state.hiddenStack = []
		state.testAddWindow(2, workspace: home)
		state.testSetColumns(home, [[1], [2]])
		plan = state.plan(snapshot: showing([1: fullSlot, 2: rightSlot], at: 2), options: PlanOptions(), now: 2)
		expectEqual(plan.actions, [setFrame(1, leftSlot, .layout, observed: fullSlot)])
		expectEqual(state.plannerState.minimized, [])
	},

	TestCase("a minimize that does not take is asked again and given up after three tries") {
		var state = testState()
		let home = state.testActive()
		state.testAddWindow(2, workspace: home, visibility: .axisMinimized)
		state.hiddenStack = [HiddenEntry(window: 2)]
		var writes = 0
		for time in [1.0, 2.1, 3.2, 4.3, 5.4] {
			let plan = state.plan(snapshot: showing([2: rightSlot], at: time), options: PlanOptions(), now: time)
			writes += plan.actions.count
			state.recordWrites(landed(plan), now: time + 0.01)
		}
		expectEqual(writes, 3)
		expectEqual(state.drainLog(), [TrackingLog("enforce: giving up on App/W2#2 for 30s (3 fights)")])
		expectEqual(state.ledger[2]?.gaveUpUntil ?? 0, 34.3, accuracy: 1e-9)
	},
]

// MARK: - Layout state

private let layoutStateTests: [TestCase] = [
	TestCase("the layout stores normalized ratios and keeps them while nothing is drawable") {
		var state = testState()
		let home = state.testActive()
		state.testSetColumns(home, [[1], [2]])
		state.workspaces[home]!.widthRatios = [0.5, 0.3, 0.2]
		state.workspaces[home]!.rowRatios = [0: [0.5, 0.5]]
		_ = state.plan(snapshot: showing([1: leftSlot, 2: rightSlot], at: 1), options: PlanOptions(), now: 1)
		expectEqual(state.workspaces[home]?.widthRatios, nil)
		expectEqual(state.workspaces[home]?.rowRatios, [:])

		state.workspaces[home]!.widthRatios = [0.6, 0.4]
		let plan = state.plan(snapshot: showing([1: leftSlot, 2: rightSlot], at: 2), options: PlanOptions(), now: 2)
		let frames = plan.actions.map { action -> CGRect in
			if case .setFrame(let frame) = action.kind { return frame }
			return .null
		}
		expectEqual(frames.count, 2)
		expectEqual(frames.first ?? .null, CGRect(x: 12, y: 37, width: 842.4, height: 851), accuracy: 0.001)
		expectEqual(frames.last ?? .null, CGRect(x: 866.4, y: 37, width: 561.6, height: 851), accuracy: 0.001)

		// Every window on another Space (a fullscreen trip): nothing to lay out, ratios kept.
		state.testAddWindow(1, workspace: home, visibility: .otherSpace)
		state.testAddWindow(2, workspace: home, visibility: .otherSpace)
		expect(state.plan(snapshot: showing([:], at: 3), options: PlanOptions(), now: 3).isEmpty)
		expectEqual(state.workspaces[home]?.widthRatios, [0.6, 0.4])
		expectInvariants(state)
	},

	TestCase("the reservation's phantom slot moves the active workspace's windows aside") {
		var state = testState()
		state.testSetColumns(state.testActive(), [[1], [2]])
		state.reservation = PlacementReservation(kind: .newColumnRight, monitor: main, columnIndex: 0)
		let plan = state.plan(snapshot: showing([1: leftSlot, 2: rightSlot], at: 1), options: PlanOptions(isCommand: true), now: 1)
		expectEqual(plan.actions, [
			setFrame(1, CGRect(x: 12, y: 37, width: 464, height: 851), .layout, observed: leftSlot),
			setFrame(2, CGRect(x: 964, y: 37, width: 464, height: 851), .layout, observed: rightSlot),
		])
		expectEqual(state.reservedSlot, CGRect(x: 488, y: 37, width: 464, height: 851))

		state.reservation = nil
		_ = state.plan(snapshot: showing([1: leftSlot, 2: rightSlot], at: 2), options: PlanOptions(), now: 2)
		expectEqual(state.reservedSlot, nil)
	},

	TestCase("a window opened into the reservation takes the slot its preview showed") {
		var state = testState()
		state.testSetColumns(state.testActive(), [[1], [2]])
		state.reservation = PlacementReservation(kind: .aboveInColumn, monitor: main, columnIndex: 1)
		var plan = state.plan(snapshot: showing([1: leftSlot, 2: rightSlot], at: 1), options: PlanOptions(isCommand: true), now: 1)
		let lowerRight = CGRect(x: 726, y: 468.5, width: 702, height: 419.5)
		expectEqual(plan.actions, [setFrame(2, lowerRight, .layout, observed: rightSlot)])
		state.recordWrites(landed(plan), now: 1.01)
		let preview = CGRect(x: 726, y: 37, width: 702, height: 419.5)
		expectEqual(state.reservedSlot, preview)

		// Later passes keep the slot free until a window takes it.
		plan = state.plan(snapshot: showing([1: leftSlot, 2: lowerRight], at: 1.5), options: PlanOptions(), now: 1.5)
		expect(plan.isEmpty, "\(plan)")
		expectEqual(state.reservedSlot, preview)

		let opened = CGRect(x: 300, y: 200, width: 800, height: 600)
		state.admit(WindowFacts(id: 3, pid: 100, title: "W3", frame: opened, takenAt: 2),
			app: AppFacts(pid: 100, bundleID: "com.test.app", name: "App"), source: .created, now: 2)
		expectEqual(state.reservation, nil)
		state.normalize(now: 2)
		plan = state.plan(snapshot: showing([1: leftSlot, 2: lowerRight, 3: opened], at: 2), options: PlanOptions(), now: 2)
		expectEqual(plan.actions, [setFrame(3, preview, .layout, observed: opened)])
		expectEqual(state.reservedSlot, nil)
		expectInvariants(state)
	},
]

// MARK: - Quit

private let quitTests: [TestCase] = [
	TestCase("the quit plan puts hidden windows into their slots or floating frames and leaves the rest") {
		var (state, active, other) = twoWorkspaces()
		state.testAddWindow(2, workspace: active, visibility: .zenHidden)
		state.zen = ZenSession(monitor: main, workspace: active, focus: 1)
		state.testAddWindow(4, placement: .floating, workspace: other, visibility: inactive, pid: 300, app: "Float")
		state.records[4]!.floatingFrame = RelativeFrame(monitor: main, offset: CGPoint(x: 40, y: 60), size: CGSize(width: 300, height: 200))
		state.testAddWindow(6, workspace: active, visibility: .axisMinimized)
		state.hiddenStack = [HiddenEntry(window: 6, minimizeConfirmed: true)]
		state.testAddWindow(7, placement: .floating, workspace: active, frame: CGRect(x: 5, y: 30, width: 200, height: 100))
		expectInvariants(state)

		let plan = state.quitPlan()
		expectEqual(plan.hide, [])
		expectEqual(plan.show, [
			PlanGroup(pid: 100, actions: [
				setFrame(1, leftSlot, .layout, observed: nil),
				setFrame(2, rightSlot, .unpark(from: .zenHidden), observed: nil),
			]),
			PlanGroup(pid: 200, actions: [setFrame(3, fullSlot, .unpark(from: inactive), observed: nil, pid: 200, label: "Other/W3#3")]),
			PlanGroup(pid: 300, actions: [
				setFrame(4, CGRect(x: 40, y: 85, width: 300, height: 200), .unpark(from: inactive), observed: nil, pid: 300,
					label: "Float/W4#4"),
			]),
		])
	},
]

// MARK: - Bookkeeping

private let bookkeepingTests: [TestCase] = [
	TestCase("retiring a window drops the planner's bookkeeping for it") {
		var (state, _, _) = twoWorkspaces()
		_ = state.plan(snapshot: settled(at: 1), options: PlanOptions(), now: 1)
		let plan = state.plan(snapshot: showing([1: leftSlot, 2: rightSlot, 3: shownThree], pids: [3: 200], at: 2),
			options: PlanOptions(), now: 2)
		state.recordWrites(landed(plan), now: 2.01)
		expect(state.ledger[3] != nil)
		state.retire(3, reason: .destroyed, now: 3)
		expectEqual(state.expectedFrame(3), nil)
		expectEqual(state.plannerState.parked[3], nil)
		expectEqual(state.ledger[3], nil)
		expectInvariants(state)
	},
]

private let visibleFrameTests: [TestCase] = [
	TestCase("shown windows take their frames from the window server without a plan") {
		var (state, _, _) = twoWorkspaces()
		let home = state.testActive()
		state.testAddWindow(5, placement: .floating, workspace: home)
		state.records[5]!.floatingFrame = RelativeFrame(monitor: main, offset: CGPoint(x: 100, y: 50), size: CGSize(width: 500, height: 300))
		state.testAddWindow(6, placement: .floating, workspace: home)
		let pending = RelativeFrame(monitor: main, offset: CGPoint(x: 10, y: 10), size: CGSize(width: 500, height: 300))
		state.records[6]!.floatingFrame = pending
		state.records[6]!.pendingFloatRestore = true
		let moved = CGRect(x: 400, y: 300, width: 520, height: 310)
		state.noteVisibleFrames(snapshot: showing([1: leftSlot, 2: rightSlot, 3: parkedThree, 5: moved, 6: moved],
			pids: [3: 200], at: 1))
		expectEqual(state.records[5]?.floatingFrame, RelativeFrame(monitor: main, offset: CGPoint(x: 400, y: 275), size: moved.size))
		expectEqual(state.records[5]?.lastVisibleFrame, moved)
		expectEqual(state.records[1]?.lastVisibleFrame, leftSlot)
		// A parked window and one about to move to its floating frame keep what they have.
		expectEqual(state.records[3]?.lastVisibleFrame, nil)
		expectEqual(state.records[6]?.floatingFrame, pending)
		expectEqual(state.records[6]?.lastVisibleFrame, nil)
		expectInvariants(state)
	},
]
