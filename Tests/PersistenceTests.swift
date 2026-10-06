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
		state.testAddWindow(15, workspace: row[1], pid: 105, title: "W15")
		state.testSetColumns(row[1], [[15]])
		expectInvariants(state)

		let snapshot = state.snapshot()

		var newState = testState([testDisplay("Main", primary: true)])
		let facts: [WindowFacts] = [
			WindowFacts(id: 10, pid: 101, title: "W10"),
			WindowFacts(id: 11, pid: 101, title: "W11"),
			WindowFacts(id: 12, pid: 102, title: "W12"),
			WindowFacts(id: 13, pid: 103, title: "W13"),
			WindowFacts(id: 14, pid: 104, title: "W14"),
			WindowFacts(id: 15, pid: 105, title: "W15")
		]
		let apps: [AppFacts] = [
			AppFacts(pid: 101, bundleID: "com.app.one", name: "One"),
			AppFacts(pid: 102, bundleID: "com.app.two", name: "Two"),
			AppFacts(pid: 103, bundleID: "com.app.three", name: "Three"),
			AppFacts(pid: 104, bundleID: "com.app.four", name: "Four"),
			AppFacts(pid: 105, bundleID: "com.app.five", name: "Five")
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
		expectEqual(newState.testColumns(newState.workspace(number: 0, on: mainKey)!), [[15]])

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
	},

	TestCase("saved workspace ids that equal the ids of this run's empty workspaces keep their monitors") {
		// First run: the external display was connected first, so it got the lower workspace id.
		var state = testState([testDisplay("Ext", x: 1440), testDisplay("Main", primary: true)])
		let extHome = state.testActive("Ext")
		let mainHome = state.testActive("Main")
		expect(extHome.raw < mainHome.raw, "the external display's workspace has the lower id")
		state.testSetColumns(extHome, [[20]])
		state.testSetColumns(mainHome, [[10]])
		expectInvariants(state)
		let snapshot = state.snapshot()

		// Relaunch: the displays come in the other order, so the new empty workspaces swap ids.
		var relaunched = testState([testDisplay("Main", primary: true), testDisplay("Ext", x: 1440)])
		let facts = [
			WindowFacts(id: 10, pid: 100, title: "W10"),
			WindowFacts(id: 20, pid: 100, title: "W20")
		]
		relaunched.applyPersistence(snapshot, windows: facts, apps: [], now: 10)

		expectEqual(relaunched.testColumns(relaunched.testActive("Main")), [[10]])
		expectEqual(relaunched.testColumns(relaunched.testActive("Ext")), [[20]])
		expectEqual(relaunched.records[10]?.workspace, mainHome)
		expectEqual(relaunched.records[20]?.workspace, extHome)
		expectInvariants(relaunched)
	},

	TestCase("a monitor connected only at relaunch keeps an empty workspace under a fresh id") {
		var state = testState([testDisplay("Main", primary: true)])
		let row = state.testSetRow("Main", negatives: 0, nonNegatives: 2, active: 0)
		state.testSetColumns(row[0], [[10]])
		state.testSetColumns(row[1], [[11]])
		expectInvariants(state)
		let snapshot = state.snapshot()

		// The new display's empty workspace would get an id the snapshot already uses for Main.
		var relaunched = testState([testDisplay("Main", primary: true), testDisplay("Ext", x: 1440)])
		let facts = [
			WindowFacts(id: 10, pid: 100, title: "W10"),
			WindowFacts(id: 11, pid: 100, title: "W11")
		]
		relaunched.applyPersistence(snapshot, windows: facts, apps: [], now: 10)

		expectEqual(relaunched.testRow("Main"), row)
		expectEqual(relaunched.testColumns(row[0]), [[10]])
		expectEqual(relaunched.testColumns(row[1]), [[11]])
		expectEqual(relaunched.testRow("Ext").count, 1)
		expect(!row.contains(relaunched.testActive("Ext")), "the new display's workspace has an unused id")
		expectEqual(relaunched.testColumns(relaunched.testActive("Ext")), [])
		expectInvariants(relaunched)
	},

	TestCase("a window whose app is hidden at relaunch leaves its column and returns to it with the app") {
		var state = testState()
		let home = state.testActive()
		state.testAddWindow(11, workspace: home, pid: 101)
		state.testSetColumns(home, [[10], [11], [12]])
		expectInvariants(state)
		let snapshot = state.snapshot()

		var relaunched = testState()
		let facts = [
			WindowFacts(id: 10, pid: 100, title: "W10"),
			WindowFacts(id: 11, pid: 101, title: "W11"),
			WindowFacts(id: 12, pid: 100, title: "W12")
		]
		let hiddenApps = [
			AppFacts(pid: 100, bundleID: "com.app.one", name: "One"),
			AppFacts(pid: 101, bundleID: "com.app.two", name: "Two", isHidden: true)
		]
		relaunched.applyPersistence(snapshot, windows: facts, apps: hiddenApps, now: 10)

		expectEqual(relaunched.records[11]?.visibility, .appHidden)
		expectEqual(relaunched.testColumns(relaunched.testActive()), [[10], [12]])
		expectEqual(relaunched.records[11]?.slotMemory?.leftRep, 10)
		expectInvariants(relaunched)

		relaunched.ingestApps([AppFacts(pid: 101, bundleID: "com.app.two", name: "Two", isHidden: false)], now: 20)
		relaunched.normalize(now: 20)
		expectEqual(relaunched.testColumns(relaunched.testActive()), [[10], [11], [12]])
		expectInvariants(relaunched)
	},

	TestCase("a window minimized when the layout was saved joins the columns by its centre when it is back") {
		var state = testState()
		let home = state.testActive()
		state.testSetColumns(home, [[10], [12]])
		state.testAddWindow(11, workspace: home, visibility: .nativeMinimized)
		expectInvariants(state)
		let snapshot = state.snapshot()

		var relaunched = testState()
		let facts = [
			WindowFacts(id: 10, pid: 100, title: "W10"),
			WindowFacts(id: 11, pid: 100, title: "W11", frame: CGRect(x: 600, y: 100, width: 200, height: 300)),
			WindowFacts(id: 12, pid: 100, title: "W12")
		]
		relaunched.applyPersistence(snapshot, windows: facts, apps: [], now: 10)

		expectEqual(relaunched.records[11]?.visibility, .visible)
		expectEqual(relaunched.testColumns(relaunched.testActive()), [[10], [11], [12]])
		expectInvariants(relaunched)
	},

	TestCase("saved tiled windows that no scan listed are tiled when they appear small") {
		var state = testState()
		let home = state.testActive()
		state.testSetColumns(home, [[10], [20]])
		expectInvariants(state)
		let snapshot = state.snapshot()

		// The app of window 20 is busy at relaunch: its windows are not listed yet.
		var relaunched = testState()
		relaunched.applyPersistence(snapshot, windows: [WindowFacts(id: 10, pid: 100, title: "W10")], apps: [], now: 10)
		expectEqual(relaunched.records[20], nil)

		// It answers later; a stacked column left the window smaller than a dialog.
		let small = WindowFacts(id: 20, pid: 200, title: "W20", frame: CGRect(x: 100, y: 100, width: 300, height: 200))
		let busyApp = AppFacts(pid: 200, bundleID: "com.busy.app", name: "Busy")
		relaunched.admit(small, app: busyApp, source: .discovered, now: 20)

		expectEqual(relaunched.records[20]?.placement, .tiled)
		expectEqual(relaunched.records[20]?.workspace, home)
		expectInvariants(relaunched)
	},

	TestCase("dialogs and helper windows are never restored from saved windows") {
		var state = testState()
		let home = state.testActive()
		state.testAddWindow(10, workspace: home, pid: 100, app: "TextEdit", title: "Notes")
		state.records[10]?.bundleID = "com.apple.TextEdit"
		state.testSetColumns(home, [[10]])
		expectInvariants(state)
		let snapshot = state.snapshot()

		var relaunched = testState()
		let dialog = WindowFacts(
			id: 77, pid: 300, subrole: AXNames.dialogSubrole, title: "Notes",
			frame: CGRect(x: 0, y: 0, width: 800, height: 600))
		let helper = WindowFacts(id: 10, pid: 100, role: "AXUnknown", subrole: nil, title: "Notes", hasCloseButton: false)
		let textEdit = [
			AppFacts(pid: 100, bundleID: "com.apple.TextEdit", name: "TextEdit"),
			AppFacts(pid: 300, bundleID: "com.apple.TextEdit", name: "TextEdit")
		]
		relaunched.applyPersistence(snapshot, windows: [dialog, helper], apps: textEdit, now: 10)

		expectEqual(relaunched.records.count, 0)
		expectInvariants(relaunched)
	},

	TestCase("windows without a title are never matched by bundle") {
		var state = testState()
		let home = state.testActive()
		state.testAddWindow(10, workspace: home, pid: 100, app: "App", title: "")
		state.records[10]?.bundleID = "com.test.app"
		state.testSetColumns(home, [[10]])
		let snapshot = state.snapshot()

		var relaunched = testState()
		let untitled = WindowFacts(id: 999, pid: 250, title: "", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
		relaunched.applyPersistence(snapshot, windows: [untitled], apps: [AppFacts(pid: 250, bundleID: "com.test.app", name: "App")], now: 10)

		expectEqual(relaunched.records.count, 0)
		expectInvariants(relaunched)
	},

	TestCase("equal titles are matched to the saved window with the closest frame") {
		var state = testState()
		let home = state.testActive()
		state.testAddWindow(10, workspace: home, pid: 100, app: "Terminal", title: "zsh", frame: CGRect(x: 0, y: 0, width: 600, height: 600))
		state.testAddWindow(11, workspace: home, pid: 100, app: "Terminal", title: "zsh", frame: CGRect(x: 800, y: 0, width: 600, height: 600))
		state.records[10]?.bundleID = "com.apple.Terminal"
		state.records[11]?.bundleID = "com.apple.Terminal"
		state.testSetColumns(home, [[10], [11]])
		expectInvariants(state)
		let snapshot = state.snapshot()

		// Only the window on the right is open after the reboot.
		var relaunched = testState()
		let right = WindowFacts(id: 500, pid: 400, title: "zsh", frame: CGRect(x: 820, y: 10, width: 600, height: 600))
		relaunched.applyPersistence(snapshot, windows: [right], apps: [AppFacts(pid: 400, bundleID: "com.apple.Terminal", name: "Terminal")], now: 10)

		expectEqual(relaunched.records[500]?.source, .restored)
		expectEqual(relaunched.testColumns(relaunched.testActive()), [[500]])
		expectInvariants(relaunched)
	},

	TestCase("workspaces left without windows are dropped at relaunch and the active one stays") {
		var state = testState()
		let row = state.testSetRow(nonNegatives: 3, active: 2)
		state.testSetColumns(row[0], [[10]])
		state.testSetColumns(row[1], [[11]])
		state.testSetColumns(row[2], [[12]])
		expectInvariants(state)
		let snapshot = state.snapshot()

		// Window 11 is gone: its workspace goes with it.
		var relaunched = testState()
		let facts = [
			WindowFacts(id: 10, pid: 100, title: "W10"),
			WindowFacts(id: 12, pid: 100, title: "W12")
		]
		relaunched.applyPersistence(snapshot, windows: facts, apps: [], now: 10)
		expectEqual(relaunched.testRow(), [row[0], row[2]])
		expectEqual(relaunched.testActive(), row[2])
		expectInvariants(relaunched)

		// Window 12 is gone too: the workspace it was shown on stays while it is the active one.
		var emptied = testState()
		emptied.applyPersistence(snapshot, windows: [WindowFacts(id: 10, pid: 100, title: "W10")], apps: [], now: 10)
		expectEqual(emptied.testRow(), [row[0], row[2]])
		expectEqual(emptied.testActive(), row[2])
		expectEqual(emptied.testColumns(row[2]), [])
		expectInvariants(emptied)
	},

	TestCase("restoring reports how many windows and workspaces came back") {
		var state = testState()
		let row = state.testSetRow(nonNegatives: 2, active: 0)
		state.testSetColumns(row[0], [[10], [11]])
		state.testSetColumns(row[1], [[12]])
		let snapshot = state.snapshot()

		var relaunched = testState()
		let facts = [
			WindowFacts(id: 10, pid: 100, title: "W10"),
			WindowFacts(id: 11, pid: 100, title: "W11"),
			WindowFacts(id: 12, pid: 100, title: "W12")
		]
		relaunched.applyPersistence(snapshot, windows: facts, apps: [], now: 10)

		let lines = relaunched.drainLog().map(\.message)
		expect(lines.contains("persist: restored 3 windows, 2 workspaces"), "log lines: \(lines)")
	},

	TestCase("a layout is not restored over windows that are already tracked") {
		var state = testState()
		let home = state.testActive()
		state.testSetColumns(home, [[10]])
		let snapshot = state.snapshot()

		var running = testState()
		running.testSetColumns(running.testActive(), [[50]])
		running.applyPersistence(snapshot, windows: [WindowFacts(id: 10, pid: 100, title: "W10")], apps: [], now: 10)

		expectEqual(running.records[10], nil)
		expectEqual(running.testColumns(running.testActive()), [[50]])
		let lines = running.drainLog().map(\.message)
		expect(lines.contains { $0.hasPrefix("persist: ignored") }, "log lines: \(lines)")
		expectInvariants(running)
	},

	TestCase("restoring from scans takes the windows every app listed") {
		var state = testState()
		let row = state.testSetRow(nonNegatives: 2, active: 0)
		state.testSetColumns(row[0], [[10]])
		state.testAddWindow(20, workspace: row[1], pid: 200)
		state.testSetColumns(row[1], [[20]])
		let snapshot = state.snapshot()

		var relaunched = testState()
		let scans: [PID: ScanResult] = [
			100: .complete([WindowFacts(id: 10, pid: 100, title: "W10")]),
			200: .incomplete([WindowFacts(id: 20, pid: 200, title: "W20")]),
			300: .timedOut
		]
		relaunched.applyPersistence(snapshot, scans: scans, apps: [], now: 10)

		expectEqual(relaunched.records[10]?.source, .restored)
		expectEqual(relaunched.records[20]?.source, .restored)
		expectEqual(relaunched.testColumns(row[0]), [[10]])
		expectEqual(relaunched.testColumns(row[1]), [[20]])
		expectInvariants(relaunched)
	},

	TestCase("a monitor another one adopted stays adopted across relaunch") {
		let main = testDisplay("Main", primary: true)
		var state = testState([main, testDisplay("Old", x: 1440)])
		state.testSetColumns(state.testActive("Old"), [[20]])
		// The old display is replaced by a new one, which takes over its workspaces.
		state.reconcileTopology([main, testDisplay("New", x: 1440)], now: 5)
		expectEqual(state.memory[testKey("Old")]?.adoptedBy, testKey("New"))
		expectInvariants(state)
		let snapshot = state.snapshot()
		expectEqual(snapshot.memory.first?.adoptedBy, testKey("New"))

		var relaunched = testState([main, testDisplay("New", x: 1440)])
		relaunched.applyPersistence(snapshot, windows: [WindowFacts(id: 20, pid: 100, title: "W20")], apps: [], now: 10)
		expectEqual(relaunched.memory[testKey("Old")]?.adoptedBy, testKey("New"))
		expectEqual(relaunched.testColumns(relaunched.testActive("New")), [[20]])

		// The old display returns: the new one keeps the workspaces, the old one starts empty.
		let change = relaunched.reconcileTopology([main, testDisplay("New", x: 1440), testDisplay("Old", x: 2880)], now: 20)
		expectEqual(change.restored, [])
		expectEqual(relaunched.testColumns(relaunched.testActive("New")), [[20]])
		expectEqual(relaunched.testColumns(relaunched.testActive("Old")), [])
		expectInvariants(relaunched)
	},

	TestCase("the layout right after a restore is the one that was loaded") {
		var state = testState()
		let row = state.testSetRow(nonNegatives: 2, active: 1)
		state.testSetColumns(row[0], [[10, 11]])
		state.testSetColumns(row[1], [[12]])
		let snapshot = state.snapshot()

		var relaunched = testState()
		let facts = [
			WindowFacts(id: 10, pid: 100, title: "W10"),
			WindowFacts(id: 11, pid: 100, title: "W11"),
			WindowFacts(id: 12, pid: 100, title: "W12")
		]
		relaunched.applyPersistence(snapshot, windows: facts, apps: [], now: 10)
		expectEqual(relaunched.persistenceTakeSnapshot(), nil)

		// A window gone since: the layout differs from the file's and is offered for writing.
		var shrunk = testState()
		shrunk.applyPersistence(snapshot, windows: Array(facts.prefix(2)), apps: [], now: 10)
		expect(shrunk.persistenceTakeSnapshot() != nil, "a changed layout is offered")
	},

	TestCase("a snapshot is offered once per layout change") {
		var state = testState()
		let home = state.testActive()
		state.testSetColumns(home, [[10], [11]])

		let first = state.persistenceTakeSnapshot()
		expect(first != nil, "the first layout is offered")
		expectEqual(state.persistenceTakeSnapshot(), nil)

		// A window moving between columns changes the layout.
		state.testSetColumns(home, [[10, 11]])
		let second = state.persistenceTakeSnapshot()
		expect(second != nil, "a new column layout is offered")
		expectEqual(state.persistenceTakeSnapshot(), nil)

		// A failed write offers the same layout again.
		state.persistenceNoteWriteFailed()
		expect(state.persistenceTakeSnapshot() != nil, "the layout is offered again after a failed write")
		expectEqual(state.persistenceTakeSnapshot(), nil)
	},

	TestCase("titles and observed frames alone do not count as a layout change") {
		var state = testState()
		let home = state.testActive()
		state.testSetColumns(home, [[10], [11]])
		_ = state.persistenceTakeSnapshot()

		state.records[10]?.title = "Another title"
		state.records[11]?.observed.frame = CGRect(x: 5, y: 5, width: 300, height: 300)
		expectEqual(state.persistenceTakeSnapshot(), nil)

		// Floating, the hidden stack and the ratios do count.
		state.records[11]?.placement = .floating
		state.workspaces[home]?.columns = [[10]]
		expect(state.persistenceTakeSnapshot() != nil, "a window that floats is offered")
		state.workspaces[home]?.widthRatios = [1.0]
		expect(state.persistenceTakeSnapshot() != nil, "a ratio change is offered")
		state.hiddenStack = [HiddenEntry(window: 10)]
		expect(state.persistenceTakeSnapshot() != nil, "a hidden window is offered")
	},

	TestCase("a snapshot taken from a consistent state validates") {
		var state = testState([testDisplay("Main", primary: true), testDisplay("Ext", x: 1440)])
		let row = state.testSetRow("Main", negatives: 1, nonNegatives: 2, active: 1)
		state.testSetColumns(row[0], [[10], [11, 12]])
		state.testSetColumns(row[2], [[13]])
		state.testSetColumns(state.testActive("Ext"), [[20]])
		expectInvariants(state)
		expectEqual(state.snapshot().validationProblem(), nil)
		expectEqual(testState().snapshot().validationProblem(), nil)
	},

	TestCase("inconsistent snapshots are reported") {
		var state = testState([testDisplay("Main", primary: true), testDisplay("Ext", x: 1440)])
		let row = state.testSetRow("Main", negatives: 0, nonNegatives: 2, active: 0)
		state.testSetColumns(row[0], [[10], [11]])
		state.testSetColumns(state.testActive("Ext"), [[20]])
		let good = state.snapshot()
		expectEqual(good.validationProblem(), nil)

		var twoColumns = good
		twoColumns.monitors[0].workspaces[1].columns = [[10]]
		expect(twoColumns.validationProblem() != nil, "a window in two columns")

		var sharedWorkspace = good
		sharedWorkspace.monitors[1].order = [row[0]]
		sharedWorkspace.monitors[1].active = row[0]
		sharedWorkspace.monitors[1].workspaces[0].id = row[0]
		expect(sharedWorkspace.validationProblem() != nil, "a workspace of two monitors")

		var badNegativeCount = good
		badNegativeCount.monitors[0].negativeCount = 2
		expect(badNegativeCount.validationProblem() != nil, "a negative count that leaves no home workspace")

		var strayActive = good
		strayActive.monitors[0].active = WorkspaceID(raw: 99)
		expect(strayActive.validationProblem() != nil, "an active workspace the monitor does not list")

		var missingWorkspace = good
		missingWorkspace.monitors[0].workspaces.removeLast()
		expect(missingWorkspace.validationProblem() != nil, "an ordered workspace without its saved columns")

		var emptyColumn = good
		emptyColumn.monitors[0].workspaces[0].columns = [[]]
		expect(emptyColumn.validationProblem() != nil, "an empty column")

		var twiceSaved = good
		twiceSaved.windows.append(twiceSaved.windows[0])
		expect(twiceSaved.validationProblem() != nil, "a window saved twice")

		var twiceListed = good
		twiceListed.monitors.append(twiceListed.monitors[0])
		expect(twiceListed.validationProblem() != nil, "a monitor listed twice")
	},

	TestCase("damaged data does not decode") {
		var state = testState()
		state.testSetColumns(state.testActive(), [[10], [11]])
		let data = try state.encodePersistence()

		let damaged: [String: Data] = [
			"empty": Data(),
			"not json": Data("not json".utf8),
			"truncated": data.prefix(data.count / 2),
			"wrong shape": Data("{\"monitors\": 3}".utf8),
			"missing keys": Data("{\"monitors\": [], \"windows\": []}".utf8)
		]
		for (name, bytes) in damaged {
			var decoded: PersistenceSnapshot?
			do {
				decoded = try TrackingState.decodePersistence(from: bytes)
			} catch {
				decoded = nil
			}
			expect(decoded == nil, "\(name) data decoded")
		}
	},

	TestCase("restoring random layouts across random relaunches keeps the state consistent") {
		var random = SeededGenerator(seed: 49)
		let names = ["A", "B", "C"]
		func randomFrame(_ random: inout SeededGenerator) -> CGRect {
			CGRect(
				x: CGFloat.random(in: 0..<1000, using: &random), y: CGFloat.random(in: 25..<500, using: &random),
				width: CGFloat.random(in: 200..<900, using: &random), height: CGFloat.random(in: 200..<900, using: &random))
		}

		for round in 0..<300 {
			// A first run: up to three displays, each with its own row of workspaces and windows.
			let displayCount = Int.random(in: 1...3, using: &random)
			var displays: [DisplayFacts] = []
			for index in 0..<displayCount {
				displays.append(testDisplay(names[index], x: CGFloat(index) * 1440, primary: index == 0, displayID: UInt32(index + 1)))
			}
			var state = testState(displays)
			var nextID: WindowID = 1
			func addWindow(_ state: inout TrackingState, in workspace: WorkspaceID, placement: Placement = .tiled,
				visibility: Visibility = .visible) -> WindowID {
				let id = nextID
				nextID += 1
				state.testAddWindow(id, placement: placement, workspace: workspace, visibility: visibility,
					pid: PID(100 + Int(id) % 3), title: "T\(id % 4)")
				state.records[id]?.bundleID = "com.test.app\(id % 3)"
				return id
			}
			for display in displays {
				let negatives = Int.random(in: 0...2, using: &random)
				let nonNegatives = Int.random(in: 1...3, using: &random)
				let row = state.testSetRow(display.name, negatives: negatives, nonNegatives: nonNegatives,
					active: Int.random(in: 0..<nonNegatives, using: &random))
				for workspace in row {
					var columns: [[WindowID]] = []
					for _ in 0..<Int.random(in: 0...3, using: &random) {
						columns.append((0..<Int.random(in: 1...2, using: &random)).map { _ in addWindow(&state, in: workspace) })
					}
					state.testSetColumns(workspace, columns)
					if Bool.random(using: &random) {
						let floating = addWindow(&state, in: workspace, placement: .floating)
						state.records[floating]?.floatingFrame = RelativeFrame(
							monitor: display.key, offset: CGPoint(x: 40, y: 40), size: CGSize(width: 400, height: 300))
					}
					if Int.random(in: 0..<3, using: &random) == 0 {
						_ = addWindow(&state, in: workspace, visibility: .nativeMinimized)
					}
					if Int.random(in: 0..<4, using: &random) == 0 {
						let hidden = addWindow(&state, in: workspace, visibility: .axisMinimized)
						state.hiddenStack.append(HiddenEntry(window: hidden, minimizeConfirmed: Bool.random(using: &random)))
					}
				}
			}
			expectInvariants(state, "round \(round) first run")
			let snapshot = state.snapshot()
			expectEqual(snapshot.validationProblem(), nil, "round \(round) snapshot")
			expectEqual(try TrackingState.decodePersistence(from: state.encodePersistence()), snapshot, "round \(round) round trip")

			// Relaunch: the displays that are connected now come in any order, one may be new.
			var pool = Array(names.prefix(displayCount)) + (Bool.random(using: &random) ? ["N"] : [])
			pool.shuffle(using: &random)
			var displays2: [DisplayFacts] = []
			for (index, name) in pool.prefix(Int.random(in: 1...pool.count, using: &random)).enumerated() {
				displays2.append(testDisplay(name, x: CGFloat(index) * 1440, primary: index == 0, displayID: UInt32(index + 1)))
			}
			var relaunched = testState(displays2)

			// Most windows are still open, some under a new id and process, some minimized, some new.
			var facts: [WindowFacts] = []
			for saved in snapshot.windows {
				switch Int.random(in: 0..<10, using: &random) {
				case 0:
					continue
				case 1:
					facts.append(WindowFacts(id: saved.id + 1000, pid: saved.pid + 51, title: saved.title, frame: randomFrame(&random)))
				default:
					facts.append(WindowFacts(id: saved.id, pid: saved.pid, title: saved.title, frame: randomFrame(&random),
						isMinimized: Int.random(in: 0..<12, using: &random) == 0))
				}
			}
			for index in 0..<Int.random(in: 0...3, using: &random) {
				facts.append(WindowFacts(id: 5000 + WindowID(index), pid: 100 + PID(index % 3), title: "New\(index)", frame: randomFrame(&random)))
			}
			var apps: [AppFacts] = []
			for pid in Set(facts.map(\.pid)).sorted() {
				apps.append(AppFacts(pid: pid, bundleID: "com.test.app\((Int(pid) - 100) % 3)", name: "App\(pid)",
					isHidden: Int.random(in: 0..<8, using: &random) == 0))
			}

			relaunched.applyPersistence(snapshot, windows: facts, apps: apps, now: 10)
			expectInvariants(relaunched, "round \(round) after the restore")
			for fact in facts where relaunched.records[fact.id] == nil {
				if let app = apps.first(where: { $0.pid == fact.pid }) {
					relaunched.admit(fact, app: app, source: .startup, now: 11)
				}
			}
			relaunched.normalize(now: 11)
			expectInvariants(relaunched, "round \(round) after the startup admission")

			// The layout saved from the relaunched run restores to itself.
			let next = relaunched.snapshot()
			expectEqual(next.validationProblem(), nil, "round \(round) second snapshot")
			var third = testState(displays2)
			var thirdFacts: [WindowFacts] = []
			for record in relaunched.records.values.sorted(by: { $0.id < $1.id }) {
				thirdFacts.append(WindowFacts(id: record.id, pid: record.pid, title: record.title,
					frame: record.observed.frame ?? .zero, isMinimized: record.observed.isMinimized))
			}
			let thirdApps = relaunched.apps.values.sorted(by: { $0.pid < $1.pid }).map {
				AppFacts(pid: $0.pid, bundleID: $0.bundleID, name: $0.name, isHidden: $0.isHidden)
			}
			third.applyPersistence(next, windows: thirdFacts, apps: thirdApps, now: 20)
			expectInvariants(third, "round \(round) third run")
			expect(third.snapshot().hasSameLayout(as: next), "round \(round): the restored layout differs from the saved one")
		}
	}
]
