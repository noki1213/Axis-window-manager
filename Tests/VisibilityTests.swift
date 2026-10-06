//
//  VisibilityTests.swift
//  Axis core tests
//
//  Visibility resolution, its transitions and the sessions that hide windows temporarily.
//

import Foundation
import CoreGraphics

private let main = testKey("Main")
private let secondary = testKey("Secondary")

let visibilityTests: [TestCase] = precedenceTests + transitionTests + dockRestoreTests + sessionTests + focusRuleTests

// MARK: - Precedence resolution

private let precedenceTests: [TestCase] = [
	TestCase("fullscreen takes precedence over minimized") {
		var state = testState()
		let ws = state.testActive()
		state.testAddWindow(1, workspace: ws)
		state.records[1]?.observed.isFullscreen = true
		state.records[1]?.observed.isMinimized = true
		expectEqual(state.resolveVisibility(state.records[1]!), .nativeFullscreen)
	},

	TestCase("fullscreen takes precedence over hidden stack") {
		var state = testState()
		let ws = state.testActive()
		state.testAddWindow(1, workspace: ws)
		state.records[1]?.observed.isFullscreen = true
		state.hiddenStack.append(HiddenEntry(window: 1))
		expectEqual(state.resolveVisibility(state.records[1]!), .nativeFullscreen)
	},

	TestCase("fullscreen takes precedence over app hidden") {
		var state = testState()
		let ws = state.testActive()
		state.testAddWindow(1, workspace: ws, pid: 200)
		state.apps[200] = AppState(pid: 200, isHidden: true)
		state.records[1]?.observed.isFullscreen = true
		expectEqual(state.resolveVisibility(state.records[1]!), .nativeFullscreen)
	},

	TestCase("fullscreen takes precedence over otherSpace facts") {
		var state = testState()
		let ws = state.testActive()
		state.testAddWindow(1, workspace: ws)
		state.records[1]?.observed.isFullscreen = true
		state.records[1]?.observed.listedInLastCompleteScan = false
		state.records[1]?.observed.serverHas = true
		state.records[1]?.observed.onScreen = false
		expectEqual(state.resolveVisibility(state.records[1]!), .nativeFullscreen)
	},

	TestCase("fullscreen takes precedence over inactive workspace") {
		var state = testState()
		let row = state.testSetRow("Main", negatives: 0, nonNegatives: 2, active: 0)
		let inactiveWs = row[1]
		state.testAddWindow(1, workspace: inactiveWs)
		state.records[1]?.observed.isFullscreen = true
		expectEqual(state.resolveVisibility(state.records[1]!), .nativeFullscreen)
	},

	TestCase("fullscreen takes precedence over palette session") {
		var state = testState()
		let ws = state.testActive()
		state.testAddWindow(1, workspace: ws)
		state.records[1]?.observed.isFullscreen = true
		state.paletteBegin(now: 0)
		expectEqual(state.resolveVisibility(state.records[1]!), .nativeFullscreen)
	},

	TestCase("fullscreen takes precedence over Zen session") {
		var state = testState()
		let ws = state.testActive()
		state.testAddWindow(1, workspace: ws)
		state.testAddWindow(2, workspace: ws)
		state.records[2]?.observed.isFullscreen = true
		state.zenEnter(1, now: 0)
		expectEqual(state.resolveVisibility(state.records[2]!), .nativeFullscreen)
	},

	TestCase("minimized window in hidden stack resolves to axisMinimized") {
		var state = testState()
		let ws = state.testActive()
		state.testAddWindow(1, workspace: ws)
		state.records[1]?.observed.isMinimized = true
		state.hiddenStack.append(HiddenEntry(window: 1))
		expectEqual(state.resolveVisibility(state.records[1]!), .axisMinimized)
	},

	TestCase("minimized window not in hidden stack resolves to nativeMinimized") {
		var state = testState()
		let ws = state.testActive()
		state.testAddWindow(1, workspace: ws)
		state.records[1]?.observed.isMinimized = true
		expectEqual(state.resolveVisibility(state.records[1]!), .nativeMinimized)
	},

	TestCase("hidden stack window not yet seen minimized resolves to axisMinimized") {
		var state = testState()
		let ws = state.testActive()
		state.testAddWindow(1, workspace: ws)
		state.records[1]?.observed.isMinimized = false
		state.hiddenStack.append(HiddenEntry(window: 1))
		expectEqual(state.resolveVisibility(state.records[1]!), .axisMinimized)
	},

	TestCase("hidden stack takes precedence over app hidden") {
		var state = testState()
		let ws = state.testActive()
		state.testAddWindow(1, workspace: ws, pid: 200)
		state.apps[200] = AppState(pid: 200, isHidden: true)
		state.hiddenStack.append(HiddenEntry(window: 1))
		expectEqual(state.resolveVisibility(state.records[1]!), .axisMinimized)
	},

	TestCase("hidden stack takes precedence over otherSpace facts") {
		var state = testState()
		let ws = state.testActive()
		state.testAddWindow(1, workspace: ws)
		state.records[1]?.observed.listedInLastCompleteScan = false
		state.records[1]?.observed.serverHas = true
		state.records[1]?.observed.onScreen = false
		state.hiddenStack.append(HiddenEntry(window: 1))
		expectEqual(state.resolveVisibility(state.records[1]!), .axisMinimized)
	},

	TestCase("hidden stack takes precedence over inactive workspace") {
		var state = testState()
		let row = state.testSetRow("Main", negatives: 0, nonNegatives: 2, active: 0)
		let inactiveWs = row[1]
		state.testAddWindow(1, workspace: inactiveWs)
		state.hiddenStack.append(HiddenEntry(window: 1))
		expectEqual(state.resolveVisibility(state.records[1]!), .axisMinimized)
	},

	TestCase("app hidden takes precedence over otherSpace facts") {
		var state = testState()
		let ws = state.testActive()
		state.testAddWindow(1, workspace: ws, pid: 200)
		state.apps[200] = AppState(pid: 200, isHidden: true)
		state.records[1]?.observed.listedInLastCompleteScan = false
		state.records[1]?.observed.serverHas = true
		state.records[1]?.observed.onScreen = false
		expectEqual(state.resolveVisibility(state.records[1]!), .appHidden)
	},

	TestCase("app hidden takes precedence over inactive workspace") {
		var state = testState()
		let row = state.testSetRow("Main", negatives: 0, nonNegatives: 2, active: 0)
		let inactiveWs = row[1]
		state.testAddWindow(1, workspace: inactiveWs, pid: 200)
		state.apps[200] = AppState(pid: 200, isHidden: true)
		expectEqual(state.resolveVisibility(state.records[1]!), .appHidden)
	},

	TestCase("app hidden takes precedence over palette session") {
		var state = testState()
		let ws = state.testActive()
		state.testAddWindow(1, workspace: ws, pid: 200)
		state.apps[200] = AppState(pid: 200, isHidden: true)
		state.paletteBegin(now: 0)
		expectEqual(state.resolveVisibility(state.records[1]!), .appHidden)
	},

	TestCase("app hidden takes precedence over Zen session") {
		var state = testState()
		let ws = state.testActive()
		state.testAddWindow(1, workspace: ws)
		state.testAddWindow(2, workspace: ws, pid: 200)
		state.apps[200] = AppState(pid: 200, isHidden: true)
		state.zenEnter(1, now: 0)
		expectEqual(state.resolveVisibility(state.records[2]!), .appHidden)
	},

	TestCase("otherSpace takes precedence over inactive workspace") {
		var state = testState()
		let row = state.testSetRow("Main", negatives: 0, nonNegatives: 2, active: 0)
		let inactiveWs = row[1]
		state.testAddWindow(1, workspace: inactiveWs)
		state.records[1]?.observed.listedInLastCompleteScan = false
		state.records[1]?.observed.serverHas = true
		state.records[1]?.observed.onScreen = false
		expectEqual(state.resolveVisibility(state.records[1]!), .otherSpace)
	},

	TestCase("otherSpace takes precedence over palette session") {
		var state = testState()
		let ws = state.testActive()
		state.testAddWindow(1, workspace: ws)
		state.records[1]?.observed.listedInLastCompleteScan = false
		state.records[1]?.observed.serverHas = true
		state.records[1]?.observed.onScreen = false
		state.paletteBegin(now: 0)
		expectEqual(state.resolveVisibility(state.records[1]!), .otherSpace)
	},

	TestCase("otherSpace takes precedence over Zen session") {
		var state = testState()
		let ws = state.testActive()
		state.testAddWindow(1, workspace: ws)
		state.testAddWindow(2, workspace: ws)
		state.records[2]?.observed.listedInLastCompleteScan = false
		state.records[2]?.observed.serverHas = true
		state.records[2]?.observed.onScreen = false
		state.zenEnter(1, now: 0)
		expectEqual(state.resolveVisibility(state.records[2]!), .otherSpace)
	},

	TestCase("inactive workspace takes precedence over palette session") {
		var state = testState()
		let row = state.testSetRow("Main", negatives: 0, nonNegatives: 2, active: 0)
		let inactiveWs = row[1]
		state.testAddWindow(1, workspace: inactiveWs)
		state.paletteBegin(now: 0)
		expectEqual(state.resolveVisibility(state.records[1]!), .parked(.workspaceInactive))
	},

	TestCase("palette session takes precedence over Zen session") {
		var state = testState()
		let ws = state.testActive()
		state.testAddWindow(1, workspace: ws)
		state.zenEnter(1, now: 0)
		state.paletteBegin(now: 1)
		expectEqual(state.resolveVisibility(state.records[1]!), .paletteHidden)
	},

	TestCase("Zen session hides other members in its workspace") {
		var state = testState()
		let ws = state.testActive()
		state.testAddWindow(1, workspace: ws)
		state.testAddWindow(2, workspace: ws)
		state.zenEnter(1, now: 0)
		expectEqual(state.resolveVisibility(state.records[1]!), .visible)
		expectEqual(state.resolveVisibility(state.records[2]!), .zenHidden)
	},

	TestCase("unmanaged window on Zen monitor is untouched") {
		var state = testState()
		let ws = state.testActive()
		state.testAddWindow(1, workspace: ws)
		state.testAddWindow(2, placement: .unmanaged, workspace: nil, frame: CGRect(x: 100, y: 100, width: 200, height: 200))
		state.zenEnter(1, now: 0)
		expectEqual(state.resolveVisibility(state.records[2]!), .visible)
	},

	TestCase("default window in active workspace resolves to visible") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])
		expectEqual(state.resolveVisibility(state.records[1]!), .visible)
		state.normalize(now: 0)
		expectInvariants(state)
	},
]

