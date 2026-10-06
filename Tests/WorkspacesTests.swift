//
//  WorkspacesTests.swift
//  Axis core tests
//
//  Workspace order, numbering, compaction, column operations and size ratios.
//

import Foundation
import CoreGraphics

private let main = testKey("Main")

let workspacesTests: [TestCase] = numberingTests + compactionTests + columnOperationTests
	+ drawableViewTests + insertionTests + membershipTests + ratioTests + retireTests
	+ invariantTests + helperTests

// MARK: - Numbering, next and previous

private let numberingTests: [TestCase] = [
	TestCase("numbers count from the home workspace with negatives on the left") {
		var state = testState()
		let row = state.testSetRow(negatives: 2, nonNegatives: 3, active: 1)
		expectEqual(state.testNumbers(), [-2, -1, 0, 1, 2])
		for (index, workspace) in row.enumerated() {
			expectEqual(state.workspace(number: index - 2, on: main), workspace)
		}
		expectEqual(state.workspace(number: 3, on: main), nil)
		expectEqual(state.workspace(number: -3, on: main), nil)
		expectEqual(state.describeWorkspace(row[2]), "ws1[\(row[2])]")
		expectEqual(state.describeWorkspace(row[0]), "ws-1[\(row[0])]")
		expectEqual(state.activeWorkspace(main), row[3])
		expectInvariants(state)
	},

	TestCase("next past the right end creates a non-negative workspace") {
		var state = testState()
		let home = state.testActive()
		state.testSetColumns(home, [[1]])
		let next = state.switchWorkspace(on: main, to: .next)
		expectEqual(state.testRow(), [home, next!])
		expectEqual(state.workspaces[next!]?.side, .nonNegative)
		expectEqual(state.number(of: next!), 1)
		expectEqual(state.testActive(), next!)
		expectEqual(state.events, [.activeChanged(monitor: main, from: home, to: next!, cause: .command)])
		expectInvariants(state)
	},

	TestCase("previous past the left end creates a negative workspace") {
		var state = testState()
		let home = state.testActive()
		state.testSetColumns(home, [[1]])
		let previous = state.switchWorkspace(on: main, to: .prev)!
		expectEqual(state.testRow(), [previous, home])
		expectEqual(state.monitors[main]?.negativeCount, 1)
		expectEqual(state.number(of: previous), -1)
		expectEqual(state.workspaces[previous]?.side, .negative)
		// Going further left from an empty negative workspace replaces it.
		let further = state.switchWorkspace(on: main, to: .prev)!
		expectEqual(state.testRow(), [further, home])
		expectEqual(state.number(of: further), -1)
		expectEqual(state.workspaces[previous], nil)
		expectInvariants(state)
	},

	TestCase("next and previous step through existing workspaces without creating any") {
		var state = testState()
		let row = state.testSetRow(negatives: 1, nonNegatives: 2, active: 0)
		state.testSetColumns(row[0], [[1]])
		state.testSetColumns(row[1], [[2]])
		state.testSetColumns(row[2], [[3]])
		expectEqual(state.switchWorkspace(on: main, to: .next), row[2])
		expectEqual(state.switchWorkspace(on: main, to: .prev), row[1])
		expectEqual(state.switchWorkspace(on: main, to: .prev), row[0])
		expectEqual(state.testRow(), row)
		expectEqual(state.switchWorkspace(on: main, to: .number(1)), row[2])
		expectEqual(state.switchWorkspace(on: main, to: .id(row[1])), row[1])
		expectInvariants(state)
	},

	TestCase("switching to the active workspace or to a missing one changes nothing") {
		var state = testState()
		let home = state.testActive()
		state.testSetColumns(home, [[1]])
		let before = state
		expectEqual(state.switchWorkspace(on: main, to: .id(home)), nil)
		expectEqual(state.switchWorkspace(on: main, to: .number(4)), nil)
		expectEqual(state.switchWorkspace(on: main, to: .id(WorkspaceID(raw: 99))), nil)
		expectEqual(state.switchWorkspace(on: testKey("Nowhere"), to: .next), nil)
		expectEqual(state, before)
	},

	TestCase("switching away from an empty workspace drops it") {
		var state = testState()
		let row = state.testSetRow(nonNegatives: 2, active: 1)
		state.testSetColumns(row[0], [[1]])
		expectEqual(state.switchWorkspace(on: main, to: .prev), row[0])
		expectEqual(state.testRow(), [row[0]])
		expectEqual(state.workspaces[row[1]], nil)
		expect(state.log.contains { $0.message.hasPrefix("workspace: dropped empty ws2[\(row[1])] on Main") },
			"compaction log line: \(state.log)")
		expectInvariants(state)
	},

	TestCase("switching ends Zen only on its own monitor") {
		var state = testState([testDisplay("Main", primary: true), testDisplay("Right", x: 1440, displayID: 2)])
		let home = state.testActive()
		state.testSetColumns(home, [[1]])
		state.testSetColumns(state.testActive("Right"), [[2]])
		state.zen = ZenSession(monitor: main, workspace: home, focus: 1)
		state.switchWorkspace(on: testKey("Right"), to: .next)
		expect(state.zen != nil, "a switch on another monitor keeps Zen")
		state.switchWorkspace(on: main, to: .next)
		expectEqual(state.zen, nil)
		expect(state.events.contains(.zenEnded(.workspaceSwitched)))
		expectInvariants(state)
	},
]

// MARK: - Compaction

