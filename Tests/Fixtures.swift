//
//  Fixtures.swift
//  Axis core tests
//
//  Builders for core states shared by the suites: displays, monitors with workspace rows, and
//  window records placed directly (without admission); assertions for invariants and ratios; and
//  a seeded random generator for randomized checks.
//

import Foundation
import CoreGraphics

/// The monitor key of a test display name.
func testKey(_ name: String) -> MonitorKey {
	MonitorKey(raw: "uuid-\(name)")
}

/// A display whose visible area leaves a menu bar at the top and an optional Dock at the bottom.
/// Frames are global and top-left based, like everything in the core.
func testDisplay(
	_ name: String, x: CGFloat = 0, y: CGFloat = 0, width: CGFloat = 1440, height: CGFloat = 900,
	menuBar: CGFloat = 25, dock: CGFloat = 0, primary: Bool = false, displayID: UInt32 = 1
) -> DisplayFacts {
	DisplayFacts(
		key: testKey(name), displayID: displayID, name: name,
		frame: CGRect(x: x, y: y, width: width, height: height),
		visibleFrame: CGRect(x: x, y: y + menuBar, width: width, height: height - menuBar - dock),
		isPrimary: primary)
}

/// A state with the displays connected in order, each with one empty home workspace, no barrier.
func testState(_ displays: [DisplayFacts] = [testDisplay("Main", primary: true)]) -> TrackingState {
	var state = TrackingState()
	for display in displays {
		state.addMonitor(display)
	}
	return state
}

/// Fails once per broken invariant.
func expectInvariants(_ state: TrackingState, _ context: String = "", file: StaticString = #filePath, line: UInt = #line) {
	for problem in state.checkInvariants() {
		fail(context.isEmpty ? "invariant: \(problem)" : "invariant (\(context)): \(problem)", file: file, line: line)
	}
}

extension TrackingState {
	/// The active workspace of a test display.
	func testActive(_ name: String = "Main") -> WorkspaceID {
		monitors[testKey(name)]!.active
	}

	/// A test display's workspace row, left to right.
	func testRow(_ name: String = "Main") -> [WorkspaceID] {
		monitors[testKey(name)]!.order
	}

	/// The numbers of a test display's workspaces, left to right.
	func testNumbers(_ name: String = "Main") -> [Int] {
		testRow(name).map { number(of: $0)! }
	}

	/// Replaces a test display's row with `negatives` negative and `nonNegatives` non-negative
	/// empty workspaces (the old ones are removed) and makes workspace number `active` active.
	@discardableResult
	mutating func testSetRow(_ name: String = "Main", negatives: Int = 0, nonNegatives: Int, active: Int = 0) -> [WorkspaceID] {
		let key = testKey(name)
		for workspace in monitors[key]!.order {
			workspaces[workspace] = nil
		}
		var order: [WorkspaceID] = []
		for index in 0..<(negatives + nonNegatives) {
			let id = makeWorkspaceID()
			workspaces[id] = Workspace(id: id, host: key, side: index < negatives ? .negative : .nonNegative)
			order.append(id)
		}
		monitors[key]!.order = order
		monitors[key]!.negativeCount = negatives
		monitors[key]!.active = order[negatives + active]
		return order
	}

	/// Adds (or replaces) a record placed directly, bypassing admission. Tiled records are not
	/// put into columns here; use `testSetColumns`.
	mutating func testAddWindow(
		_ id: WindowID, placement: Placement = .tiled, workspace: WorkspaceID?, visibility: Visibility = .visible,
		pid: PID = 100, app: String = "App", title: String? = nil, frame: CGRect? = nil, ghost: Bool = false
	) {
		records[id] = WindowRecord(
			id: id, pid: pid, appName: app, title: title ?? "W\(id)",
			placement: placement, workspace: placement == .unmanaged ? nil : workspace, visibility: visibility,
			observed: Observed(frame: frame, isServerGhost: ghost))
	}

	/// Replaces the columns of `workspace`, adding a tiled member (visible unless listed) for every
	/// id not tracked yet. `ghosts` are window-server ghosts.
	mutating func testSetColumns(
		_ workspace: WorkspaceID, _ columns: [[WindowID]],
		visibility: [WindowID: Visibility] = [:], ghosts: Set<WindowID> = []
	) {
		for id in columns.joined() where records[id] == nil {
			testAddWindow(id, workspace: workspace, visibility: visibility[id] ?? .visible, ghost: ghosts.contains(id))
		}
		workspaces[workspace]!.columns = columns
	}

	/// The stored columns of a workspace.
	func testColumns(_ workspace: WorkspaceID) -> [[WindowID]] {
		workspaces[workspace]?.columns ?? []
	}
}

/// Fails unless the ratios match within 0.0001.
func expectRatios(_ actual: [CGFloat]?, _ expected: [CGFloat], _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
	guard let actual, actual.count == expected.count else {
		fail("ratios \(String(describing: actual)), expected \(expected) \(message)", file: file, line: line)
		return
	}
	for (value, target) in zip(actual, expected) where abs(value - target) > 0.0001 {
		fail("ratios \(actual), expected \(expected) \(message)", file: file, line: line)
		return
	}
}

/// SplitMix64: a small seeded generator, so randomized tests check the same cases on every run.
struct SeededGenerator: RandomNumberGenerator {
	private var state: UInt64

	init(seed: UInt64) {
		state = seed
	}

	mutating func next() -> UInt64 {
		state &+= 0x9E37_79B9_7F4A_7C15
		var value = state
		value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
		value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
		return value ^ (value >> 31)
	}
}