// MARK: - Transitions and normalization

private let transitionTests: [TestCase] = [
	TestCase("visible to parked keeps columns and logs transition") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1], [2]])
		expectEqual(state.records[1]?.visibility, .visible)

		let row = state.testSetRow("Main", negatives: 0, nonNegatives: 2, active: 1)
		state.workspaces[row[0]] = Workspace(id: row[0], host: main, columns: [[1], [2]])
		state.records[1]?.workspace = row[0]
		state.records[2]?.workspace = row[0]

		state.normalize(now: 0)
		expectEqual(state.records[1]?.visibility, .parked(.workspaceInactive))
		expectEqual(state.records[2]?.visibility, .parked(.workspaceInactive))
		expectEqual(state.workspaces[row[0]]?.columns, [[1], [2]])
		expect(state.log.contains { $0.message.contains("visible -> parked(workspaceInactive)") })
		expectInvariants(state)
	},

	TestCase("parked to visible sets pendingFloatRestore for floating window") {
		var state = testState()
		let row = state.testSetRow("Main", negatives: 0, nonNegatives: 2, active: 1)
		let inactiveWs = row[0]
		state.testAddWindow(1, placement: .floating, workspace: inactiveWs, visibility: .parked(.workspaceInactive))
		expectEqual(state.records[1]?.pendingFloatRestore, false)

		state.switchWorkspace(on: main, to: .id(inactiveWs))
		state.normalize(now: 0)
		expectEqual(state.records[1]?.visibility, .visible)
		expectEqual(state.records[1]?.pendingFloatRestore, true)
		expectInvariants(state)
	},

	TestCase("visible to zenHidden keeps columns and logs transition") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1], [2]])
		state.normalize(now: 0)

		state.zenEnter(1, now: 0)
		state.normalize(now: 1)
		expectEqual(state.records[1]?.visibility, .visible)
		expectEqual(state.records[2]?.visibility, .zenHidden)
		expectEqual(state.workspaces[ws]?.columns, [[1], [2]])
		expect(state.log.contains { $0.message.contains("visible -> zenHidden") })
		expectInvariants(state)
	},

	TestCase("zenHidden to visible sets pendingFloatRestore for floating window") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])
		state.testAddWindow(2, placement: .floating, workspace: ws, visibility: .visible)
		state.zenEnter(1, now: 0)
		state.normalize(now: 1)
		expectEqual(state.records[2]?.visibility, .zenHidden)
		state.records[2]?.pendingFloatRestore = false

		state.zenExit(reason: .user)
		state.normalize(now: 2)
		expectEqual(state.records[2]?.visibility, .visible)
		expectEqual(state.records[2]?.pendingFloatRestore, true)
		expectInvariants(state)
	},

	TestCase("visible to paletteHidden keeps columns") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1], [2]])
		state.normalize(now: 0)

		state.paletteBegin(now: 1)
		state.normalize(now: 2)
		expectEqual(state.records[1]?.visibility, .paletteHidden)
		expectEqual(state.records[2]?.visibility, .paletteHidden)
		expectEqual(state.workspaces[ws]?.columns, [[1], [2]])
		expectInvariants(state)
	},

	TestCase("paletteHidden to visible sets pendingFloatRestore for floating window") {
		var state = testState()
		let ws = state.testActive()
		state.testAddWindow(1, placement: .floating, workspace: ws, visibility: .paletteHidden)
		state.palette = PaletteSession(startedAt: 0)
		state.records[1]?.pendingFloatRestore = false

		state.paletteEnd()
		state.normalize(now: 1)
		expectEqual(state.records[1]?.visibility, .visible)
		expectEqual(state.records[1]?.pendingFloatRestore, true)
		expectInvariants(state)
	},

	TestCase("between parked and paletteHidden leaves columns unchanged") {
		var state = testState()
		let row = state.testSetRow("Main", negatives: 0, nonNegatives: 2, active: 0)
		let inactiveWs = row[1]
		state.workspaces[inactiveWs]?.columns = [[1], [2]]
		state.testAddWindow(1, workspace: inactiveWs, visibility: .parked(.workspaceInactive))
		state.testAddWindow(2, workspace: inactiveWs, visibility: .parked(.workspaceInactive))

		state.paletteBegin(now: 0)
		state.normalize(now: 1)
		// Inactive workspace has higher precedence than palette, so it remains parked.
		expectEqual(state.records[1]?.visibility, .parked(.workspaceInactive))
		expectEqual(state.workspaces[inactiveWs]?.columns, [[1], [2]])
		expectInvariants(state)
	},

	TestCase("keepsSlot to axisMinimized removes window with slot memory") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1], [2], [3]])
		state.normalize(now: 0)

		state.hide(2)
		state.normalize(now: 1)
		expectEqual(state.records[2]?.visibility, .axisMinimized)
		expectEqual(state.workspaces[ws]?.columns, [[1], [3]])
		expectEqual(state.records[2]?.slotMemory?.leftRep, 1)
		expectEqual(state.records[2]?.slotMemory?.rightRep, 3)
		expectEqual(state.records[2]?.slotMemory?.workspace, ws)
		expectInvariants(state)
	},

	TestCase("keepsSlot to nativeMinimized removes window with slot memory") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1], [2], [3]])
		state.normalize(now: 0)

		state.records[2]?.observed.isMinimized = true
		state.normalize(now: 1)
		expectEqual(state.records[2]?.visibility, .nativeMinimized)
		expectEqual(state.workspaces[ws]?.columns, [[1], [3]])
		expectEqual(state.records[2]?.slotMemory?.leftRep, 1)
		expectEqual(state.records[2]?.slotMemory?.rightRep, 3)
		expectInvariants(state)
	},

	TestCase("keepsSlot to nativeFullscreen removes window with slot memory") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1], [2]])
		state.normalize(now: 0)

		state.records[1]?.observed.isFullscreen = true
		state.normalize(now: 1)
		expectEqual(state.records[1]?.visibility, .nativeFullscreen)
		expectEqual(state.workspaces[ws]?.columns, [[2]])
		expectEqual(state.records[1]?.slotMemory?.rightRep, 2)
		expectInvariants(state)
	},

	TestCase("keepsSlot to appHidden removes window with slot memory") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1], [2]], pid: 200)
		state.apps[200] = AppState(pid: 200, isHidden: false)
		state.normalize(now: 0)

		state.apps[200]?.isHidden = true
		state.normalize(now: 1)
		expectEqual(state.records[1]?.visibility, .appHidden)
		expectEqual(state.records[2]?.visibility, .appHidden)
		expectEqual(state.workspaces[ws]?.columns, [])
		expectInvariants(state)
	},

	TestCase("keepsSlot to otherSpace keeps window in columns") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1], [2]])
		state.normalize(now: 0)

		state.records[2]?.observed.listedInLastCompleteScan = false
		state.records[2]?.observed.serverHas = true
		state.records[2]?.observed.onScreen = false
		state.normalize(now: 1)
		expectEqual(state.records[2]?.visibility, .otherSpace)
		expectEqual(state.workspaces[ws]?.columns, [[1], [2]])
		expectInvariants(state)
	},

	TestCase("reinsert by slot memory restores window next to remembered neighbours") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1], [2], [3]])
		state.normalize(now: 0)

		state.hide(2)
		state.normalize(now: 1)
		expectEqual(state.workspaces[ws]?.columns, [[1], [3]])

		state.unhideLast()
		state.normalize(now: 2)
		expectEqual(state.records[2]?.visibility, .visible)
		expectEqual(state.workspaces[ws]?.columns, [[1], [2], [3]])
		expectEqual(state.records[2]?.slotMemory, nil)
		expectInvariants(state)
	},

	TestCase("reinsert falls back to midX when remembered neighbours are gone") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1], [2], [3]])
		state.normalize(now: 0)

		state.hide(2)
		state.normalize(now: 1)
		expectEqual(state.workspaces[ws]?.columns, [[1], [3]])

		state.retire(1, reason: .destroyed, now: 2)
		state.retire(3, reason: .destroyed, now: 2)
		state.testAddWindow(4, workspace: ws, frame: CGRect(x: 0, y: 0, width: 600, height: 800))
		state.workspaces[ws]?.columns = [[4]]

		state.records[2]?.observed.frame = CGRect(x: 700, y: 0, width: 600, height: 800)
		state.unhideLast()
		state.normalize(now: 3)
		expectEqual(state.records[2]?.visibility, .visible)
		expectEqual(state.workspaces[ws]?.columns, [[4], [2]])
		expectEqual(state.records[2]?.slotMemory, nil)
		expectInvariants(state)
	},

	TestCase("fullscreenRoundTrip keeps otherSpace desktop windows in place and restores slots") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1], [2]])
		state.normalize(now: 0)

		// Window 1 enters native fullscreen.
		state.records[1]?.observed.isFullscreen = true
		state.normalize(now: 1)
		expectEqual(state.records[1]?.visibility, .nativeFullscreen)
		expectEqual(state.workspaces[ws]?.columns, [[2]])

		// In fullscreen Space, desktop window 2 turns otherSpace.
		state.records[2]?.observed.listedInLastCompleteScan = false
		state.records[2]?.observed.serverHas = true
		state.records[2]?.observed.onScreen = false
		state.normalize(now: 2)
		expectEqual(state.records[2]?.visibility, .otherSpace)
		expectEqual(state.workspaces[ws]?.columns, [[2]])

		// Exit fullscreen back to desktop Space.
		state.records[2]?.observed.listedInLastCompleteScan = true
		state.records[2]?.observed.onScreen = true
		state.records[1]?.observed.isFullscreen = false
		state.normalize(now: 3)
		expectEqual(state.records[2]?.visibility, .visible)
		expectEqual(state.records[1]?.visibility, .visible)
		expectEqual(state.workspaces[ws]?.columns, [[1], [2]])
		expectInvariants(state)
	},

	TestCase("fullscreen exit when workspace became inactive returns window parked") {
		var state = testState()
		let row = state.testSetRow("Main", negatives: 0, nonNegatives: 2, active: 0)
		let ws1 = row[0]
		let ws2 = row[1]
		state.workspaces[ws1]?.columns = [[1], [2]]
		state.testAddWindow(1, workspace: ws1)
		state.testAddWindow(2, workspace: ws1)
		state.normalize(now: 0)

		state.records[1]?.observed.isFullscreen = true
		state.normalize(now: 1)
		expectEqual(state.workspaces[ws1]?.columns, [[2]])

		// Switch workspace while window 1 is in fullscreen.
		state.switchWorkspace(on: main, to: .id(ws2))
		state.normalize(now: 2)
		expectEqual(state.records[2]?.visibility, .parked(.workspaceInactive))

		// Window 1 exits fullscreen.
		state.records[1]?.observed.isFullscreen = false
		state.normalize(now: 3)
		expectEqual(state.records[1]?.visibility, .parked(.workspaceInactive))
		expectEqual(state.workspaces[ws1]?.columns, [[1], [2]])
		expectInvariants(state)
	},

	TestCase("hideRoundTrip pushes to stack, minimizes and restores") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1], [2], [3]])
		state.normalize(now: 0)

		state.hide(2)
		state.normalize(now: 1)
		expectEqual(state.records[2]?.visibility, .axisMinimized)
		expectEqual(state.workspaces[ws]?.columns, [[1], [3]])

		state.unhideLast()
		state.normalize(now: 2)
		expectEqual(state.records[2]?.visibility, .visible)
		expectEqual(state.workspaces[ws]?.columns, [[1], [2], [3]])
		expectInvariants(state)
	},
]