private let compactionTests: [TestCase] = [
	TestCase("compaction keeps an empty active workspace only when asked") {
		var state = testState()
		let row = state.testSetRow(nonNegatives: 3, active: 1)
		state.testSetColumns(row[0], [[1]])
		state.testSetColumns(row[2], [[2]])
		var keeping = state
		keeping.compact(main, keepingActive: true)
		expectEqual(keeping.testRow(), row)
		expectEqual(keeping.events, [])
		state.compact(main, keepingActive: false)
		expectEqual(state.testRow(), [row[0], row[2]])
		expectEqual(state.testActive(), row[2])
		expectEqual(state.events, [.activeChanged(monitor: main, from: row[1], to: row[2], cause: .compaction)])
		expectInvariants(state)
	},

	TestCase("a deleted active negative workspace hands over to its outer neighbour") {
		var state = testState()
		let row = state.testSetRow(negatives: 2, nonNegatives: 1, active: -1)
		state.testSetColumns(row[0], [[1]])
		state.testSetColumns(row[2], [[2]])
		state.compact(main, keepingActive: false)
		expectEqual(state.testRow(), [row[0], row[2]])
		expectEqual(state.testActive(), row[0])
		expectEqual(state.number(of: row[0]), -1)
		expectInvariants(state)
	},

	TestCase("without an outer neighbour the inner one takes over") {
		var state = testState()
		var row = state.testSetRow(nonNegatives: 2, active: 1)
		state.testSetColumns(row[0], [[1]])
		state.compact(main, keepingActive: false)
		expectEqual(state.testActive(), row[0], "last non-negative -> its left neighbour")

		state = testState()
		row = state.testSetRow(negatives: 1, nonNegatives: 1, active: -1)
		state.testSetColumns(row[1], [[1]])
		state.compact(main, keepingActive: false)
		expectEqual(state.testActive(), row[1], "only negative -> home")
		expectEqual(state.monitors[main]?.negativeCount, 0)

		state = testState()
		row = state.testSetRow(negatives: 2, nonNegatives: 1, active: -2)
		state.testSetColumns(row[1], [[1]])
		state.testSetColumns(row[2], [[2]])
		state.compact(main, keepingActive: false)
		expectEqual(state.testActive(), row[1], "outermost negative -> the next one in")
		expectInvariants(state)
	},

	TestCase("negative workspaces compact toward minus one") {
		var state = testState()
		let row = state.testSetRow(negatives: 3, nonNegatives: 1, active: 0)
		state.testSetColumns(row[0], [[1]])
		state.testSetColumns(row[3], [[2]])
		state.compact(main, keepingActive: false)
		expectEqual(state.testRow(), [row[0], row[3]])
		expectEqual(state.number(of: row[0]), -1)
		expectEqual(state.monitors[main]?.negativeCount, 1)
		expectEqual(state.events, [])
		expectInvariants(state)
	},

	TestCase("the home workspace stays when no non-negative workspace has members") {
		var state = testState()
		let row = state.testSetRow(negatives: 1, nonNegatives: 2, active: -1)
		state.testSetColumns(row[0], [[1]])
		state.compact(main, keepingActive: false)
		expectEqual(state.testRow(), [row[0], row[1]])

		var empty = testState()
		let emptyRow = empty.testSetRow(nonNegatives: 2, active: 1)
		var keeping = empty
		keeping.compact(main, keepingActive: true)
		expectEqual(keeping.testRow(), emptyRow)
		empty.compact(main, keepingActive: false)
		expectEqual(empty.testRow(), [emptyRow[0]])
		expectEqual(empty.testActive(), emptyRow[0])
		expectInvariants(state)
		expectInvariants(empty)
	},

	TestCase("workspace ids survive compaction while numbers shift") {
		var state = testState()
		let row = state.testSetRow(negatives: 1, nonNegatives: 3, active: 2)
		state.testSetColumns(row[1], [[1]])
		state.testSetColumns(row[3], [[2]])
		state.testAddWindow(3, placement: .floating, workspace: row[3])
		state.compact(main, keepingActive: false)
		expectEqual(state.testRow(), [row[1], row[3]])
		expectEqual(state.number(of: row[3]), 1)
		expectEqual(state.testActive(), row[3])
		expectEqual(state.records[2]?.workspace, row[3])
		expectEqual(state.records[3]?.workspace, row[3])
		expectEqual(state.workspaces[row[0]], nil)
		expectEqual(state.workspaces[row[2]], nil)
		expectInvariants(state)
	},

	TestCase("floating and minimized members keep a workspace from being dropped") {
		var state = testState()
		let row = state.testSetRow(nonNegatives: 3, active: 0)
		state.testSetColumns(row[0], [[1]])
		state.testAddWindow(2, placement: .floating, workspace: row[1])
		state.testAddWindow(3, workspace: row[2], visibility: .nativeMinimized)
		state.compact(main, keepingActive: false)
		expectEqual(state.testRow(), row)
		expectInvariants(state)
	},

	TestCase("compaction keeps the Zen workspace") {
		var state = testState()
		let row = state.testSetRow(nonNegatives: 2, active: 1)
		state.testSetColumns(row[0], [[1]])
		state.testAddWindow(9, placement: .unmanaged, workspace: nil)
		state.zen = ZenSession(monitor: main, workspace: row[1], focus: 9)
		state.compact(main, keepingActive: false)
		expectEqual(state.testRow(), row)
		expectInvariants(state)
	},

	TestCase("a new workspace at the end reuses a trailing empty one") {
		var state = testState()
		var row = state.testSetRow(nonNegatives: 2, active: 0)
		state.testSetColumns(row[0], [[1]])
		expectEqual(state.createWorkspaceAtEnd(on: main), row[1])

		state = testState()
		row = state.testSetRow(nonNegatives: 1)
		state.testSetColumns(row[0], [[1]])
		let created = state.createWorkspaceAtEnd(on: main)!
		expectEqual(state.testRow(), [row[0], created])
		expectEqual(state.workspaces[created]?.side, .nonNegative)

		state = testState()
		row = state.testSetRow(negatives: 1, nonNegatives: 1, active: -1)
		state.testSetColumns(row[0], [[1]])
		expectEqual(state.createWorkspaceAtEnd(on: main), row[1], "an empty home past an in-use negative is reused")

		state = testState()
		row = state.testSetRow(nonNegatives: 2, active: 1)
		expectEqual(state.createWorkspaceAtEnd(on: main), state.testRow().last, "the active one counts as in use")
		expectEqual(state.testRow().count, 3)
		expectInvariants(state)
	},
]

// MARK: - Column operations

