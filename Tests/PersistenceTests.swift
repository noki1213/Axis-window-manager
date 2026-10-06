//
//  PersistenceTests.swift
//  Axis core tests
//
//  Snapshot encoding, decoding, and restoring workspaces across relaunch.
//

import Foundation
import CoreGraphics

private let mainKey = testKey("Main")
private let extKey = testKey("Ext")

let persistenceTests: [TestCase] = [
	TestCase("round trip snapshot encodes and decodes losslessly") {
		var state = testState([
			testDisplay("Main", primary: true),
			testDisplay("Ext", x: 1440, primary: false)
		])
		let mainRow = state.testSetRow("Main", negatives: 1, nonNegatives: 2, active: 1)
		let activeWs = mainRow[2]
		let negWs = mainRow[0]
		state.testSetColumns(activeWs, [[10, 11], [12]])
		state.workspaces[activeWs]?.widthRatios = [0.3, 0.7]
		state.workspaces[activeWs]?.rowRatios = [0: [0.4, 0.6], 1: [1.0]]

		let floatingFrame = RelativeFrame(
			monitor: mainKey,
			offset: CGPoint(x: 50, y: 50),
			size: CGSize(width: 400, height: 300)
		)
		state.testAddWindow(13, placement: .floating, workspace: activeWs)
		state.records[13]?.floatingFrame = floatingFrame

		state.testAddWindow(14, placement: .tiled, workspace: negWs, visibility: .axisMinimized)
		state.hiddenStack = [HiddenEntry(window: 14, minimizeConfirmed: true)]

		let extRow = state.testRow("Ext")
		state.testSetColumns(extRow[0], [[20]])

		let oldKey = testKey("OldDisplay")
		state.memory[oldKey] = MonitorMemory(
			key: oldKey,
			name: "OldDisplay",
			order: [WorkspaceID(raw: 99)],
			negativeCount: 0,
			active: WorkspaceID(raw: 99),
			adoptedBy: nil,
			at: 5.0
		)

		expectInvariants(state)

		let original = state.snapshot()
		let data = try original.encode()
		let decoded = try PersistenceSnapshot.decode(from: data)
		expectEqual(decoded, original)

		let dataFromState = try state.encodePersistence()
		let decodedFromState = try TrackingState.decodePersistence(from: dataFromState)
		expectEqual(decodedFromState, original)
	},

	TestCase("relaunch with same ids restores workspaces columns active workspace and floats") {
		var state = testState([testDisplay("Main", primary: true)])
		let row = state.testSetRow("Main", negatives: 1, nonNegatives: 2, active: 1)
		let negWs = row[0]
		let activeWs = row[2]

		state.testAddWindow(10, workspace: activeWs, pid: 101, title: "W10")
		state.testAddWindow(11, workspace: activeWs, pid: 101, title: "W11")
		state.testAddWindow(12, workspace: activeWs, pid: 102, title: "W12")
		state.testSetColumns(activeWs, [[10, 11], [12]])
		state.workspaces[activeWs]?.widthRatios = [0.4, 0.6]
		state.workspaces[activeWs]?.rowRatios = [0: [0.3, 0.7], 1: [1.0]]

		let relFrame = RelativeFrame(
			monitor: mainKey,
			offset: CGPoint(x: 100, y: 120),
			size: CGSize(width: 500, height: 400)
		)
		state.testAddWindow(13, placement: .floating, workspace: activeWs, pid: 103, title: "W13")
		state.records[13]?.floatingFrame = relFrame

		state.testAddWindow(14, workspace: negWs, pid: 104, title: "W14")
		state.testSetColumns(negWs, [[14]])
		expectInvariants(state)

		let snapshot = state.snapshot()

		var newState = testState([testDisplay("Main", primary: true)])
		let facts: [WindowFacts] = [
			WindowFacts(id: 10, pid: 101, title: "W10"),
			WindowFacts(id: 11, pid: 101, title: "W11"),
			WindowFacts(id: 12, pid: 102, title: "W12"),
			WindowFacts(id: 13, pid: 103, title: "W13"),
			WindowFacts(id: 14, pid: 104, title: "W14")
		]
		let apps: [AppFacts] = [
			AppFacts(pid: 101, bundleID: "com.app.one", name: "One"),
			AppFacts(pid: 102, bundleID: "com.app.two", name: "Two"),
			AppFacts(pid: 103, bundleID: "com.app.three", name: "Three"),
			AppFacts(pid: 104, bundleID: "com.app.four", name: "Four")
		]

		newState.applyPersistence(snapshot, windows: facts, apps: apps, now: 10.0)

		expectEqual(newState.testNumbers("Main"), [-1, 0, 1])
		expectEqual(newState.number(of: newState.testActive("Main")), 1)

		let restoredActiveWs = newState.testActive("Main")
		expectEqual(newState.testColumns(restoredActiveWs), [[10, 11], [12]])
		expectRatios(newState.workspaces[restoredActiveWs]?.widthRatios, [0.4, 0.6])
		expectRatios(newState.workspaces[restoredActiveWs]?.rowRatios[0], [0.3, 0.7])

		let restoredNegWs = newState.workspace(number: -1, on: mainKey)!
		expectEqual(newState.testColumns(restoredNegWs), [[14]])

		guard let floatRecord = newState.records[13] else {
			fail("floating window 13 was not restored")
			return
		}
		expectEqual(floatRecord.placement, .floating)
		expectEqual(floatRecord.workspace, restoredActiveWs)
		expectEqual(floatRecord.floatingFrame, relFrame)
		expectEqual(floatRecord.source, .restored)

		expectInvariants(newState)
	},

	TestCase("id changed but same bundle and title matches") {
		var state = testState([testDisplay("Main", primary: true)])
		let home = state.testActive("Main")
		state.testAddWindow(10, placement: .tiled, workspace: home, pid: 100, app: "TextEdit", title: "Notes.txt")
		state.records[10]?.bundleID = "com.apple.TextEdit"
		state.testSetColumns(home, [[10]])
		expectInvariants(state)

		let snapshot = state.snapshot()

		var newState = testState([testDisplay("Main", primary: true)])
		let candidateFacts = [
			WindowFacts(id: 999, pid: 250, title: "Notes.txt")
		]
		let candidateApps = [
			AppFacts(pid: 250, bundleID: "com.apple.TextEdit", name: "TextEdit")
		]

		newState.applyPersistence(snapshot, windows: candidateFacts, apps: candidateApps, now: 20.0)

		expectEqual(newState.records[10], nil)
		guard let rekeyedRecord = newState.records[999] else {
			fail("rekeyed window 999 was not restored")
			return
		}
		expectEqual(rekeyedRecord.source, .restored)
		expectEqual(rekeyedRecord.placement, .tiled)
		expectEqual(rekeyedRecord.workspace, home)

		let restoredHome = newState.testActive("Main")
		expectEqual(newState.testColumns(restoredHome), [[999]])

		expectInvariants(newState)
	},

	TestCase("monitor missing at relaunch sends workspaces to remembered memory") {
		var state = testState([
			testDisplay("Main", primary: true),
			testDisplay("Ext", x: 1440, primary: false)
		])
		let mainWs = state.testActive("Main")
		state.testSetColumns(mainWs, [[10]])

		let extRow = state.testSetRow("Ext", negatives: 0, nonNegatives: 2, active: 1)
		state.testSetColumns(extRow[0], [[20]])
		state.testSetColumns(extRow[1], [[21]])
		expectInvariants(state)

		let snapshot = state.snapshot()

		var newState = testState([testDisplay("Main", primary: true)])
		let facts = [
			WindowFacts(id: 10, pid: 100, title: "W10"),
			WindowFacts(id: 20, pid: 100, title: "W20"),
			WindowFacts(id: 21, pid: 100, title: "W21")
		]
		newState.applyPersistence(snapshot, windows: facts, apps: [], now: 30.0)

		expectEqual(newState.monitors[extKey], nil)
		guard let mem = newState.memory[extKey] else {
			fail("missing monitor Ext was not saved into remembered memory")
			return
		}
		expectEqual(mem.order.count, 2)
		expectEqual(mem.active, extRow[1])

		let activeMainWs = newState.testActive("Main")
		expectEqual(newState.testColumns(activeMainWs), [[10]])
		expectEqual(newState.records[20], nil)
		expectEqual(newState.records[21], nil)

		expectInvariants(newState)
	},

	TestCase("unknown windows fall back to normal admission") {
		var state = testState([testDisplay("Main", primary: true)])
		let home = state.testActive("Main")
		state.testSetColumns(home, [[10]])
		expectInvariants(state)

		let snapshot = state.snapshot()

		var newState = testState([testDisplay("Main", primary: true)])
		let knownFacts = WindowFacts(id: 10, pid: 100, title: "W10")
		let unknownFacts = WindowFacts(
			id: 50,
			pid: 200,
			title: "Unknown",
			frame: CGRect(x: 100, y: 100, width: 800, height: 600)
		)
		let appKnown = AppFacts(pid: 100, bundleID: "com.known", name: "Known")
		let appUnknown = AppFacts(pid: 200, bundleID: "com.unknown", name: "Unknown")

		newState.applyPersistence(snapshot, windows: [knownFacts, unknownFacts], apps: [appKnown, appUnknown], now: 40.0)

		expectEqual(newState.records[10]?.source, .restored)
		expectEqual(newState.records[50], nil)

		let admittedID = newState.admit(unknownFacts, app: appUnknown, source: .startup, now: 41.0)
		expectEqual(admittedID, 50)
		guard let admittedRecord = newState.records[50] else {
			fail("unknown window 50 was not admitted")
			return
		}
		expectEqual(admittedRecord.source, .startup)
		expectEqual(admittedRecord.workspace, newState.testActive("Main"))

		expectInvariants(newState)
	},

	TestCase("stale window entries are dropped during restore") {
		var state = testState([testDisplay("Main", primary: true)])
		let home = state.testActive("Main")
		state.testSetColumns(home, [[10, 11], [12]])
		expectInvariants(state)

		let snapshot = state.snapshot()

		var newState = testState([testDisplay("Main", primary: true)])
		let liveFacts = [WindowFacts(id: 10, pid: 100, title: "W10")]
		newState.applyPersistence(snapshot, windows: liveFacts, apps: [], now: 50.0)

		expectEqual(newState.records[10]?.source, .restored)
		expectEqual(newState.records[11], nil)
		expectEqual(newState.records[12], nil)

		let restoredHome = newState.testActive("Main")
		expectEqual(newState.testColumns(restoredHome), [[10]])

		expectInvariants(newState)
	},

	TestCase("hidden stack entries are restored across relaunch") {
		var state = testState([testDisplay("Main", primary: true)])
		let home = state.testActive("Main")
		state.testSetColumns(home, [[10]])
		state.testAddWindow(11, placement: .tiled, workspace: home, visibility: .axisMinimized)
		state.hiddenStack = [HiddenEntry(window: 11, minimizeConfirmed: true)]
		expectInvariants(state)

		let snapshot = state.snapshot()

		var newState = testState([testDisplay("Main", primary: true)])
		let facts = [
			WindowFacts(id: 10, pid: 100, title: "W10"),
			WindowFacts(id: 11, pid: 100, title: "W11", isMinimized: true)
		]
		newState.applyPersistence(snapshot, windows: facts, apps: [], now: 60.0)

		expectEqual(newState.hiddenStack.map(\.window), [11])
		expectEqual(newState.records[11]?.visibility, .axisMinimized)
		expectEqual(newState.testColumns(newState.testActive("Main")), [[10]])

		expectInvariants(newState)
	}
]
