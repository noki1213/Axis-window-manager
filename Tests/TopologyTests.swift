//
//  TopologyTests.swift
//  Axis core tests
//
//  Display topology changes: screens added, removed, replaced and reordered.
//

import Foundation
import CoreGraphics

private let main = testKey("Main")
private let ext = testKey("Ext")

let topologyTests: [TestCase] = [
	TestCase("new displayID with same UUID keeps workspaces") {
		var state = testState([testDisplay("Main", primary: true, displayID: 1)])
		let row = state.testSetRow("Main", negatives: 1, nonNegatives: 2, active: 1)
		let change = state.reconcileTopology([testDisplay("Main", primary: true, displayID: 99)], now: 1.0)
		expectEqual(state.testRow("Main"), row)
		expectEqual(state.monitors[main]?.displayID, 99)
		expectEqual(change.kept, [main])
		expectEqual(change.added, [])
		expectEqual(change.removed, [])
		expectEqual(change.isEmpty, true)
		expectInvariants(state)
	},

	TestCase("monitor added without memory gets a fresh workspace and nothing else moves") {
		var state = testState([testDisplay("Main", primary: true)])
		let mainRow = state.testSetRow("Main", negatives: 0, nonNegatives: 2, active: 0)
		let change = state.reconcileTopology([
			testDisplay("Main", primary: true),
			testDisplay("Ext", x: 1440, primary: false)
		], now: 2.0)
		expectEqual(change.kept, [main])
		expectEqual(change.added, [ext])
		expectEqual(change.removed, [])
		expectEqual(change.restored, [])
		expectEqual(change.adopted, [:])
		expectEqual(change.migrated, [])
		expectEqual(state.testRow("Main"), mainRow)
		expectEqual(state.testActive("Main"), mainRow[0])
		let extRow = state.testRow("Ext")
		expectEqual(extRow.count, 1)
		expectEqual(state.monitors[ext]?.negativeCount, 0)
		expectEqual(state.testActive("Ext"), extRow[0])
		expectInvariants(state)
	},

	TestCase("sequence of degenerate and empty configs equals applying final config directly") {
		var state1 = testState([
			testDisplay("Main", primary: true),
			testDisplay("Ext", x: 1440, primary: false)
		])
		state1.testSetRow("Main", negatives: 1, nonNegatives: 2, active: 0)
		state1.testSetRow("Ext", negatives: 0, nonNegatives: 2, active: 1)
		var state2 = state1

		let ignored1 = state1.reconcileTopology([], now: 10.0)
		expectEqual(ignored1.ignored, true)
		let ignored2 = state1.reconcileTopology([testDisplay("Main", width: 1, height: 900, primary: true)], now: 11.0)
		expectEqual(ignored2.ignored, true)
		let ignored3 = state1.reconcileTopology([testDisplay("Main", width: 1440, height: 1, primary: true)], now: 12.0)
		expectEqual(ignored3.ignored, true)
		let ignored4 = state1.reconcileTopology([
			DisplayFacts(key: main, displayID: 1, name: "Main", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
				visibleFrame: CGRect(x: 0, y: 0, width: 0, height: 0), isPrimary: true)
		], now: 13.0)
		expectEqual(ignored4.ignored, true)

		let finalDisplays = [testDisplay("Main", width: 1920, height: 1080, primary: true)]
		state1.reconcileTopology(finalDisplays, now: 20.0)
		state2.reconcileTopology(finalDisplays, now: 20.0)

		expectEqual(state1, state2)
		expectInvariants(state1)
		expectInvariants(state2)
	},

	TestCase("one to one replacement adopts the old monitor's workspaces") {
		var state = testState([testDisplay("BuiltIn", primary: true)])
		let builtInKey = testKey("BuiltIn")
		let originalRow = state.testSetRow("BuiltIn", negatives: 1, nonNegatives: 2, active: 1)

		let externalKey = testKey("External")
		let change = state.reconcileTopology([testDisplay("External", primary: true)], now: 5.0)

		expectEqual(change.removed, [builtInKey])
		expectEqual(change.added, [externalKey])
		expectEqual(change.adopted, [externalKey: builtInKey])
		expectEqual(state.monitors[builtInKey], nil)
		expectEqual(state.testRow("External"), originalRow)
		expectEqual(state.monitors[externalKey]?.negativeCount, 1)
		expectEqual(state.testActive("External"), originalRow[2])
		expectEqual(state.memory[builtInKey]?.adoptedBy, externalKey)
		for wsID in originalRow {
			expectEqual(state.workspaces[wsID]?.host, externalKey)
		}
		expectInvariants(state)
	},

	TestCase("two to one then one to one virtual display preserves all workspaces") {
		var state = testState([
			testDisplay("Main", primary: true),
			testDisplay("Ext", x: 1440, primary: false)
		])
		let mainWs = state.testActive("Main")
		let extWs = state.testActive("Ext")

		// First transition: secondary monitor disconnected, workspaces migrate to primary.
		let change1 = state.reconcileTopology([testDisplay("Main", primary: true)], now: 10.0)
		expectEqual(change1.removed, [ext])
		expectEqual(change1.migrated, [ext])
		expectEqual(state.testRow("Main"), [mainWs, extWs])
		expectEqual(state.workspaces[extWs]?.host, main)
		expectEqual(state.workspaces[extWs]?.origin, ext)
		expectEqual(state.monitors[main]?.activeBeforeHosting, mainWs)
		expectInvariants(state)

		// Second transition: primary replaced 1:1 by virtual display.
		let virtualKey = testKey("Virtual")
		let change2 = state.reconcileTopology([testDisplay("Virtual", primary: true)], now: 20.0)
		expectEqual(change2.removed, [main])
		expectEqual(change2.added, [virtualKey])
		expectEqual(change2.adopted, [virtualKey: main])
		expectEqual(state.testRow("Virtual"), [mainWs, extWs])
		expectEqual(state.workspaces[mainWs]?.host, virtualKey)
		expectEqual(state.workspaces[extWs]?.host, virtualKey)
		expectEqual(state.memory[main]?.adoptedBy, virtualKey)
		expectInvariants(state)
	},

	TestCase("unplug replug round trip restores order and active workspace") {
		var state = testState([
			testDisplay("Main", primary: true),
			testDisplay("Ext", x: 1440, primary: false)
		])
		let extRow = state.testSetRow("Ext", negatives: 1, nonNegatives: 2, active: 1)
		let extActive = extRow[2]

		// Unplug external monitor.
		state.reconcileTopology([testDisplay("Main", primary: true)], now: 10.0)
		expectEqual(state.monitors[ext], nil)
		expectEqual(state.memory[ext]?.adoptedBy, nil)
		expectInvariants(state)

		// Replug external monitor.
		let change = state.reconcileTopology([
			testDisplay("Main", primary: true),
			testDisplay("Ext", x: 1440, primary: false)
		], now: 20.0)
		expectEqual(change.restored, [ext])
		expectEqual(state.testRow("Ext"), extRow)
		expectEqual(state.testActive("Ext"), extActive)
		expectEqual(state.monitors[ext]?.negativeCount, 1)
		for wsID in extRow {
			expectEqual(state.workspaces[wsID]?.host, ext)
		}
		expectInvariants(state)
	},

	TestCase("host active workspace fallback when returning monitor reclaims active workspace") {
		var state = testState([
			testDisplay("Main", primary: true),
			testDisplay("Ext", x: 1440, primary: false)
		])
		let mainWs = state.testActive("Main")
		let extWs = state.testActive("Ext")

		// Unplug external monitor.
		state.reconcileTopology([testDisplay("Main", primary: true)], now: 10.0)
		expectEqual(state.testRow("Main"), [mainWs, extWs])

		// User activates the hosted workspace while external is disconnected.
		state.monitors[main]?.active = extWs
		_ = state.drainEvents()

		// Replug external monitor: hosted workspace leaves, host must fall back to activeBeforeHosting.
		state.reconcileTopology([
			testDisplay("Main", primary: true),
			testDisplay("Ext", x: 1440, primary: false)
		], now: 20.0)
		expectEqual(state.testActive("Main"), mainWs)
		expectEqual(state.testActive("Ext"), extWs)
		expectEqual(state.events.contains(.activeChanged(monitor: main, from: extWs, to: mainWs, cause: .topology)), true)
		expectInvariants(state)
	},

	TestCase("zen ends when its monitor is disconnected") {
		var state = testState([
			testDisplay("Main", primary: true),
			testDisplay("Ext", x: 1440, primary: false)
		])
		let extWs = state.testActive("Ext")
		state.testAddWindow(42, placement: .tiled, workspace: extWs, visibility: .visible)
		state.testSetColumns(extWs, [[42]])

		let entered = state.zenEnter(42, now: 1.0)
		expectEqual(entered, true)
		expectEqual(state.zen?.monitor, ext)
		_ = state.drainEvents()

		// Disconnect external monitor.
		state.reconcileTopology([testDisplay("Main", primary: true)], now: 2.0)
		expectEqual(state.zen, nil)
		expectEqual(state.events.contains(.zenEnded(.monitorGone)), true)
		expectInvariants(state)
	},

	TestCase("duplicate UUID disambiguation assigns distinct keys in displayID order") {
		let d1 = testDisplay("Dell", primary: true, displayID: 10)
		let d2 = testDisplay("Dell", x: 1440, primary: false, displayID: 20)
		let disambiguated = TopologyState.disambiguate([d1, d2])
		expectEqual(disambiguated[0].key, testKey("Dell"))
		expectEqual(disambiguated[1].key, MonitorKey(raw: "\(testKey("Dell").raw)#2"))

		var state = TrackingState()
		state.reconcileTopology([d1, d2], now: 1.0)
		expectEqual(state.monitors.count, 2)
		expectEqual(state.monitors[testKey("Dell")] != nil, true)
		expectEqual(state.monitors[MonitorKey(raw: "\(testKey("Dell").raw)#2")] != nil, true)
		expectEqual(state.monitorOrder, [testKey("Dell"), MonitorKey(raw: "\(testKey("Dell").raw)#2")])
		expectInvariants(state)
	},

	TestCase("returning monitor with adopted memory leaves workspaces on adopting monitor by default") {
		var state = testState([testDisplay("BuiltIn", primary: true)])
		let builtInKey = testKey("BuiltIn")
		let originalRow = state.testSetRow("BuiltIn", negatives: 0, nonNegatives: 2, active: 0)

		// 1:1 adopt by external monitor.
		let externalKey = testKey("External")
		state.reconcileTopology([testDisplay("External", primary: true)], now: 1.0)
		expectEqual(state.testRow("External"), originalRow)

		// Both monitors connected (lid opened): adopted workspaces stay where they were adopted.
		expectEqual(TopologyPolicy.returningMonitorReclaimsAdoptedWorkspaces, false)
		let change = state.reconcileTopology([
			testDisplay("External", primary: true),
			testDisplay("BuiltIn", x: 1440, primary: false)
		], now: 2.0)
		expectEqual(change.kept, [externalKey])
		expectEqual(change.added, [builtInKey])
		expectEqual(change.restored, [])
		expectEqual(state.testRow("External"), originalRow)
		let builtInRow = state.testRow("BuiltIn")
		expectEqual(builtInRow.count, 1)
		expectEqual(builtInRow != originalRow, true)
		expectInvariants(state)

		// Testing alternative policy flag: reclaims adopted workspaces when enabled.
		TopologyPolicy.returningMonitorReclaimsAdoptedWorkspaces = true
		defer { TopologyPolicy.returningMonitorReclaimsAdoptedWorkspaces = false }

		var stateWithReclaim = testState([testDisplay("BuiltIn", primary: true)])
		let rowToReclaim = stateWithReclaim.testSetRow("BuiltIn", negatives: 0, nonNegatives: 2, active: 0)
		stateWithReclaim.reconcileTopology([testDisplay("External", primary: true)], now: 3.0)
		stateWithReclaim.reconcileTopology([
			testDisplay("External", primary: true),
			testDisplay("BuiltIn", x: 1440, primary: false)
		], now: 4.0)
		expectEqual(stateWithReclaim.testRow("BuiltIn"), rowToReclaim)
		expectInvariants(stateWithReclaim)
	},

	TestCase("palette ends and reservation on disconnected monitor clears") {
		var state = testState([
			testDisplay("Main", primary: true),
			testDisplay("Ext", x: 1440, primary: false)
		])
		state.paletteBegin(now: 1.0)
		expectEqual(state.palette != nil, true)
		state.reservation = PlacementReservation(kind: .float, monitor: ext, columnIndex: 0)

		state.reconcileTopology([testDisplay("Main", primary: true)], now: 2.0)
		expectEqual(state.palette, nil)
		expectEqual(state.reservation, nil)
		expectInvariants(state)
	}
]