private let columnOperationTests: [TestCase] = [
	TestCase("moving a window left or right swaps whole columns and their ratios") {
		var state = testState()
		let home = state.testActive()
		state.testSetColumns(home, [[1], [2, 3], [4]])
		state.workspaces[home]!.widthRatios = [0.2, 0.5, 0.3]
		state.workspaces[home]!.rowRatios = [1: [0.4, 0.6]]
		expectEqual(state.moveWindow(3, .left), .moved)
		expectEqual(state.testColumns(home), [[2, 3], [1], [4]])
		expectEqual(state.workspaces[home]?.widthRatios, [0.5, 0.2, 0.3])
		expectEqual(state.workspaces[home]?.rowRatios, [0: [0.4, 0.6]])
		expectEqual(state.moveWindow(1, .right), .moved)
		expectEqual(state.testColumns(home), [[2, 3], [4], [1]])
		expectEqual(state.workspaces[home]?.widthRatios, [0.5, 0.3, 0.2])

		state.workspaces[home]!.widthRatios = [0.5, 0.5]
		state.moveWindow(4, .right)
		expectEqual(state.testColumns(home), [[2, 3], [1], [4]])
		expectEqual(state.workspaces[home]?.widthRatios, [0.5, 0.5], "stale ratios are left alone")
		expectInvariants(state)
	},

	TestCase("moving a window up or down swaps it in its column with its row ratio") {
		var state = testState()
		let home = state.testActive()
		state.testSetColumns(home, [[1, 2, 3], [4]])
		state.workspaces[home]!.rowRatios = [0: [0.2, 0.3, 0.5]]
		expectEqual(state.moveWindow(3, .up), .moved)
		expectEqual(state.testColumns(home), [[1, 3, 2], [4]])
		expectEqual(state.workspaces[home]?.rowRatios[0], [0.2, 0.5, 0.3])
		expectEqual(state.moveWindow(1, .down), .moved)
		expectEqual(state.testColumns(home), [[3, 1, 2], [4]])
		state.workspaces[home]!.rowRatios = [0: [0.5, 0.5]]
		state.moveWindow(1, .down)
		expectEqual(state.testColumns(home), [[3, 2, 1], [4]])
		expectEqual(state.workspaces[home]?.rowRatios[0], [0.5, 0.5], "stale row ratios are left alone")
		expectEqual(state.moveWindow(1, .down), .none, "bottom edge without a monitor below")
		expectEqual(state.moveWindow(99, .left), .none)
		expectInvariants(state)
	},

	TestCase("at the edge a window moves to the neighbouring monitor") {
		var state = testState([
			testDisplay("Main", primary: true),
			testDisplay("Right", x: 1440, width: 1920, height: 1080, displayID: 2),
			testDisplay("Top", y: -900, displayID: 3),
		])
		let right = testKey("Right")
		let top = testKey("Top")
		let home = state.testActive()
		let rightHome = state.testActive("Right")
		state.testSetColumns(home, [[1], [2]])
		state.testSetColumns(rightHome, [[5], [6]])
		expectEqual(state.moveWindow(2, .right), .movedToMonitor(right))
		expectEqual(state.testColumns(rightHome), [[2], [5], [6]])
		expectEqual(state.testColumns(home), [[1]])
		expectEqual(state.records[2]?.workspace, rightHome)
		expectEqual(state.moveWindow(2, .left), .movedToMonitor(main))
		expectEqual(state.testColumns(home), [[1], [2]], "moving left lands at the right end")
		expectEqual(state.moveWindow(1, .left), .none)
		expectEqual(state.moveWindow(1, .up), .movedToMonitor(top))
		expectEqual(state.testColumns(state.testActive("Top")), [[1]])
		expectEqual(state.adjacentMonitor(of: top, toward: .down), main)
		expectInvariants(state)
	},

	TestCase("moving the last window to another monitor keeps the workspace it left") {
		var state = testState([testDisplay("Main", primary: true), testDisplay("Right", x: 1440, displayID: 2)])
		let row = state.testSetRow(nonNegatives: 2, active: 1)
		state.testSetColumns(row[0], [[3]])
		state.testSetColumns(row[1], [[1]])
		expectEqual(state.moveWindow(1, .right), .movedToMonitor(testKey("Right")))
		expectEqual(state.testActive(), row[1])
		expectEqual(state.testRow(), row)
		expect(!state.events.contains { if case .activeChanged = $0 { return true } else { return false } })
		expectInvariants(state)
	},

	TestCase("a step move splits a window out of its column or merges it into the neighbour") {
		var state = testState()
		let home = state.testActive()
		state.testSetColumns(home, [[1, 2], [3]])
		expect(state.stepMove(2, .right))
		expectEqual(state.testColumns(home), [[1], [2], [3]])
		expect(state.stepMove(2, .right))
		expectEqual(state.testColumns(home), [[1], [3, 2]])
		expect(state.stepMove(2, .left))
		expectEqual(state.testColumns(home), [[1], [2], [3]])
		expect(state.stepMove(2, .left))
		expectEqual(state.testColumns(home), [[1, 2], [3]])
		expect(state.stepMove(1, .left))
		expectEqual(state.testColumns(home), [[1], [2], [3]])
		expect(!state.stepMove(1, .left), "alone at the left edge")
		expect(!state.stepMove(1, .up), "only left and right")
		expectInvariants(state)
	},

	TestCase("resetting the layout gives every window its own column and ends Zen") {
		var state = testState()
		let home = state.testActive()
		state.testSetColumns(home, [[1, 2], [3, 4]], visibility: [2: .zenHidden, 3: .zenHidden, 4: .zenHidden])
		state.zen = ZenSession(monitor: main, workspace: home, focus: 1)
		state.resetToSingleColumns(home)
		expectEqual(state.testColumns(home), [[1], [2], [3], [4]])
		expectEqual(state.zen, nil)
		expect(state.events.contains(.zenEnded(.layoutReset)))
	},

	TestCase("a reservation inserts the new window where its key pointed") {
		func inserted(_ kind: ReservationKind, _ index: Int, into columns: [[WindowID]]) -> [[WindowID]] {
			var state = testState()
			let home = state.testActive()
			state.testSetColumns(home, columns)
			state.testAddWindow(9, placement: kind == .float ? .floating : .tiled, workspace: home)
			state.insertReserved(9, kind: kind, columnIndex: index, into: home)
			expectInvariants(state, "\(kind) \(index)")
			return state.testColumns(home)
		}
		let base: [[WindowID]] = [[1, 2], [3]]
		expectEqual(inserted(.aboveInColumn, 1, into: base), [[1, 2], [9, 3]])
		expectEqual(inserted(.belowInColumn, 0, into: base), [[1, 2, 9], [3]])
		expectEqual(inserted(.newColumnLeft, 1, into: base), [[1, 2], [9], [3]])
		expectEqual(inserted(.newColumnRight, 1, into: base), [[1, 2], [3], [9]])
		expectEqual(inserted(.aboveInColumn, 7, into: base), [[1, 2], [9, 3]])
		expectEqual(inserted(.newColumnLeft, -3, into: base), [[9], [1, 2], [3]])
		expectEqual(inserted(.newColumnRight, 5, into: base), [[1, 2], [3], [9]])
		expectEqual(inserted(.belowInColumn, 0, into: []), [[9]])
		expectEqual(inserted(.float, 0, into: base), base)
	},

	TestCase("column operations match a reference model on random layouts") {
		var random = SeededGenerator(seed: 0x5EED_0001)
		for round in 0..<400 {
			let layout = randomLayout(&random)
			var state = testState()
			let home = state.testActive()
			state.testSetColumns(home, layout.columns)
			state.workspaces[home]!.widthRatios = layout.widthRatios
			state.workspaces[home]!.rowRatios = layout.rowRatios
			var reference = ReferenceTiling(columns: layout.columns, widthRatios: layout.widthRatios, rowRatios: layout.rowRatios)
			let op = randomOperation(&random, columns: layout.columns)
			apply(op, to: &state, workspace: home)
			reference.apply(op, visibleFrame: state.monitors[main]!.visibleFrame, config: state.config)
			let context = "round \(round): \(op) on \(layout.columns)"
			expectEqual(state.testColumns(home), reference.columns, context)
			expectEqual(state.workspaces[home]?.widthRatios, reference.widthRatios, context)
			expectEqual(state.workspaces[home]?.rowRatios, reference.rowRatios, context)
			expectInvariants(state, context)
		}
	},
]

// MARK: - Drawable view

private let drawableViewTests: [TestCase] = [
	TestCase("layout columns leave out other-Space windows and window-server ghosts") {
		var state = testState()
		let home = state.testActive()
		state.testSetColumns(home, [[1, 2], [3], [4, 5]],
			visibility: [2: .otherSpace, 4: .zenHidden, 5: .paletteHidden], ghosts: [3])
		state.workspaces[home]!.widthRatios = [0.7, 0.3]
		expectEqual(state.layoutColumns(home), [[1], [4, 5]])
		expectEqual(state.layoutInput(home), LayoutInput(columns: [[1], [4, 5]], widthRatios: [0.7, 0.3]))
		expect(!state.isDrawable(2))
		expect(!state.isDrawable(3))
		expect(state.isDrawable(4))
		expectInvariants(state)
	},

	TestCase("parked windows of an inactive workspace keep their slots") {
		var state = testState()
		let row = state.testSetRow(nonNegatives: 2, active: 0)
		state.testSetColumns(row[1], [[1], [2]], visibility: [1: .parked(.workspaceInactive), 2: .parked(.workspaceInactive)])
		expectEqual(state.layoutColumns(row[1]), [[1], [2]])
	},

	TestCase("merging an unchanged drawable view restores the columns exactly") {
		var random = SeededGenerator(seed: 0x5EED_0002)
		for round in 0..<500 {
			let columns = randomLayout(&random).columns
			let ids = Array(columns.joined())
			let drawable = Set(ids.filter { _ in Bool.random(using: &random) })
			let view = ColumnView.drawable(columns, keeping: drawable)
			expectEqual(ColumnView.merge(original: columns, edited: view, drawable: drawable), columns,
				"round \(round): drawable \(drawable.sorted())")
		}
	},

	TestCase("an invisible column never absorbs a move") {
		var state = testState()
		let home = state.testActive()
		state.testSetColumns(home, [[1], [7], [2]], visibility: [7: .otherSpace])
		expectEqual(state.moveWindow(1, .right), .moved)
		expectEqual(state.layoutColumns(home), [[2], [1]])
		expectEqual(state.testColumns(home), [[2], [1], [7]])

		state = testState()
		state.testSetColumns(home, [[1], [7], [2]], visibility: [7: .otherSpace])
		expect(state.stepMove(1, .right))
		expectEqual(state.layoutColumns(home), [[2, 1]])
		expectEqual(state.testColumns(home), [[2, 1], [7]])
		expectInvariants(state)
	},

	TestCase("a ghost in a column never absorbs a move and stays by its neighbour") {
		var state = testState()
		let home = state.testActive()
		state.testSetColumns(home, [[1, 8, 2], [3]], ghosts: [8])
		expectEqual(state.moveWindow(2, .up), .moved)
		expectEqual(state.layoutColumns(home), [[2, 1], [3]])
		expectEqual(state.testColumns(home), [[2, 1, 8], [3]])
		state.resetToSingleColumns(home)
		expectEqual(state.layoutColumns(home), [[2], [1], [3]])
		expectEqual(state.testColumns(home), [[2], [1, 8], [3]])
		expectInvariants(state)
	},

	TestCase("column operations act on the drawable view and keep hidden entries") {
		var random = SeededGenerator(seed: 0x5EED_0003)
		for round in 0..<400 {
			let layout = randomLayout(&random)
			var columns = layout.columns
			var hidden: [WindowID] = []
			var visibility: [WindowID: Visibility] = [:]
			var ghosts: Set<WindowID> = []
			for index in 0..<Int.random(in: 1...3, using: &random) {
				let id = WindowID(500 + index)
				hidden.append(id)
				if Bool.random(using: &random) {
					visibility[id] = .otherSpace
				} else {
					ghosts.insert(id)
				}
				if Bool.random(using: &random) {
					let column = Int.random(in: 0..<columns.count, using: &random)
					columns[column].insert(id, at: Int.random(in: 0...columns[column].count, using: &random))
				} else {
					columns.insert([id], at: Int.random(in: 0...columns.count, using: &random))
				}
			}
			var state = testState()
			let home = state.testActive()
			state.testSetColumns(home, columns, visibility: visibility, ghosts: ghosts)
			state.workspaces[home]!.widthRatios = layout.widthRatios
			state.workspaces[home]!.rowRatios = layout.rowRatios
			expectEqual(state.layoutColumns(home), layout.columns)
			var reference = ReferenceTiling(columns: layout.columns, widthRatios: layout.widthRatios, rowRatios: layout.rowRatios)
			let op = randomOperation(&random, columns: layout.columns)
			apply(op, to: &state, workspace: home)
			reference.apply(op, visibleFrame: state.monitors[main]!.visibleFrame, config: state.config)
			let context = "round \(round): \(op) on \(columns)"
			expectEqual(state.layoutColumns(home), reference.columns, context)
			expectEqual(state.workspaces[home]?.widthRatios, reference.widthRatios, context)
			expectEqual(state.workspaces[home]?.rowRatios, reference.rowRatios, context)
			let after = state.testColumns(home).joined()
			for id in hidden {
				expectEqual(after.filter { $0 == id }.count, 1, "\(context): #\(id) kept once")
			}
			expectInvariants(state, context)
		}
	},
]