// MARK: - Dock restore and hide stack

private let dockRestoreTests: [TestCase] = [
	TestCase("dockRestoreRule restores window when unminimized after confirmation") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1], [2], [3]])
		state.normalize(now: 0)

		state.hide(2)
		state.normalize(now: 1)
		expectEqual(state.hiddenStack.first?.minimizeConfirmed, false)

		// System confirms window is minimized.
		state.records[2]?.observed.isMinimized = true
		state.normalize(now: 2)
		expectEqual(state.hiddenStack.first?.minimizeConfirmed, true)

		// User clicks Dock icon to restore.
		state.records[2]?.observed.isMinimized = false
		state.normalize(now: 3)
		expectEqual(state.hiddenStack.isEmpty, true)
		expectEqual(state.records[2]?.visibility, .visible)
		expectEqual(state.workspaces[ws]?.columns, [[1], [2], [3]])
		expectInvariants(state)
	},

	TestCase("dockRestoreRule does not restore prematurely before minimize confirmation") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1], [2]])
		state.normalize(now: 0)

		state.hide(2)
		// Window has not been seen minimized yet.
		state.records[2]?.observed.isMinimized = false
		state.normalize(now: 1)
		expectEqual(state.hiddenStack.count, 1)
		expectEqual(state.records[2]?.visibility, .axisMinimized)
		expectInvariants(state)
	},

	TestCase("dockRestoreRule sets pendingFloatRestore for floating window") {
		var state = testState()
		let ws = state.testActive()
		state.testAddWindow(1, placement: .floating, workspace: ws)
		state.normalize(now: 0)

		state.hide(1)
		state.normalize(now: 1)
		state.records[1]?.observed.isMinimized = true
		state.normalize(now: 2)

		state.records[1]?.observed.isMinimized = false
		state.normalize(now: 3)
		expectEqual(state.records[1]?.visibility, .visible)
		expectEqual(state.records[1]?.pendingFloatRestore, true)
		expectEqual(state.hiddenStack.isEmpty, true)
		expectInvariants(state)
	},

	TestCase("native minimized window unminimized from Dock is not affected by hidden stack") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1], [2]])
		state.normalize(now: 0)

		state.records[1]?.observed.isMinimized = true
		state.normalize(now: 1)
		expectEqual(state.records[1]?.visibility, .nativeMinimized)
		expectEqual(state.workspaces[ws]?.columns, [[2]])

		state.records[1]?.observed.isMinimized = false
		state.normalize(now: 2)
		expectEqual(state.records[1]?.visibility, .visible)
		expectEqual(state.workspaces[ws]?.columns, [[1], [2]])
		expectEqual(state.hiddenStack.isEmpty, true)
		expectInvariants(state)
	},
]