// MARK: - Insertion and removal

private let insertionTests: [TestCase] = [
	TestCase("slot centres follow the ratios when they fit the column count") {
		let visibleFrame = CGRect(x: 0, y: 25, width: 1440, height: 875)
		let even = ColumnView.columnCentres(count: 3, widthRatios: nil, visibleFrame: visibleFrame, config: LayoutConfig())
		expectEqual(even.count, 3)
		for (actual, expected) in zip(even, [244.0, 720.0, 1196.0] as [CGFloat]) {
			expectEqual(actual, expected, accuracy: 0.001)
		}
		let ratios = ColumnView.columnCentres(count: 3, widthRatios: [0.5, 0.25, 0.25], visibleFrame: visibleFrame, config: LayoutConfig())
		for (actual, expected) in zip(ratios, [360.0, 894.0, 1254.0] as [CGFloat]) {
			expectEqual(actual, expected, accuracy: 0.001)
		}
		let stale = ColumnView.columnCentres(count: 3, widthRatios: [0.5, 0.5], visibleFrame: visibleFrame, config: LayoutConfig())
		expectEqual(stale, even)
	},

	TestCase("a new column goes before the first slot whose centre is right of the window") {
		func inserted(midX: CGFloat) -> [[WindowID]] {
			var state = testState()
			let home = state.testActive()
			state.testSetColumns(home, [[1], [2], [3]])
			state.testAddWindow(9, workspace: home)
			state.insertByMidX(9, midX: midX, into: home)
			expectInvariants(state)
			return state.testColumns(home)
		}
		expectEqual(inserted(midX: 100), [[9], [1], [2], [3]])
		expectEqual(inserted(midX: 500), [[1], [9], [2], [3]])
		expectEqual(inserted(midX: 800), [[1], [2], [9], [3]])
		expectEqual(inserted(midX: 1300), [[1], [2], [3], [9]])
	},

	TestCase("a window comes back next to the neighbours it remembers") {
		func inserted(_ memory: SlotMemory) -> (Bool, [[WindowID]]) {
			var state = testState()
			let home = state.testActive()
			state.testSetColumns(home, [[1, 2], [3]])
			state.testAddWindow(9, workspace: home)
			let done = state.insertBySlotMemory(9, memory: memory, into: home)
			return (done, state.testColumns(home))
		}
		let home = testState().testActive()
		var result = inserted(SlotMemory(above: 1, workspace: home))
		expect(result.0)
		expectEqual(result.1, [[1, 9, 2], [3]])
		result = inserted(SlotMemory(above: 99, below: 2, workspace: home))
		expectEqual(result.1, [[1, 9, 2], [3]])
		result = inserted(SlotMemory(above: 99, below: 98, leftRep: 1, rightRep: 3, workspace: home))
		expectEqual(result.1, [[1, 2], [9], [3]])
		result = inserted(SlotMemory(rightRep: 3, workspace: home))
		expectEqual(result.1, [[1, 2], [9], [3]])
		result = inserted(SlotMemory(above: 99, leftRep: 97, workspace: home))
		expect(!result.0)
		expectEqual(result.1, [[1, 2], [3]], "nothing changes without a surviving neighbour")
	},

	TestCase("removing a window from the columns reports its neighbours") {
		var state = testState()
		let home = state.testActive()
		state.testSetColumns(home, [[1, 2, 3], [4], [5]])
		expectEqual(state.removeFromColumns(2), SlotMemory(above: 1, below: 3, rightRep: 4, workspace: home))
		expectEqual(state.testColumns(home), [[1, 3], [4], [5]])
		expectEqual(state.removeFromColumns(4), SlotMemory(leftRep: 1, rightRep: 5, workspace: home))
		expectEqual(state.testColumns(home), [[1, 3], [5]])
		expectEqual(state.removeFromColumns(4), nil)
	},
]

// MARK: - Membership moves and float

private let membershipTests: [TestCase] = [
	TestCase("moving a window to the next workspace takes it along and switches there") {
		var state = testState()
		let home = state.testActive()
		state.testSetColumns(home, [[1], [2]])
		state.records[1]!.observed.frame = CGRect(x: 12, y: 37, width: 696, height: 851)
		state.records[2]!.observed.frame = CGRect(x: 720, y: 37, width: 696, height: 851)
		let next = state.moveWindowToWorkspace(2, on: main, to: .next)!
		expectEqual(state.records[2]?.workspace, next)
		expectEqual(state.testColumns(next), [[2]])
		expectEqual(state.testColumns(home), [[1]])
		expectEqual(state.testActive(), next)
		expectInvariants(state)

		expectEqual(state.moveWindowToWorkspace(2, on: main, to: .prev), home)
		expectEqual(state.testColumns(home), [[1], [2]], "placed by its centre")
		expectEqual(state.testRow(), [home], "the workspace it left was empty and is dropped")
		expectEqual(state.moveWindowToWorkspace(2, on: main, to: .id(home)), nil)
		expectInvariants(state)
	},

	TestCase("moving a floating or unmanaged window to a workspace keeps it out of the columns") {
		var state = testState()
		let home = state.testActive()
		state.testSetColumns(home, [[1]])
		state.testAddWindow(4, placement: .floating, workspace: home)
		state.testAddWindow(5, placement: .unmanaged, workspace: nil, frame: CGRect(x: 100, y: 100, width: 400, height: 300))
		let next = state.moveWindowToWorkspace(4, on: main, to: .next)!
		expectEqual(state.records[4]?.workspace, next)
		expectEqual(state.testColumns(next), [])
		expectEqual(state.moveWindowToWorkspace(5, on: main, to: .id(home)), home)
		expectEqual(state.records[5]?.placement, .floating)
		expectEqual(state.records[5]?.workspace, home)
		expectEqual(state.records[5]?.floatingFrame?.frame(in: state.monitors[main]!.visibleFrame),
			CGRect(x: 100, y: 100, width: 400, height: 300))
		expectInvariants(state)
	},

	TestCase("toggling float takes a tiled window out of the columns and back by its centre") {
		var state = testState()
		let home = state.testActive()
		state.testSetColumns(home, [[1], [2]])
		state.records[2]!.observed.frame = CGRect(x: 732, y: 37, width: 696, height: 851)
		expectEqual(state.toggleFloat(2), .floating)
		expectEqual(state.testColumns(home), [[1]])
		expect(state.records[2]?.pendingFloatRestore == true)
		expectEqual(state.records[2]?.floatingFrame?.frame(in: state.monitors[main]!.visibleFrame),
			CGRect(x: 372, y: 37, width: 696, height: 851))
		expectInvariants(state)
		expectEqual(state.toggleFloat(2), .tiled)
		expectEqual(state.testColumns(home), [[1], [2]])
		expectInvariants(state)
	},

	TestCase("toggling float on an unmanaged window only centres it") {
		var state = testState()
		state.testAddWindow(5, placement: .unmanaged, workspace: nil, frame: CGRect(x: 100, y: 100, width: 400, height: 300))
		expectEqual(state.toggleFloat(5), .unmanaged)
		expectEqual(state.records[5]?.workspace, nil)
		expectEqual(state.records[5]?.floatingFrame,
			RelativeFrame(monitor: main, offset: CGPoint(x: 520, y: 287.5), size: CGSize(width: 400, height: 300)))
		expect(state.records[5]?.pendingFloatRestore == true)
		expectEqual(state.toggleFloat(99), nil)
		expectInvariants(state)
	},

	TestCase("moving a floating window to another monitor keeps its offset there") {
		var state = testState([testDisplay("Main", primary: true), testDisplay("Right", x: 1440, displayID: 2)])
		let right = testKey("Right")
		state.testAddWindow(4, placement: .floating, workspace: state.testActive())
		state.records[4]!.floatingFrame = RelativeFrame(monitor: main, offset: CGPoint(x: 50, y: 60), size: CGSize(width: 300, height: 200))
		expect(state.moveWindowToMonitor(4, to: right, edge: .left))
		expectEqual(state.records[4]?.workspace, state.testActive("Right"))
		expectEqual(state.records[4]?.floatingFrame,
			RelativeFrame(monitor: right, offset: CGPoint(x: 50, y: 60), size: CGSize(width: 300, height: 200)))
		expect(state.records[4]?.pendingFloatRestore == true)
		expect(!state.moveWindowToMonitor(4, to: right, edge: .left), "already there")
		expectInvariants(state)
	},
]

// MARK: - Size ratios

private let ratioTests: [TestCase] = [
	TestCase("dragging a column boundary shifts width between the two columns") {
		var state = testState()
		let home = state.testActive()
		state.testSetColumns(home, [[1], [2]])
		// 1440 wide: 1440 - 2 * 12 padding - 12 gap = 1404 pt to share.
		expect(state.resizeColumnGap(in: home, at: 0, delta: 140.4))
		expectRatios(state.workspaces[home]?.widthRatios, [0.6, 0.4])
		expect(!state.resizeColumnGap(in: home, at: 0, delta: 702), "the right column would go below the minimum")
		expectRatios(state.workspaces[home]?.widthRatios, [0.6, 0.4])
		expect(!state.resizeColumnGap(in: home, at: 1, delta: 10))
		state.workspaces[home]!.widthRatios = [0.2, 0.3, 0.5]
		expect(state.resizeColumnGap(in: home, at: 0, delta: -70.2))
		expectRatios(state.workspaces[home]?.widthRatios, [0.45, 0.55], "stale ratios restart from even")
	},

	TestCase("dragging a row boundary shifts height between the two rows") {
		var state = testState()
		let home = state.testActive()
		state.testSetColumns(home, [[1], [2, 3]])
		// 875 high: 875 - 2 * 12 padding - 12 gap = 839 pt to share.
		expect(state.resizeRowGap(in: home, column: 1, row: 0, delta: 83.9))
		expectRatios(state.workspaces[home]?.rowRatios[1], [0.6, 0.4])
		expect(!state.resizeRowGap(in: home, column: 0, row: 0, delta: 10), "a single row has no boundary")
		expect(!state.resizeRowGap(in: home, column: 1, row: 0, delta: 420))
	},

	TestCase("resizing a window takes the change from both neighbours") {
		var state = testState()
		let home = state.testActive()
		state.testSetColumns(home, [[1], [2], [3]])
		let third: CGFloat = 1.0 / 3.0
		expect(state.resizeWindow(2, increase: true))
		expectRatios(state.workspaces[home]?.widthRatios, [third - 0.025, third + 0.05, third - 0.025])
		state.workspaces[home]!.widthRatios = nil
		expect(state.resizeWindow(1, increase: true))
		expectRatios(state.workspaces[home]?.widthRatios, [third + 0.05, third - 0.05, third])
		state.workspaces[home]!.widthRatios = [0.12, 0.76, 0.12]
		expect(!state.resizeWindow(2, increase: true), "neighbours at the minimum")
		expect(state.resizeWindow(2, increase: false))

		var single = testState()
		single.testSetColumns(single.testActive(), [[1, 2]])
		expect(!single.resizeWindow(1, increase: true), "one column cannot be resized")
	},
]

// MARK: - Retire

private let retireTests: [TestCase] = [
	TestCase("retire removes the window everywhere and tombstones it") {
		var state = testState()
		let row = state.testSetRow(nonNegatives: 2, active: 1)
		state.testSetColumns(row[0], [[7]])
		state.testSetColumns(row[1], [[1], [2]])
		state.testAddWindow(3, workspace: row[1], visibility: .axisMinimized)
		state.hiddenStack = [HiddenEntry(window: 3, minimizeConfirmed: true)]
		state.ledger[2] = LastWrite(target: .zero, kind: .frame, at: 1)
		state.focus.current = 2
		state.relaunchTiled = [2]
		expectInvariants(state, "before")

		let retired = state.retire(2, reason: .destroyed, now: 5)
		expectEqual(state.records[2], nil)
		expectEqual(state.testColumns(row[1]), [[1]])
		expectEqual(state.ledger[2], nil)
		expect(state.tombstones.contains(2))
		expectEqual(state.focus.current, nil)
		expectEqual(state.relaunchTiled, [])
		expectEqual(retired?.record.slotMemory, SlotMemory(leftRep: 1, workspace: row[1]))
		expectEqual(retired?.at, 5)
		expectEqual(retired?.monitor, main)
		expectEqual(retired?.number, 1)
		expect(state.events.contains(.retired(2, .destroyed)))
		expect(state.log.contains { $0.message == "track: retire App/W2#2 (destroyed) from Main ws2[\(row[1])]" },
			"retire log line: \(state.log)")

		let hidden = state.retire(3, reason: .appTerminated, now: 6)
		expectEqual(hidden?.hiddenEntry, HiddenEntry(window: 3, minimizeConfirmed: true))
		expectEqual(hidden?.hiddenIndex, 0)
		expectEqual(state.hiddenStack, [])
		expectEqual(state.retire(3, reason: .destroyed, now: 7), nil)
		expectInvariants(state, "after")
	},

	TestCase("retiring the last window of the active workspace hands over to a neighbour") {
		var state = testState()
		let row = state.testSetRow(nonNegatives: 2, active: 1)
		state.testSetColumns(row[0], [[1]])
		state.testSetColumns(row[1], [[2]])
		state.retire(2, reason: .destroyed, now: 1)
		expectEqual(state.testRow(), [row[0]])
		expectEqual(state.testActive(), row[0])
		expect(state.events.contains(.activeChanged(monitor: main, from: row[1], to: row[0], cause: .compaction)))
		expectInvariants(state)
	},

	TestCase("retiring the Zen focus or a window Zen parked ends Zen") {
		var state = testState()
		let home = state.testActive()
		state.testSetColumns(home, [[1], [2], [3]], visibility: [2: .zenHidden, 3: .zenHidden])
		state.zen = ZenSession(monitor: main, workspace: home, focus: 1)
		var closingHidden = state
		closingHidden.retire(2, reason: .destroyed, now: 1)
		expectEqual(closingHidden.zen, nil)
		expect(closingHidden.events.contains(.zenEnded(.hiddenClosed)))
		let retired = state.retire(1, reason: .destroyed, now: 1)
		expect(retired?.wasZenFocus == true)
		expectEqual(state.zen, nil)
		expect(state.events.contains(.zenEnded(.focusClosed)))
		expectInvariants(state)
	},

	TestCase("a retire can leave the compaction to the caller") {
		var state = testState()
		let row = state.testSetRow(nonNegatives: 2, active: 1)
		state.testSetColumns(row[0], [[1]])
		state.testSetColumns(row[1], [[2]])
		state.retire(2, reason: .destroyed, now: 1, compacting: false)
		expectEqual(state.testRow(), row)
		expectEqual(state.testActive(), row[1])
		state.compact(main, keepingActive: false)
		expectEqual(state.testRow(), [row[0]])
		expectInvariants(state)
	},

	TestCase("retiring an unmanaged window leaves the workspaces alone") {
		var state = testState()
		let row = state.testSetRow(nonNegatives: 2, active: 1)
		state.testSetColumns(row[0], [[1]])
		state.testAddWindow(5, placement: .unmanaged, workspace: nil)
		state.retire(5, reason: .destroyed, now: 1)
		expectEqual(state.testRow(), row)
		expect(state.log.contains { $0.message == "track: retire App/W5#5 (destroyed)" })
	},
]