// MARK: - Sessions (Zen, palette)

private let sessionTests: [TestCase] = [
	TestCase("zenExit clears session and emits user reason") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])
		state.zenEnter(1, now: 0)
		expect(state.zen != nil)

		state.zenExit(reason: .user)
		expectEqual(state.zen, nil)
		expect(state.events.contains { $0 == .zenEnded(.user) })
		expect(state.log.contains { $0.message == "zen: exit (user)" })
		expectInvariants(state)
	},

	TestCase("zenExit sends a floating Zen window back to its floating frame, a tiled one to its slot") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])
		state.testAddWindow(2, placement: .floating, workspace: ws)
		state.zenEnter(2, now: 0)
		state.zenExit(reason: .user)
		expectEqual(state.records[2]?.pendingFloatRestore, true)

		state.zenEnter(1, now: 1)
		state.zenExit(reason: .user)
		expectEqual(state.records[1]?.pendingFloatRestore, false)
		expectInvariants(state)
	},

	TestCase("zenExit on workspace switch ends Zen") {
		var state = testState()
		let row = state.testSetRow("Main", negatives: 0, nonNegatives: 2, active: 0)
		state.testSetColumns(row[0], [[1]])
		state.zenEnter(1, now: 0)

		state.switchWorkspace(on: main, to: .id(row[1]))
		expectEqual(state.zen, nil)
		expect(state.events.contains { $0 == .zenEnded(.workspaceSwitched) })
		expectInvariants(state)
	},

	TestCase("paletteBegin ends Zen with paletteOpened") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])
		state.zenEnter(1, now: 0)

		state.paletteBegin(now: 1)
		expectEqual(state.zen, nil)
		expect(state.events.contains { $0 == .zenEnded(.paletteOpened) })
		expectEqual(state.palette?.startedAt, 1)
		expectInvariants(state)
	},

	TestCase("the palette takes managed windows out of sight and leaves unmanaged ones where they are") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])
		state.testAddWindow(2, placement: .floating, workspace: ws)
		state.testAddWindow(3, placement: .unmanaged, workspace: nil)
		state.normalize(now: 0)
		state.records[2]?.pendingFloatRestore = false
		_ = state.drainLog()

		state.paletteBegin(now: 1)
		state.normalize(now: 2)
		expectEqual(state.records[1]?.visibility, .paletteHidden)
		expectEqual(state.records[2]?.visibility, .paletteHidden)
		expectEqual(state.records[3]?.visibility, .visible)
		expect(!state.log.contains { $0.message.contains("#3") }, "\(state.log)")

		state.paletteEnd()
		state.normalize(now: 3)
		expectEqual(state.records[1]?.visibility, .visible)
		expectEqual(state.records[2]?.visibility, .visible)
		expectEqual(state.records[2]?.pendingFloatRestore, true)
		// It never left, so there is nothing to put back.
		expectEqual(state.records[3]?.visibility, .visible)
		expectEqual(state.records[3]?.pendingFloatRestore, false)
		expectInvariants(state)
	},

	TestCase("layoutReset ends Zen") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1, 2]])
		state.zenEnter(1, now: 0)

		state.resetToSingleColumns(ws)
		expectEqual(state.zen, nil)
		expect(state.events.contains { $0 == .zenEnded(.layoutReset) })
		expectInvariants(state)
	},

	TestCase("zenFocusCloses ends Zen with focusClosed") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1], [2]])
		state.normalize(now: 0)
		state.zenEnter(1, now: 1)

		state.retire(1, reason: .destroyed, now: 2)
		expectEqual(state.zen, nil)
		expect(state.events.contains { $0 == .zenEnded(.focusClosed) })
		expectInvariants(state)
	},

	TestCase("zenExitsWhenHiddenWindowCloses ends Zen with hiddenClosed") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1], [2]])
		state.normalize(now: 0)
		state.zenEnter(1, now: 1)
		state.normalize(now: 2)
		expectEqual(state.records[2]?.visibility, .zenHidden)

		state.retire(2, reason: .destroyed, now: 3)
		expectEqual(state.zen, nil)
		expect(state.events.contains { $0 == .zenEnded(.hiddenClosed) })
		expectInvariants(state)
	},

	TestCase("zenExit when tiled window admitted into zen workspace") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])
		state.zenEnter(1, now: 0)

		state.testSetColumns(ws, [[1], [2]])
		state.zenNoteAdmission(state.records[2]!)
		expectEqual(state.zen, nil)
		expect(state.events.contains { $0 == .zenEnded(.tiledAdmitted) })
		expectInvariants(state)
	},

	TestCase("zenSurvivesLock barrier without exiting") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])
		state.zenEnter(1, now: 0)

		state.setBarrier(.locked, active: true, now: 1)
		expect(state.zen != nil)
		state.setBarrier(.locked, active: false, now: 2)
		expect(state.zen != nil)
		expectInvariants(state)
	},

	TestCase("zenSurvivesSleep and missionControl barriers") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])
		state.zenEnter(1, now: 0)

		state.setBarrier(.asleep, active: true, now: 1)
		expect(state.zen != nil)
		state.setBarrier(.missionControl, active: true, now: 2)
		expect(state.zen != nil)
		expectInvariants(state)
	},

	TestCase("zenIgnoresOtherMonitorChanges on secondary display") {
		var state = testState([testDisplay("Main", primary: true), testDisplay("Secondary", x: 1440, displayID: 2)])
		let mainWs = state.testActive("Main")
		let secWs = state.testActive("Secondary")
		state.testSetColumns(mainWs, [[1]])
		state.testSetColumns(secWs, [[2]])
		state.zenEnter(1, now: 0)

		state.retire(2, reason: .destroyed, now: 1)
		expect(state.zen != nil)
		expectInvariants(state)
	},

	TestCase("zenKeepsForFloatingAdmission into Zen workspace") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])
		state.zenEnter(1, now: 0)

		state.testAddWindow(2, placement: .floating, workspace: ws)
		state.zenNoteAdmission(state.records[2]!)
		expect(state.zen != nil)
		expectInvariants(state)
	},

	TestCase("zenKeepsForUnmanagedAdmission") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])
		state.zenEnter(1, now: 0)

		state.testAddWindow(2, placement: .unmanaged, workspace: nil)
		state.zenNoteAdmission(state.records[2]!)
		expect(state.zen != nil)
		expectInvariants(state)
	},

	TestCase("zenKeepsForAdmissionIntoDifferentWorkspace") {
		var state = testState()
		let row = state.testSetRow("Main", negatives: 0, nonNegatives: 2, active: 0)
		let ws1 = row[0]
		let ws2 = row[1]
		state.testSetColumns(ws1, [[1]])
		state.zenEnter(1, now: 0)

		state.testSetColumns(ws2, [[2]])
		state.zenNoteAdmission(state.records[2]!)
		expect(state.zen != nil)
		expectInvariants(state)
	},

	TestCase("zenAdjustWidth adjusts ratio and clamps to valid range") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])
		state.zenEnter(1, now: 0)
		expectEqual(state.zen?.widthRatio, 0.75)

		state.zenAdjustWidth(increase: true)
		expectEqual(state.zen!.widthRatio, 0.80, accuracy: 0.001)

		state.zenAdjustWidth(increase: false)
		expectEqual(state.zen!.widthRatio, 0.75, accuracy: 0.001)

		for _ in 0..<20 { state.zenAdjustWidth(increase: true) }
		expectEqual(state.zen!.widthRatio, 1.0, accuracy: 0.001)

		for _ in 0..<30 { state.zenAdjustWidth(increase: false) }
		expectEqual(state.zen!.widthRatio, 0.1, accuracy: 0.001)
		expectInvariants(state)
	},

	TestCase("zenEnter on unmanaged window uses frame center to find monitor") {
		var state = testState()
		state.testAddWindow(1, placement: .unmanaged, workspace: nil,
			frame: CGRect(x: 200, y: 200, width: 400, height: 300))
		let entered = state.zenEnter(1, now: 0)
		expectEqual(entered, true)
		expectEqual(state.zen?.monitor, main)
		expectEqual(state.zen?.focus, 1)
		expectInvariants(state)
	},

	TestCase("paletteRoundTrip restores visibility from model without pixel capture") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1], [2]])
		state.testAddWindow(3, placement: .floating, workspace: ws)
		state.normalize(now: 0)

		state.paletteBegin(now: 1)
		state.normalize(now: 2)
		expectEqual(state.records[1]?.visibility, .paletteHidden)
		expectEqual(state.records[2]?.visibility, .paletteHidden)
		expectEqual(state.records[3]?.visibility, .paletteHidden)

		state.paletteEnd()
		state.normalize(now: 3)
		expectEqual(state.records[1]?.visibility, .visible)
		expectEqual(state.records[2]?.visibility, .visible)
		expectEqual(state.records[3]?.visibility, .visible)
		expectEqual(state.records[3]?.pendingFloatRestore, true)
		expectEqual(state.workspaces[ws]?.columns, [[1], [2]])
		expectInvariants(state)
	},
]