// MARK: - Invariants

private let invariantTests: [TestCase] = [
	TestCase("invariants hold through a sequence of operations on two monitors") {
		var state = testState([testDisplay("Main", primary: true), testDisplay("Right", x: 1440, displayID: 2)])
		let right = testKey("Right")
		let home = state.testActive()
		state.testSetColumns(home, [[1, 2], [3]])
		state.testSetColumns(state.testActive("Right"), [[4]])
		state.testAddWindow(5, placement: .floating, workspace: home, frame: CGRect(x: 300, y: 300, width: 400, height: 300))
		state.testAddWindow(6, placement: .unmanaged, workspace: nil, frame: CGRect(x: 1600, y: 300, width: 300, height: 200))
		var step = 0
		func check(_ label: String) {
			step += 1
			expectInvariants(state, "step \(step) \(label)")
		}
		check("start")
		state.moveWindow(2, .right); check("move right")
		state.stepMove(1, .right); check("step right")
		state.switchWorkspace(on: main, to: .next); check("next")
		state.switchWorkspace(on: main, to: .prev); check("prev")
		state.moveWindowToWorkspace(3, on: main, to: .prev); check("move to prev")
		state.switchWorkspace(on: main, to: .next); check("back")
		state.moveWindow(1, .right); check("move right again")
		state.moveWindowToMonitor(4, to: main, edge: .left); check("move to main")
		state.toggleFloat(4); check("float")
		state.toggleFloat(4); check("tile")
		state.toggleFloat(6); check("centre unmanaged")
		state.moveWindowToWorkspace(5, on: main, to: .next); check("floating to next")
		state.switchWorkspace(on: right, to: .prev); check("right prev")
		state.resetToSingleColumns(state.testActive()); check("reset")
		state.resizeWindow(2, increase: true); check("resize")
		for id in state.records.keys.sorted() {
			state.retire(id, reason: .appTerminated, now: 10)
			check("retire #\(id)")
		}
		expectEqual(state.records.count, 0)
		expectEqual(state.testRow().count, 1)
		expectEqual(state.testRow("Right").count, 1)
	},

	TestCase("checkInvariants reports each broken rule") {
		func problems(_ edit: (inout TrackingState) -> Void) -> [String] {
			var state = testState([testDisplay("Main", primary: true), testDisplay("Right", x: 1440, displayID: 2)])
			let home = state.testActive()
			state.testSetColumns(home, [[1], [2]])
			state.testAddWindow(3, placement: .floating, workspace: home)
			state.testAddWindow(4, placement: .unmanaged, workspace: nil)
			edit(&state)
			return state.checkInvariants()
		}
		func expectRule(_ rule: String, _ edit: (inout TrackingState) -> Void, line: UInt = #line) {
			let found = problems(edit)
			expect(found.contains { $0.hasPrefix(rule + ":") }, "expected \(rule), got \(found)", line: line)
		}
		expectEqual(problems { _ in }, [])
		expectRule("I1") { $0.records[3]!.workspace = WorkspaceID(raw: 900) }
		expectRule("I2") { state in
			let home = state.testActive()
			state.monitors[testKey("Right")]!.order.append(home)
		}
		expectRule("I2") { state in
			let stray = state.makeWorkspaceID()
			state.workspaces[stray] = Workspace(id: stray, host: main)
		}
		expectRule("I3") { $0.monitors[main]!.active = WorkspaceID(raw: 900) }
		expectRule("I3") { $0.monitors[main]!.negativeCount = 1 }
		expectRule("I4") { state in
			let home = state.testActive()
			state.workspaces[home]!.columns = [[1], [2, 1]]
		}
		expectRule("I4") { state in
			let home = state.testActive()
			state.workspaces[home]!.columns = [[1], [2], [3]]
		}
		expectRule("I4") { state in
			let home = state.testActive()
			state.workspaces[home]!.columns = [[1], [], [2]]
		}
		expectRule("I4") { state in
			let other = state.testActive("Right")
			state.workspaces[other]!.columns = [[1]]
		}
		expectRule("I4") { state in
			let home = state.testActive()
			state.testAddWindow(5, workspace: home, visibility: .nativeMinimized)
			state.workspaces[home]!.columns.append([5])
		}
		expectRule("I5") { state in
			let home = state.testActive()
			state.testAddWindow(5, workspace: home)
		}
		expectRule("I6") { $0.hiddenStack = [HiddenEntry(window: 1)] }
		expectRule("I6") { $0.hiddenStack = [HiddenEntry(window: 77)] }
		expectRule("I7") { state in
			let home = state.testActive()
			state.zen = ZenSession(monitor: main, workspace: home, focus: 77)
		}
		expectRule("I7") { state in
			let other = state.testActive("Right")
			state.zen = ZenSession(monitor: main, workspace: other, focus: 1)
		}
		expectRule("I8") { $0.records[4]!.workspace = $0.testActive() }
		expectRule("I8") { $0.records[3]!.workspace = nil }
		expectRule("I9") { $0.tombstones.insert(1) }
	},
]

// MARK: - Small helpers

private let helperTests: [TestCase] = [
	TestCase("tombstones forget the oldest ids past their capacity") {
		var tombstones = TombstoneSet(capacity: 3)
		for id: WindowID in [1, 2, 3, 2, 4] {
			tombstones.insert(id)
		}
		expectEqual(tombstones.count, 3)
		expect(!tombstones.contains(1))
		expect(tombstones.contains(2) && tombstones.contains(3) && tombstones.contains(4))
		tombstones.insert(5)
		expect(!tombstones.contains(2))
		expectEqual(TombstoneSet().capacity, 4096)
	},

	TestCase("relative frames come back inside a smaller visible area") {
		let wide = CGRect(x: 0, y: 25, width: 1440, height: 875)
		let small = CGRect(x: 0, y: 25, width: 1280, height: 775)
		let frame = RelativeFrame(frame: CGRect(x: 1000, y: 500, width: 400, height: 300), monitor: main, visibleFrame: wide)
		expectEqual(frame.offset, CGPoint(x: 1000, y: 475))
		expectEqual(frame.frame(in: wide), CGRect(x: 1000, y: 500, width: 400, height: 300))
		expectEqual(frame.frame(in: small), CGRect(x: 880, y: 500, width: 400, height: 300))
		let moved = CGRect(x: 1440, y: 25, width: 1920, height: 1055)
		expectEqual(frame.frame(in: moved), CGRect(x: 2440, y: 500, width: 400, height: 300))
		let oversized = RelativeFrame.centred(size: CGSize(width: 2000, height: 300), monitor: main, visibleFrame: wide)
		expectEqual(oversized.frame(in: wide).minX, -280, "too wide to fit: stays centred")
	},

	TestCase("monitor lookup falls back to the nearest monitor") {
		let state = testState([testDisplay("Main", primary: true), testDisplay("Right", x: 1440, displayID: 2)])
		expectEqual(state.monitorKey(for: CGRect(x: 1500, y: 100, width: 200, height: 200)), testKey("Right"))
		expectEqual(state.monitorKey(for: CGRect(x: -900, y: 300, width: 200, height: 200)), main)
		expectEqual(state.monitorKey(for: CGRect(x: 3400, y: 100, width: 200, height: 200)), testKey("Right"))
		expectEqual(state.primaryMonitor, main)
		expectEqual(state.focusMonitor(), main)
	},

	TestCase("adjacent monitors are found on each side in top-left coordinates") {
		let state = testState([
			testDisplay("Main", primary: true),
			testDisplay("Right", x: 1440, y: 100, displayID: 2),
			testDisplay("Top", y: -900, displayID: 3),
			testDisplay("Below", x: 200, y: 900, displayID: 4),
			testDisplay("Far", x: 5000, y: 5000, displayID: 5),
		])
		expectEqual(state.adjacentMonitor(of: main, toward: .right), testKey("Right"))
		expectEqual(state.adjacentMonitor(of: main, toward: .up), testKey("Top"))
		expectEqual(state.adjacentMonitor(of: main, toward: .down), testKey("Below"))
		expectEqual(state.adjacentMonitor(of: main, toward: .left), nil)
		expectEqual(state.adjacentMonitor(of: testKey("Right"), toward: .left), main)
		expectEqual(state.adjacentMonitor(of: testKey("Far"), toward: .left), nil)
	},

	TestCase("queries answer from the records alone") {
		var state = testState()
		let row = state.testSetRow(nonNegatives: 2, active: 0)
		state.testSetColumns(row[0], [[2], [1]])
		state.testAddWindow(5, placement: .floating, workspace: row[0])
		state.testAddWindow(3, workspace: row[0], visibility: .nativeMinimized)
		state.testSetColumns(row[1], [[4]], visibility: [4: .parked(.workspaceInactive)])
		expectEqual(state.orderedWindows(row[0]), [2, 1, 3, 5])
		expectEqual(state.members(of: row[0]), [1, 2, 3, 5])
		expect(!state.isHidden(1))
		expect(state.isHidden(4))
		expect(!state.isHidden(99), "untracked windows are never hidden")
		expectEqual(state.visibility(99), nil)
		expect(state.isFloating(5))
		expectEqual(state.location(4), WindowLocation(monitor: main, workspace: row[1], number: 1))
		expectEqual(state.location(99), nil)
		expect(state.isActive(row[0]) && !state.isActive(row[1]))
		expectEqual(state.describe(1), "App/W1#1")
		expectEqual(state.describe(99), "#99")
		expectEqual(TrackingState.describeFrame(CGRect(x: 58.4, y: 45, width: 352, height: 899.6)), "58,45 352x900")
		expectEqual(state.drainLog(), [])
		expectInvariants(state)
	},
]

// MARK: - Reference model of the column operations

/// A column operation of the randomized comparisons.
private enum ColumnOperation: CustomStringConvertible {
	case move(WindowID, MoveDirection)
	case step(WindowID, MoveDirection)
	case reserve(ReservationKind, Int)
	case reset
	case columnGap(Int, CGFloat)
	case rowGap(Int, Int, CGFloat)
	case resize(WindowID, Bool)

	/// The id a reservation inserts.
	static let reservedID: WindowID = 1000

	var description: String {
		switch self {
		case .move(let id, let direction): return "move #\(id) \(direction)"
		case .step(let id, let direction): return "step #\(id) \(direction)"
		case .reserve(let kind, let index): return "reserve \(kind) at \(index)"
		case .reset: return "reset"
		case .columnGap(let index, let delta): return "column gap \(index) by \(delta)"
		case .rowGap(let column, let row, let delta): return "row gap \(column)/\(row) by \(delta)"
		case .resize(let id, let increase): return "resize #\(id) \(increase ? "up" : "down")"
		}
	}
}

private func apply(_ operation: ColumnOperation, to state: inout TrackingState, workspace: WorkspaceID) {
	switch operation {
	case .move(let id, let direction):
		state.moveWindow(id, direction)
	case .step(let id, let direction):
		state.stepMove(id, direction)
	case .reserve(let kind, let index):
		state.testAddWindow(ColumnOperation.reservedID, workspace: workspace)
		state.insertReserved(ColumnOperation.reservedID, kind: kind, columnIndex: index, into: workspace)
	case .reset:
		state.resetToSingleColumns(workspace)
	case .columnGap(let index, let delta):
		state.resizeColumnGap(in: workspace, at: index, delta: delta)
	case .rowGap(let column, let row, let delta):
		state.resizeRowGap(in: workspace, column: column, row: row, delta: delta)
	case .resize(let id, let increase):
		state.resizeWindow(id, increase: increase)
	}
}

/// A direct model of the column operations on window ids, on one screen with no neighbouring
/// screen (so moves past an edge do nothing). The state's operations are checked against it.
private struct ReferenceTiling {
	var columns: [[WindowID]]
	var widthRatios: [CGFloat]?
	var rowRatios: [Int: [CGFloat]]

	private func position(_ id: WindowID) -> (column: Int, row: Int)? {
		for (column, ids) in columns.enumerated() {
			if let row = ids.firstIndex(of: id) { return (column, row) }
		}
		return nil
	}

	private func even(_ count: Int) -> [CGFloat] {
		Array(repeating: 1.0 / CGFloat(count), count: count)
	}

	mutating func apply(_ operation: ColumnOperation, visibleFrame: CGRect, config: LayoutConfig) {
		switch operation {
		case .move(let id, let direction): moveWindow(id, direction)
		case .step(let id, let direction): stepMoveWindow(id, direction)
		case .reserve(let kind, let index): insertReservedWindow(ColumnOperation.reservedID, columnIndex: index, kind: kind)
		case .reset: columns = columns.flatMap { $0 }.map { [$0] }
		case .columnGap(let index, let delta): resizeColumnGap(at: index, delta: delta, visibleFrame: visibleFrame, config: config)
		case .rowGap(let column, let row, let delta):
			resizeRowGap(columnIndex: column, rowIndex: row, delta: delta, visibleFrame: visibleFrame, config: config)
		case .resize(let id, let increase): resizeCurrentWindow(id, increase: increase)
		}
	}

	private mutating func moveWindow(_ id: WindowID, _ direction: MoveDirection) {
		guard let (columnIndex, rowIndex) = position(id) else { return }
		switch direction {
		case .left:
			if columnIndex > 0 {
				columns.swapAt(columnIndex, columnIndex - 1)
				if var ratios = widthRatios, ratios.count == columns.count {
					ratios.swapAt(columnIndex, columnIndex - 1)
					widthRatios = ratios
				}
				let temp = rowRatios[columnIndex]
				rowRatios[columnIndex] = rowRatios[columnIndex - 1]
				rowRatios[columnIndex - 1] = temp
			}
		case .right:
			if columnIndex < columns.count - 1 {
				columns.swapAt(columnIndex, columnIndex + 1)
				if var ratios = widthRatios, ratios.count == columns.count {
					ratios.swapAt(columnIndex, columnIndex + 1)
					widthRatios = ratios
				}
				let temp = rowRatios[columnIndex]
				rowRatios[columnIndex] = rowRatios[columnIndex + 1]
				rowRatios[columnIndex + 1] = temp
			}
		case .up:
			if rowIndex > 0 {
				columns[columnIndex].swapAt(rowIndex, rowIndex - 1)
				if var ratios = rowRatios[columnIndex], ratios.count == columns[columnIndex].count {
					ratios.swapAt(rowIndex, rowIndex - 1)
					rowRatios[columnIndex] = ratios
				}
			}
		case .down:
			if rowIndex < columns[columnIndex].count - 1 {
				columns[columnIndex].swapAt(rowIndex, rowIndex + 1)
				if var ratios = rowRatios[columnIndex], ratios.count == columns[columnIndex].count {
					ratios.swapAt(rowIndex, rowIndex + 1)
					rowRatios[columnIndex] = ratios
				}
			}
		}
	}