// MARK: - Focus rules

private let focusRuleTests: [TestCase] = [
	TestCase("focus change to another workspace waits for settle delay") {
		var state = testState()
		let row = state.testSetRow("Main", negatives: 0, nonNegatives: 2, active: 0)
		state.testSetColumns(row[0], [[1]])
		state.testSetColumns(row[1], [[2]])
		state.normalize(now: 0)

		let context = FollowContext(focused: 2, previous: 1, changedAt: 10.0)
		let decision = FocusRules.followDecision(context, in: state, now: 10.1)
		expectEqual(decision, .wait(until: 10.3))
	},

	TestCase("focus change follows after settle delay has elapsed") {
		var state = testState()
		let row = state.testSetRow("Main", negatives: 0, nonNegatives: 2, active: 0)
		state.testSetColumns(row[0], [[1]])
		state.testSetColumns(row[1], [[2]])
		state.normalize(now: 0)

		let context = FollowContext(focused: 2, previous: 1, changedAt: 10.0)
		let decision = FocusRules.followDecision(context, in: state, now: 10.3)
		expectEqual(decision, .follow(window: 2, workspace: row[1]))
	},

	TestCase("focus change within the same active workspace stays immediately") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1], [2]])
		state.normalize(now: 0)

		let context = FollowContext(focused: 2, previous: 1, changedAt: 10.0)
		let decision = FocusRules.followDecision(context, in: state, now: 10.0)
		expectEqual(decision, .stay)
	},

	TestCase("focus change to unmanaged window stays without following") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])
		state.testAddWindow(2, placement: .unmanaged, workspace: nil)
		state.normalize(now: 0)

		let context = FollowContext(focused: 2, previous: 1, changedAt: 10.0)
		let decision = FocusRules.followDecision(context, in: state, now: 10.5)
		expectEqual(decision, .stay)
	},

	TestCase("closeHandoff chooses same monitor tile first after settle delay") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1], [2]])
		state.normalize(now: 0)
		state.retire(1, reason: .destroyed, now: 10.0)

		let context = FollowContext(focused: nil, previous: 1, changedAt: 10.0, previousMonitor: main)
		// Before settle delay: waits.
		expectEqual(FocusRules.followDecision(context, in: state, now: 10.1), .wait(until: 10.3))
		// After settle delay: focuses adjacent tile on same monitor.
		expectEqual(FocusRules.followDecision(context, in: state, now: 10.3), .focus(2))
	},

	TestCase("closeHandoff falls back to window under mouse when same monitor has no tiles") {
		var state = testState([testDisplay("Main", primary: true), testDisplay("Secondary", x: 1440, displayID: 2)])
		let mainWs = state.testActive("Main")
		let secWs = state.testActive("Secondary")
		state.testSetColumns(mainWs, [[1]])
		state.testSetColumns(secWs, [[2], [3]])
		state.normalize(now: 0)
		state.retire(1, reason: .destroyed, now: 10.0)

		let context = FollowContext(focused: nil, previous: 1, changedAt: 10.0,
			windowUnderMouse: 3, previousMonitor: main)
		let decision = FocusRules.followDecision(context, in: state, now: 10.3)
		expectEqual(decision, .focus(3))
	},

	TestCase("closeHandoff falls back to first tile across monitors when mouse is empty") {
		var state = testState([testDisplay("Main", primary: true), testDisplay("Secondary", x: 1440, displayID: 2)])
		let mainWs = state.testActive("Main")
		let secWs = state.testActive("Secondary")
		state.testSetColumns(mainWs, [[1]])
		state.testSetColumns(secWs, [[2]])
		state.normalize(now: 0)
		state.retire(1, reason: .destroyed, now: 10.0)

		let context = FollowContext(focused: nil, previous: 1, changedAt: 10.0,
			windowUnderMouse: nil, previousMonitor: main)
		let decision = FocusRules.followDecision(context, in: state, now: 10.3)
		expectEqual(decision, .focus(2))
	},

	TestCase("a window is focusable while its app answers") {
		var state = testState()
		let ws = state.testActive()
		state.testAddWindow(1, workspace: ws, pid: 100)
		state.testAddWindow(2, placement: .unmanaged, workspace: nil, pid: 200)
		expect(state.isFocusable(1))
		expect(state.isFocusable(2))
		expect(!state.isFocusable(99), "an untracked window is not a focus target")

		state.apps[100] = AppState(pid: 100, name: "Busy", unresponsiveSince: 5)
		expect(!state.isFocusable(1))
		expect(state.isFocusable(2))

		// The app answers a scan again.
		state.ingestScan(pid: 100, result: .complete([WindowFacts(id: 1, pid: 100, title: "W1")]), serverHas: [1], now: 6)
		expect(state.isFocusable(1))
	},

	TestCase("closeHandoff passes over tiles of apps that do not answer and focuses nothing when none answers") {
		var state = testState()
		let ws = state.testActive()
		state.testAddWindow(1, workspace: ws, pid: 100)
		state.testAddWindow(2, workspace: ws, pid: 200, app: "Busy")
		state.testAddWindow(3, workspace: ws, pid: 300)
		state.workspaces[ws]?.columns = [[1], [2], [3]]
		state.normalize(now: 0)
		state.apps[200] = AppState(pid: 200, name: "Busy", unresponsiveSince: 5)
		state.retire(1, reason: .destroyed, now: 10.0)

		let context = FollowContext(focused: nil, previous: 1, changedAt: 10.0, previousMonitor: main)
		expectEqual(FocusRules.followDecision(context, in: state, now: 10.3), .focus(3))

		state.apps[300] = AppState(pid: 300, name: "Also busy", unresponsiveSince: 6)
		expectEqual(FocusRules.followDecision(context, in: state, now: 10.3), .stay)
	},

	TestCase("closeHandoff does not hand focus to the window under the mouse when its app does not answer") {
		var state = testState()
		let ws = state.testActive()
		state.testAddWindow(1, workspace: ws, pid: 100)
		state.testAddWindow(2, placement: .floating, workspace: ws, pid: 200, app: "Busy")
		state.workspaces[ws]?.columns = [[1]]
		state.normalize(now: 0)
		state.apps[200] = AppState(pid: 200, name: "Busy", unresponsiveSince: 5)
		state.retire(1, reason: .destroyed, now: 10.0)

		let context = FollowContext(focused: nil, previous: 1, changedAt: 10.0, windowUnderMouse: 2)
		expectEqual(FocusRules.followDecision(context, in: state, now: 10.3), .stay)
	},

	TestCase("zenFocusCloses suppresses follow decision") {
		var state = testState()
		let row = state.testSetRow("Main", negatives: 0, nonNegatives: 2, active: 0)
		state.testSetColumns(row[0], [[1]])
		state.testSetColumns(row[1], [[2]])
		state.normalize(now: 0)
		state.zenEnter(1, now: 0)
		state.retire(1, reason: .destroyed, now: 10.0)

		let context = FollowContext(focused: 2, previous: 1, changedAt: 10.0, zenClosed: true)
		let decision = FocusRules.followDecision(context, in: state, now: 10.3)
		expectEqual(decision, .stay)
	},

	TestCase("switchToEmpty suppresses follow back to previous workspace") {
		var state = testState()
		let row = state.testSetRow("Main", negatives: 0, nonNegatives: 2, active: 0)
		state.testSetColumns(row[0], [[1]])
		// Switch to empty workspace 1.
		state.switchWorkspace(on: main, to: .id(row[1]))
		state.normalize(now: 0)

		// macOS leaves focus on window 1 in parked workspace 0.
		let context = FollowContext(focused: 1, previous: 1, changedAt: 10.0)
		let decision = FocusRules.followDecision(context, in: state, now: 10.5)
		expectEqual(decision, .stay)
	},

	TestCase("focus moved to another window while on empty workspace follows") {
		var state = testState()
		let row = state.testSetRow("Main", negatives: 0, nonNegatives: 3, active: 0)
		state.testSetColumns(row[0], [[1]])
		state.testSetColumns(row[2], [[2]])
		// Switch to empty workspace 1.
		state.switchWorkspace(on: main, to: .id(row[1]))
		state.normalize(now: 0)

		// Focus moved to window 2 on workspace 2 via Dock/Cmd+Tab.
		let context = FollowContext(focused: 2, previous: 1, changedAt: 10.0)
		let decision = FocusRules.followDecision(context, in: state, now: 10.5)
		expectEqual(decision, .follow(window: 2, workspace: row[2]))
	},

	TestCase("closeHandoff prefers window under mouse when previous monitor is nil") {
		var state = testState([testDisplay("Main", primary: true), testDisplay("Secondary", x: 1440, displayID: 2)])
		let mainWs = state.testActive("Main")
		let secWs = state.testActive("Secondary")
		state.testSetColumns(mainWs, [[1], [4]])
		state.testSetColumns(secWs, [[2], [3]])
		state.normalize(now: 0)
		state.retire(1, reason: .destroyed, now: 10.0)

		// When previous monitor is nil, window under mouse is preferred over other monitor tiles.
		let context = FollowContext(focused: nil, previous: 1, changedAt: 10.0,
			windowUnderMouse: 3, previousMonitor: nil)
		let decision = FocusRules.followDecision(context, in: state, now: 10.3)
		expectEqual(decision, .focus(3))
	},

	TestCase("launchAside holds focus until deadline") {
		var state = testState()
		let row = state.testSetRow("Main", negatives: 0, nonNegatives: 2, active: 0)
		state.testSetColumns(row[0], [[1]])
		state.testSetColumns(row[1], [[2]], bundleID: "com.test.aside")
		state.records[2]?.bundleID = "com.test.aside"
		state.launchAside["com.test.aside"] = LaunchAsideEntry(bundleID: "com.test.aside", monitor: main,
			deadline: 30.0, workspace: row[1], holdFocusUntil: 20.0)
		state.normalize(now: 0)

		let context = FollowContext(focused: 2, previous: 1, changedAt: 10.0)
		// While hold is active: stay.
		expectEqual(FocusRules.followDecision(context, in: state, now: 15.0), .stay)
		// After hold expired: follow.
		expectEqual(FocusRules.followDecision(context, in: state, now: 21.0), .follow(window: 2, workspace: row[1]))
	},
]

private extension TrackingState {
	mutating func testSetColumns(_ workspace: WorkspaceID, _ columns: [[WindowID]], pid: PID) {
		for id in columns.joined() where records[id] == nil {
			testAddWindow(id, workspace: workspace, pid: pid)
		}
		workspaces[workspace]!.columns = columns
	}

	mutating func testSetColumns(_ workspace: WorkspaceID, _ columns: [[WindowID]], bundleID: String) {
		for id in columns.joined() where records[id] == nil {
			testAddWindow(id, workspace: workspace)
			records[id]?.bundleID = bundleID
		}
		workspaces[workspace]!.columns = columns
	}
}