	private mutating func stepMoveWindow(_ id: WindowID, _ direction: MoveDirection) {
		guard direction == .left || direction == .right else { return }
		guard let (columnIndex, rowIndex) = position(id) else { return }
		if columns[columnIndex].count > 1 {
			columns[columnIndex].remove(at: rowIndex)
			let insertIndex = (direction == .left) ? columnIndex : columnIndex + 1
			columns.insert([id], at: insertIndex)
		} else {
			let targetColumnIndex = (direction == .left) ? columnIndex - 1 : columnIndex + 1
			guard targetColumnIndex >= 0 && targetColumnIndex < columns.count else { return }
			columns.remove(at: columnIndex)
			let adjustedTargetIndex = (direction == .left) ? targetColumnIndex : targetColumnIndex - 1
			columns[adjustedTargetIndex].append(id)
		}
	}

	private mutating func insertReservedWindow(_ id: WindowID, columnIndex: Int, kind: ReservationKind) {
		for index in 0..<columns.count {
			columns[index].removeAll { $0 == id }
		}
		columns = columns.filter { !$0.isEmpty }
		switch kind {
		case .aboveInColumn, .belowInColumn:
			guard !columns.isEmpty else {
				columns = [[id]]
				return
			}
			let index = min(max(columnIndex, 0), columns.count - 1)
			if kind == .aboveInColumn {
				columns[index].insert(id, at: 0)
			} else {
				columns[index].append(id)
			}
		case .newColumnLeft:
			columns.insert([id], at: min(max(columnIndex, 0), columns.count))
		case .newColumnRight:
			columns.insert([id], at: min(max(columnIndex + 1, 0), columns.count))
		case .float:
			return
		}
	}

	private mutating func resizeColumnGap(at columnIndex: Int, delta: CGFloat, visibleFrame: CGRect, config: LayoutConfig) {
		guard columns.count > 1 else { return }
		guard columnIndex >= 0 && columnIndex < columns.count - 1 else { return }
		var ratios = widthRatios ?? even(columns.count)
		if ratios.count != columns.count {
			ratios = even(columns.count)
		}
		let totalColumnGaps = config.gap * CGFloat(columns.count - 1)
		let availableWidth = visibleFrame.width - (config.padding * 2) - totalColumnGaps
		let deltaRatio = delta / availableWidth
		let minRatio: CGFloat = 0.1
		let newLeftRatio = ratios[columnIndex] + deltaRatio
		let newRightRatio = ratios[columnIndex + 1] - deltaRatio
		guard newLeftRatio >= minRatio && newRightRatio >= minRatio else { return }
		ratios[columnIndex] = newLeftRatio
		ratios[columnIndex + 1] = newRightRatio
		widthRatios = ratios
	}

	private mutating func resizeRowGap(columnIndex: Int, rowIndex: Int, delta: CGFloat, visibleFrame: CGRect, config: LayoutConfig) {
		guard columnIndex >= 0 && columnIndex < columns.count else { return }
		let column = columns[columnIndex]
		guard column.count > 1 else { return }
		guard rowIndex >= 0 && rowIndex < column.count - 1 else { return }
		var ratios = rowRatios[columnIndex] ?? even(column.count)
		if ratios.count != column.count {
			ratios = even(column.count)
		}
		let totalRowGaps = config.gap * CGFloat(column.count - 1)
		let availableHeight = visibleFrame.height - (config.padding * 2) - totalRowGaps
		let deltaRatio = delta / availableHeight
		let minRatio: CGFloat = 0.1
		let newUpperRatio = ratios[rowIndex] + deltaRatio
		let newLowerRatio = ratios[rowIndex + 1] - deltaRatio
		guard newUpperRatio >= minRatio && newLowerRatio >= minRatio else { return }
		ratios[rowIndex] = newUpperRatio
		ratios[rowIndex + 1] = newLowerRatio
		rowRatios[columnIndex] = ratios
	}

	private mutating func resizeCurrentWindow(_ id: WindowID, increase: Bool) {
		guard let (columnIndex, _) = position(id) else { return }
		guard columns.count > 1 else { return }
		let resizeStep: CGFloat = 0.05
		let delta = increase ? resizeStep : -resizeStep
		var ratios = widthRatios ?? even(columns.count)
		if ratios.count != columns.count {
			ratios = even(columns.count)
		}
		let minRatio: CGFloat = 0.1
		let hasLeft = columnIndex > 0
		let hasRight = columnIndex < columns.count - 1
		if hasLeft && hasRight {
			let halfDelta = delta / 2.0
			let newLeft = ratios[columnIndex - 1] - halfDelta
			let newRight = ratios[columnIndex + 1] - halfDelta
			let newCurrent = ratios[columnIndex] + delta
			guard newLeft >= minRatio && newRight >= minRatio && newCurrent >= minRatio else { return }
			ratios[columnIndex - 1] = newLeft
			ratios[columnIndex + 1] = newRight
			ratios[columnIndex] = newCurrent
		} else if hasLeft {
			let newLeft = ratios[columnIndex - 1] - delta
			let newCurrent = ratios[columnIndex] + delta
			guard newLeft >= minRatio && newCurrent >= minRatio else { return }
			ratios[columnIndex - 1] = newLeft
			ratios[columnIndex] = newCurrent
		} else if hasRight {
			let newRight = ratios[columnIndex + 1] - delta
			let newCurrent = ratios[columnIndex] + delta
			guard newRight >= minRatio && newCurrent >= minRatio else { return }
			ratios[columnIndex + 1] = newRight
			ratios[columnIndex] = newCurrent
		}
		widthRatios = ratios
	}
}

// MARK: - Random layouts

/// 1-5 columns of 1-3 windows (ids from 1) with valid, stale or missing ratios.
private func randomLayout(_ random: inout SeededGenerator) -> (columns: [[WindowID]], widthRatios: [CGFloat]?, rowRatios: [Int: [CGFloat]]) {
	var next: WindowID = 1
	var columns: [[WindowID]] = []
	for _ in 0..<Int.random(in: 1...5, using: &random) {
		var column: [WindowID] = []
		for _ in 0..<Int.random(in: 1...3, using: &random) {
			column.append(next)
			next += 1
		}
		columns.append(column)
	}
	func ratios(_ count: Int) -> [CGFloat] {
		let weights = (0..<count).map { _ in CGFloat.random(in: 1...4, using: &random) }
		let total = weights.reduce(0, +)
		return weights.map { $0 / total }
	}
	let widthRatios: [CGFloat]?
	switch Int.random(in: 0..<10, using: &random) {
	case 0..<3: widthRatios = nil
	case 3..<8: widthRatios = ratios(columns.count)
	default: widthRatios = ratios(columns.count + Int.random(in: 1...2, using: &random))
	}
	var rowRatios: [Int: [CGFloat]] = [:]
	for (index, column) in columns.enumerated() where Bool.random(using: &random) {
		rowRatios[index] = ratios(Bool.random(using: &random) ? column.count : column.count + 1)
	}
	return (columns, widthRatios, rowRatios)
}

private func randomOperation(_ random: inout SeededGenerator, columns: [[WindowID]]) -> ColumnOperation {
	let ids = Array(columns.joined())
	let id = ids.randomElement(using: &random)!
	let directions: [MoveDirection] = [.left, .right, .up, .down]
	let kinds: [ReservationKind] = [.aboveInColumn, .belowInColumn, .newColumnLeft, .newColumnRight]
	switch Int.random(in: 0..<7, using: &random) {
	case 0:
		return .move(id, directions.randomElement(using: &random)!)
	case 1:
		return .step(id, directions.randomElement(using: &random)!)
	case 2:
		return .reserve(kinds.randomElement(using: &random)!, Int.random(in: -1...(columns.count + 1), using: &random))
	case 3:
		return .reset
	case 4:
		return .columnGap(Int.random(in: -1...columns.count, using: &random), CGFloat(Int.random(in: -400...400, using: &random)))
	case 5:
		return .rowGap(Int.random(in: -1...columns.count, using: &random), Int.random(in: -1...3, using: &random),
			CGFloat(Int.random(in: -300...300, using: &random)))
	default:
		return .resize(id, Bool.random(using: &random))
	}
}
