//
//  AdmissionTests.swift
//  Axis core tests
//
//  Window classification, placement ladder precedence, replacement pairing,
//  launch-aside claim and expiry, and reservation consumption.
//

import Foundation
import CoreGraphics

private let mainKey = testKey("Main")
private let externalKey = testKey("External")

let admissionTests: [TestCase] = classifierTests
	+ placementLadderTests
	+ ladderPrecedenceTests
	+ launchAsideTests
	+ reservationTests
	+ rescueFrameTests
	+ zenAdmissionTests
	+ replacementPairingTests

// MARK: - Window classification

private let classifierTests: [TestCase] = [
	TestCase("own process id is ignored") {
		let facts = WindowFacts(id: 1, pid: 999, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole)
		let result = Classifier.classify(facts, bundleID: "com.test.app", ownPID: 999, relaunchTiled: [])
		expectEqual(result, .ignore)
	},

	TestCase("non window role element is ignored") {
		let facts = WindowFacts(id: 1, pid: 100, role: "AXButton", subrole: AXNames.standardWindowSubrole)
		let result = Classifier.classify(facts, bundleID: "com.test.app", ownPID: 999, relaunchTiled: [])
		expectEqual(result, .ignore)
	},

	TestCase("helper window without standard subrole and without close button is ignored") {
		let facts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: "AXUnknown",
			frame: CGRect(x: 0, y: 0, width: 1, height: 1), hasCloseButton: false)
		let result = Classifier.classify(facts, bundleID: "com.test.app", ownPID: 999, relaunchTiled: [])
		expectEqual(result, .ignore)
	},

	TestCase("document window with close button and non standard subrole is classified as tiled") {
		let facts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: "AXUnknown",
			frame: CGRect(x: 100, y: 100, width: 800, height: 600), hasCloseButton: true)
		let result = Classifier.classify(facts, bundleID: "com.test.office", ownPID: 999, relaunchTiled: [])
		expectEqual(result, .tiled)
	},

	TestCase("standard window subrole with close button is classified as tiled") {
		let facts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 800, height: 600), hasCloseButton: true)
		let result = Classifier.classify(facts, bundleID: "com.test.app", ownPID: 999, relaunchTiled: [])
		expectEqual(result, .tiled)
	},

	TestCase("standard window subrole without close button is classified as tiled") {
		let facts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 800, height: 600), hasCloseButton: false)
		let result = Classifier.classify(facts, bundleID: "com.test.app", ownPID: 999, relaunchTiled: [])
		expectEqual(result, .tiled)
	},

	TestCase("dialog and floating subroles are classified as unmanaged") {
		let dialogFacts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.dialogSubrole,
			frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		let systemDialogFacts = WindowFacts(
			id: 2, pid: 100, role: AXNames.windowRole, subrole: AXNames.systemDialogSubrole,
			frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		let floatingFacts = WindowFacts(
			id: 3, pid: 100, role: AXNames.windowRole, subrole: AXNames.floatingWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 800, height: 600))

		expectEqual(Classifier.classify(dialogFacts, bundleID: "com.test.app", ownPID: 999, relaunchTiled: []), .unmanaged)
		expectEqual(Classifier.classify(systemDialogFacts, bundleID: "com.test.app", ownPID: 999, relaunchTiled: []), .unmanaged)
		expectEqual(Classifier.classify(floatingFacts, bundleID: "com.test.app", ownPID: 999, relaunchTiled: []), .unmanaged)
	},

	TestCase("system settings bundle identifiers are classified as unmanaged") {
		let bundleIDs = [
			"com.apple.systempreferences",
			"com.apple.SystemPreferences",
			"com.apple.systemsettings",
			"com.apple.SystemSettings",
		]
		for bundleID in bundleIDs {
			let facts = WindowFacts(
				id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
				frame: CGRect(x: 100, y: 100, width: 800, height: 600))
			let result = Classifier.classify(facts, bundleID: bundleID, ownPID: 999, relaunchTiled: [])
			expectEqual(result, .unmanaged)
		}
	},

	TestCase("small window under threshold is classified as unmanaged unless previously tiled") {
		let smallFacts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 499, height: 499))
		let result = Classifier.classify(smallFacts, bundleID: "com.test.app", ownPID: 999, relaunchTiled: [])
		expectEqual(result, .unmanaged)
	},

	TestCase("relaunch tiled exception preserves tiled classification for small windows") {
		let smallFacts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 499, height: 499))
		let result = Classifier.classify(smallFacts, bundleID: "com.test.app", ownPID: 999, relaunchTiled: [1])
		expectEqual(result, .tiled)
	},

	TestCase("window at or above threshold is classified as tiled") {
		let facts1 = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 500, height: 499))
		let facts2 = WindowFacts(
			id: 2, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 499, height: 500))
		let facts3 = WindowFacts(
			id: 3, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 500, height: 500))

		expectEqual(Classifier.classify(facts1, bundleID: "com.test.app", ownPID: 999, relaunchTiled: []), .tiled)
		expectEqual(Classifier.classify(facts2, bundleID: "com.test.app", ownPID: 999, relaunchTiled: []), .tiled)
		expectEqual(Classifier.classify(facts3, bundleID: "com.test.app", ownPID: 999, relaunchTiled: []), .tiled)
	},

	TestCase("minimized or fullscreen flags at admission do not alter window classification") {
		let minimizedFacts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 800, height: 600), isMinimized: true)
		let fullscreenFacts = WindowFacts(
			id: 2, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 800, height: 600), isFullscreen: true)

		expectEqual(Classifier.classify(minimizedFacts, bundleID: "com.test.app", ownPID: 999, relaunchTiled: []), .tiled)
		expectEqual(Classifier.classify(fullscreenFacts, bundleID: "com.test.app", ownPID: 999, relaunchTiled: []), .tiled)
	},

	TestCase("tracked window classification is evaluated once at admission and never reclassified") {
		var state = testState()
		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "TestApp")
		let initialFacts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			title: "Doc", frame: CGRect(x: 100, y: 100, width: 800, height: 600), takenAt: 10.0)

		state.admit(initialFacts, app: app, source: .created, now: 10.0)
		expectEqual(state.records[1]?.placement, .tiled)

		// Later layout or user action shrinks window into small size.
		let updatedFacts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			title: "Doc", frame: CGRect(x: 100, y: 100, width: 300, height: 300), takenAt: 11.0)
		state.ingestWindowFacts([updatedFacts], now: 11.0)

		expectEqual(state.records[1]?.placement, .tiled)
		expectInvariants(state)
	},
]

// MARK: - Placement ladder steps

private let placementLadderTests: [TestCase] = [
	TestCase("step 7 fallback places discovered window in active workspace of monitor containing its center") {
		let display1 = testDisplay("Main", x: 0, y: 0, width: 1440, height: 900, primary: true, displayID: 1)
		let display2 = testDisplay("External", x: 1440, y: 0, width: 1920, height: 1080, primary: false, displayID: 2)
		var state = testState([display1, display2])
		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "TestApp")

		let facts1 = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 600, height: 500))
		state.admit(facts1, app: app, source: .discovered, now: 10.0)
		expectEqual(state.records[1]?.workspace, state.testActive("Main"))

		let facts2 = WindowFacts(
			id: 2, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 1600, y: 100, width: 600, height: 500))
		state.admit(facts2, app: app, source: .discovered, now: 10.0)
		expectEqual(state.records[2]?.workspace, state.testActive("External"))
		expectInvariants(state)
	},

	TestCase("step 7 fallback places window off screen on nearest or primary monitor active workspace") {
		var state = testState()
		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "TestApp")
		let facts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: -3000, y: -3000, width: 600, height: 500))

		state.admit(facts, app: app, source: .discovered, now: 10.0)
		expectEqual(state.records[1]?.workspace, state.testActive("Main"))
		expectInvariants(state)
	},

	TestCase("step 6 focus monitor places created window in active workspace of last tracked monitor") {
		let display1 = testDisplay("Main", x: 0, y: 0, width: 1440, height: 900, primary: true, displayID: 1)
		let display2 = testDisplay("External", x: 1440, y: 0, width: 1920, height: 1080, primary: false, displayID: 2)
		var state = testState([display1, display2])
		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "TestApp")

		// Last focused tracked window was on external monitor.
		state.focus.lastTrackedMonitor = externalKey

		// Created window arrives with physical frame on Main.
		let facts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 600, height: 500))
		state.admit(facts, app: app, source: .created, now: 10.0)

		expectEqual(state.records[1]?.workspace, state.testActive("External"))
		expectInvariants(state)
	},

	TestCase("step 5 reservation places created tiled window into specified column of reservation monitor") {
		let display1 = testDisplay("Main", x: 0, y: 0, width: 1440, height: 900, primary: true, displayID: 1)
		let display2 = testDisplay("External", x: 1440, y: 0, width: 1920, height: 1080, primary: false, displayID: 2)
		var state = testState([display1, display2])
		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "TestApp")
		let wsExt = state.testActive("External")
		state.testSetColumns(wsExt, [[99]])

		state.setReservation(PlacementReservation(kind: .newColumnRight, monitor: externalKey, columnIndex: 0))

		let facts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 600, height: 500))
		state.admit(facts, app: app, source: .created, now: 10.0)

		expectEqual(state.records[1]?.workspace, wsExt)
		expectEqual(state.records[1]?.placement, .tiled)
		expectEqual(state.testColumns(wsExt), [[99], [1]])
		expectEqual(state.reservation, nil)
		expectInvariants(state)
	},

	TestCase("step 5 reservation places created float window as floating centered on reservation monitor") {
		let display1 = testDisplay("Main", x: 0, y: 0, width: 1440, height: 900, primary: true, displayID: 1)
		let display2 = testDisplay("External", x: 1440, y: 0, width: 1920, height: 1080, primary: false, displayID: 2)
		var state = testState([display1, display2])
		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "TestApp")
		let wsExt = state.testActive("External")

		state.setReservation(PlacementReservation(kind: .float, monitor: externalKey, columnIndex: 0))

		let facts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 600, height: 500))
		state.admit(facts, app: app, source: .created, now: 10.0)

		expectEqual(state.records[1]?.workspace, wsExt)
		expectEqual(state.records[1]?.placement, .floating)
		expectEqual(state.records[1]?.pendingFloatRestore, true)
		expect(state.records[1]?.floatingFrame != nil)
		expectEqual(state.reservation, nil)
		expectInvariants(state)
	},

	TestCase("step 4 unmanaged class window receives unmanaged placement without workspace") {
		var state = testState()
		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "TestApp")
		let facts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.dialogSubrole,
			frame: CGRect(x: 200, y: 200, width: 400, height: 300))

		state.admit(facts, app: app, source: .created, now: 10.0)

		expectEqual(state.records[1]?.placement, .unmanaged)
		expectEqual(state.records[1]?.workspace, nil)
		expect(state.records[1]?.floatingFrame != nil)
		expectInvariants(state)
	},

	TestCase("step 3 launch aside places window in dedicated workspace at end of target monitor") {
		let display1 = testDisplay("Main", x: 0, y: 0, width: 1440, height: 900, primary: true, displayID: 1)
		let display2 = testDisplay("External", x: 1440, y: 0, width: 1920, height: 1080, primary: false, displayID: 2)
		var state = testState([display1, display2])
		let app = AppFacts(pid: 100, bundleID: "com.aside.app", name: "AsideApp")

		state.registerLaunchAside(bundleID: "com.aside.app", monitor: externalKey, now: 10.0)

		let facts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		state.admit(facts, app: app, source: .created, now: 10.5)

		guard let ws = state.records[1]?.workspace else {
			fail("window must be placed into a workspace")
			return
		}
		expectEqual(state.workspaces[ws]?.host, externalKey)
		expect(ws != state.testActive("External"), "must be placed in a newly created workspace")
		expectEqual(state.records[1]?.placement, .tiled)
		expect(state.events.contains(.returnFocus(bundleID: "com.aside.app")))
		expectInvariants(state)
	},

	TestCase("step 3 launch aside places unmanaged class window as floating in launch aside workspace") {
		var state = testState()
		let app = AppFacts(pid: 100, bundleID: "com.aside.app", name: "AsideApp")

		state.registerLaunchAside(bundleID: "com.aside.app", monitor: mainKey, now: 10.0)

		let facts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.dialogSubrole,
			frame: CGRect(x: 100, y: 100, width: 400, height: 300))
		state.admit(facts, app: app, source: .created, now: 10.5)

		expectEqual(state.records[1]?.placement, .floating)
		expect(state.records[1]?.workspace != nil, "unmanaged class becomes floating in launch-aside workspace")
		expectInvariants(state)
	},

	TestCase("step 1 replacement window replaces retired window in its original workspace and slot") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[10, 20]])

		state.retire(10, reason: .destroyed, now: 10.0)

		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "App")
		let newFacts = WindowFacts(
			id: 30, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			title: "W10", frame: CGRect(x: 100, y: 100, width: 700, height: 500))

		let admittedID = state.admit(newFacts, app: app, source: .created, now: 11.0)

		expectEqual(admittedID, 30)
		expectEqual(state.records[30]?.workspace, ws)
		expectEqual(state.records[30]?.placement, .tiled)
		expectEqual(state.testColumns(ws), [[30, 20]])
		expect(state.events.contains(.rekeyed(from: 10, to: 30)))
		expectInvariants(state)
	},
]

// MARK: - Placement ladder precedence

private let ladderPrecedenceTests: [TestCase] = [
	TestCase("replacement takes precedence over launch aside claim") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[10]])

		state.retire(10, reason: .destroyed, now: 10.0)
		state.registerLaunchAside(bundleID: "com.test.app", monitor: mainKey, now: 10.5)

		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "App")
		let newFacts = WindowFacts(
			id: 20, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			title: "W10", frame: CGRect(x: 100, y: 100, width: 700, height: 500))

		state.admit(newFacts, app: app, source: .created, now: 11.0)

		expectEqual(state.records[20]?.workspace, ws)
		expectEqual(state.testColumns(ws), [[20]])
		expect(state.events.contains(.rekeyed(from: 10, to: 20)))
		expectInvariants(state)
	},

	TestCase("replacement takes precedence over placement reservation") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[10]])

		state.retire(10, reason: .destroyed, now: 10.0)
		state.setReservation(PlacementReservation(kind: .float, monitor: mainKey, columnIndex: 0))

		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "App")
		let newFacts = WindowFacts(
			id: 20, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			title: "W10", frame: CGRect(x: 100, y: 100, width: 700, height: 500))

		state.admit(newFacts, app: app, source: .created, now: 11.0)

		expectEqual(state.records[20]?.workspace, ws)
		expectEqual(state.records[20]?.placement, .tiled)
		expectEqual(state.reservation != nil, true, "reservation must remain unconsumed")
		expectInvariants(state)
	},

	TestCase("launch aside claim takes precedence over unmanaged class placement") {
		var state = testState()
		let app = AppFacts(pid: 100, bundleID: "com.aside.app", name: "AsideApp")

		state.registerLaunchAside(bundleID: "com.aside.app", monitor: mainKey, now: 10.0)

		let facts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.dialogSubrole,
			frame: CGRect(x: 100, y: 100, width: 400, height: 300))
		state.admit(facts, app: app, source: .created, now: 10.5)

		expectEqual(state.records[1]?.placement, .floating)
		expect(state.records[1]?.workspace != nil, "unmanaged window claimed into launch-aside workspace")
		expectInvariants(state)
	},

	TestCase("launch aside claim takes precedence over placement reservation") {
		let display1 = testDisplay("Main", x: 0, y: 0, width: 1440, height: 900, primary: true, displayID: 1)
		let display2 = testDisplay("External", x: 1440, y: 0, width: 1920, height: 1080, primary: false, displayID: 2)
		var state = testState([display1, display2])
		let app = AppFacts(pid: 100, bundleID: "com.aside.app", name: "AsideApp")

		state.registerLaunchAside(bundleID: "com.aside.app", monitor: externalKey, now: 10.0)
		state.setReservation(PlacementReservation(kind: .float, monitor: mainKey, columnIndex: 0))

		let facts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		state.admit(facts, app: app, source: .created, now: 10.5)

		expectEqual(state.workspaces[state.records[1]!.workspace!]?.host, externalKey)
		expectEqual(state.reservation != nil, true, "reservation must not be consumed by launch-aside window")
		expectInvariants(state)
	},

	TestCase("launch aside claim takes precedence over focus monitor placement") {
		let display1 = testDisplay("Main", x: 0, y: 0, width: 1440, height: 900, primary: true, displayID: 1)
		let display2 = testDisplay("External", x: 1440, y: 0, width: 1920, height: 1080, primary: false, displayID: 2)
		var state = testState([display1, display2])
		let app = AppFacts(pid: 100, bundleID: "com.aside.app", name: "AsideApp")

		state.focus.lastTrackedMonitor = mainKey
		state.registerLaunchAside(bundleID: "com.aside.app", monitor: externalKey, now: 10.0)

		let facts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		state.admit(facts, app: app, source: .created, now: 10.5)

		expectEqual(state.workspaces[state.records[1]!.workspace!]?.host, externalKey)
		expectInvariants(state)
	},

	TestCase("unmanaged class placement takes precedence over reservation and leaves reservation intact") {
		var state = testState()
		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "TestApp")

		state.setReservation(PlacementReservation(kind: .newColumnRight, monitor: mainKey, columnIndex: 0))

		let dialogFacts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.dialogSubrole,
			frame: CGRect(x: 100, y: 100, width: 400, height: 300))
		state.admit(dialogFacts, app: app, source: .created, now: 10.0)

		expectEqual(state.records[1]?.placement, .unmanaged)
		expectEqual(state.records[1]?.workspace, nil)
		expect(state.reservation != nil, "reservation must remain intact for tiled windows")
		expectInvariants(state)
	},

	TestCase("unmanaged class placement takes precedence over focus monitor placement") {
		let display1 = testDisplay("Main", x: 0, y: 0, width: 1440, height: 900, primary: true, displayID: 1)
		let display2 = testDisplay("External", x: 1440, y: 0, width: 1920, height: 1080, primary: false, displayID: 2)
		var state = testState([display1, display2])
		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "TestApp")

		state.focus.lastTrackedMonitor = externalKey

		let dialogFacts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.dialogSubrole,
			frame: CGRect(x: 100, y: 100, width: 400, height: 300))
		state.admit(dialogFacts, app: app, source: .created, now: 10.0)

		expectEqual(state.records[1]?.placement, .unmanaged)
		expectEqual(state.records[1]?.workspace, nil)
		expectInvariants(state)
	},

	TestCase("placement reservation takes precedence over focus monitor placement") {
		let display1 = testDisplay("Main", x: 0, y: 0, width: 1440, height: 900, primary: true, displayID: 1)
		let display2 = testDisplay("External", x: 1440, y: 0, width: 1920, height: 1080, primary: false, displayID: 2)
		var state = testState([display1, display2])
		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "TestApp")

		state.focus.lastTrackedMonitor = mainKey
		state.setReservation(PlacementReservation(kind: .newColumnRight, monitor: externalKey, columnIndex: 0))

		let facts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		state.admit(facts, app: app, source: .created, now: 10.0)

		expectEqual(state.records[1]?.workspace, state.testActive("External"))
		expectEqual(state.reservation, nil)
		expectInvariants(state)
	},

	TestCase("focus monitor placement takes precedence over position placement for created windows") {
		let display1 = testDisplay("Main", x: 0, y: 0, width: 1440, height: 900, primary: true, displayID: 1)
		let display2 = testDisplay("External", x: 1440, y: 0, width: 1920, height: 1080, primary: false, displayID: 2)
		var state = testState([display1, display2])
		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "TestApp")

		state.focus.lastTrackedMonitor = externalKey

		// Frame is physically placed on Main screen, but source is .created.
		let facts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 200, y: 200, width: 600, height: 500))
		state.admit(facts, app: app, source: .created, now: 10.0)

		expectEqual(state.records[1]?.workspace, state.testActive("External"))
		expectInvariants(state)
	},
]

// MARK: - Launch aside

private let launchAsideTests: [TestCase] = [
	TestCase("first claimed window creates new workspace at end and extends deadline by following window wait") {
		var state = testState()
		let app = AppFacts(pid: 100, bundleID: "com.aside.app", name: "AsideApp")

		state.registerLaunchAside(bundleID: "com.aside.app", monitor: mainKey, now: 10.0)
		expectEqual(state.launchAside["com.aside.app"]?.deadline, 10.0 + AdmissionTiming.launchAsideFirstWindowWait)

		let facts1 = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		state.admit(facts1, app: app, source: .created, now: 15.0)

		let entry = state.launchAside["com.aside.app"]
		expectEqual(entry?.deadline, 15.0 + AdmissionTiming.launchAsideFollowingWindowWait)
		expectEqual(entry?.holdFocusUntil, 15.0 + AdmissionTiming.launchAsideFocusHold)
		expectInvariants(state)
	},

	TestCase("following window within wait period is claimed into same launch aside workspace") {
		var state = testState()
		let app = AppFacts(pid: 100, bundleID: "com.aside.app", name: "AsideApp")

		state.registerLaunchAside(bundleID: "com.aside.app", monitor: mainKey, now: 10.0)

		let facts1 = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		state.admit(facts1, app: app, source: .created, now: 15.0)
		let ws1 = state.records[1]?.workspace

		let facts2 = WindowFacts(
			id: 2, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 200, y: 200, width: 800, height: 600))
		state.admit(facts2, app: app, source: .created, now: 20.0)
		let ws2 = state.records[2]?.workspace

		expectEqual(ws1, ws2)
		expectInvariants(state)
	},

	TestCase("launch aside window sets hold focus and frontmost change emits return focus") {
		var state = testState()
		let app = AppFacts(pid: 100, bundleID: "com.aside.app", name: "AsideApp")

		state.registerLaunchAside(bundleID: "com.aside.app", monitor: mainKey, now: 10.0)

		let facts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		state.admit(facts, app: app, source: .created, now: 10.0)
		state.events = []

		// App activates itself during focus hold period.
		let focusFacts = FocusFacts(frontmostPID: 100, frontmostBundleID: "com.aside.app", focused: 1)
		state.ingestFocus(focusFacts, now: 11.0)

		expect(state.events.contains(.returnFocus(bundleID: "com.aside.app")))
		expectInvariants(state)
	},

	TestCase("focus arrival after hold period does not emit return focus") {
		var state = testState()
		let app = AppFacts(pid: 100, bundleID: "com.aside.app", name: "AsideApp")

		state.registerLaunchAside(bundleID: "com.aside.app", monitor: mainKey, now: 10.0)

		let facts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		state.admit(facts, app: app, source: .created, now: 10.0)
		state.events = []

		// Focus arrives after hold period (hold is 3 seconds).
		let focusFacts = FocusFacts(frontmostPID: 100, frontmostBundleID: "com.aside.app", focused: 1)
		state.ingestFocus(focusFacts, now: 14.0)

		expect(!state.events.contains(.returnFocus(bundleID: "com.aside.app")))
		expectInvariants(state)
	},

	TestCase("expired launch aside registration does not claim windows") {
		var state = testState()
		let app = AppFacts(pid: 100, bundleID: "com.aside.app", name: "AsideApp")

		state.registerLaunchAside(bundleID: "com.aside.app", monitor: mainKey, now: 10.0)

		// Time advances well past launch-aside deadline (300 s).
		let facts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		state.admit(facts, app: app, source: .created, now: 350.0)

		expectEqual(state.launchAside["com.aside.app"], nil)
		expectEqual(state.records[1]?.workspace, state.testActive("Main"))
		expect(!state.events.contains(.returnFocus(bundleID: "com.aside.app")))
		expectInvariants(state)
	},
]

// MARK: - Placement reservations

private let reservationTests: [TestCase] = [
	TestCase("discovered window does not consume placement reservation") {
		let display1 = testDisplay("Main", x: 0, y: 0, width: 1440, height: 900, primary: true, displayID: 1)
		let display2 = testDisplay("External", x: 1440, y: 0, width: 1920, height: 1080, primary: false, displayID: 2)
		var state = testState([display1, display2])
		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "TestApp")

		state.setReservation(PlacementReservation(kind: .newColumnRight, monitor: externalKey, columnIndex: 0))

		let facts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		state.admit(facts, app: app, source: .discovered, now: 10.0)

		expectEqual(state.records[1]?.workspace, state.testActive("Main"))
		expect(state.reservation != nil, "reservation must not be consumed by discovered window")
		expectInvariants(state)
	},

	TestCase("startup window does not consume placement reservation") {
		let display1 = testDisplay("Main", x: 0, y: 0, width: 1440, height: 900, primary: true, displayID: 1)
		let display2 = testDisplay("External", x: 1440, y: 0, width: 1920, height: 1080, primary: false, displayID: 2)
		var state = testState([display1, display2])
		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "TestApp")

		state.setReservation(PlacementReservation(kind: .newColumnRight, monitor: externalKey, columnIndex: 0))

		let facts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		state.admit(facts, app: app, source: .startup, now: 10.0)

		expectEqual(state.records[1]?.workspace, state.testActive("Main"))
		expect(state.reservation != nil, "reservation must not be consumed by startup window")
		expectInvariants(state)
	},

	TestCase("clearing reservation cancels it for subsequent created windows") {
		var state = testState()
		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "TestApp")

		state.setReservation(PlacementReservation(kind: .float, monitor: mainKey, columnIndex: 0))
		state.setReservation(nil)

		let facts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		state.admit(facts, app: app, source: .created, now: 10.0)

		expectEqual(state.records[1]?.placement, .tiled)
		expectEqual(state.records[1]?.workspace, state.testActive("Main"))
		expectInvariants(state)
	},

	TestCase("float reservation centers window and sets pending float restore") {
		var state = testState()
		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "TestApp")

		state.setReservation(PlacementReservation(kind: .float, monitor: mainKey, columnIndex: 0))

		let facts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 500, height: 400))
		state.admit(facts, app: app, source: .created, now: 10.0)

		expectEqual(state.records[1]?.placement, .floating)
		expectEqual(state.records[1]?.pendingFloatRestore, true)
		guard let frame = state.records[1]?.floatingFrame?.frame(in: state.monitors[mainKey]!.visibleFrame) else {
			fail("floating frame must be set")
			return
		}
		let visible = state.monitors[mainKey]!.visibleFrame
		expectEqual(frame.midX, visible.midX, accuracy: 1.0)
		expectEqual(frame.midY, visible.midY, accuracy: 1.0)
		expectInvariants(state)
	},
]

// MARK: - Rescue frame for hidden-looking admissions

private let rescueFrameTests: [TestCase] = [
	TestCase("floating window admitted with frame off screen is centered and marked for float restore") {
		var state = testState()
		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "TestApp")

		// Frame far off screen.
		let facts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.dialogSubrole,
			frame: CGRect(x: -3000, y: -3000, width: 500, height: 400))
		state.admit(facts, app: app, source: .created, now: 10.0)

		expectEqual(state.records[1]?.placement, .unmanaged)
		expectEqual(state.records[1]?.pendingFloatRestore, true)
		guard let frame = state.records[1]?.floatingFrame?.frame(in: state.monitors[mainKey]!.visibleFrame) else {
			fail("floating frame must be set")
			return
		}
		let visible = state.monitors[mainKey]!.visibleFrame
		expectEqual(frame.midX, visible.midX, accuracy: 1.0)
		expectEqual(frame.midY, visible.midY, accuracy: 1.0)
		expectInvariants(state)
	},

	TestCase("unmanaged window admitted as sliver at screen corner is centered on monitor") {
		var state = testState()
		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "TestApp")

		// Sliver at bottom corner (effectively hidden).
		let facts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.dialogSubrole,
			frame: CGRect(x: 1439, y: 899, width: 500, height: 400))
		state.admit(facts, app: app, source: .created, now: 10.0)

		expectEqual(state.records[1]?.placement, .unmanaged)
		expectEqual(state.records[1]?.pendingFloatRestore, true)
		guard let frame = state.records[1]?.floatingFrame?.frame(in: state.monitors[mainKey]!.visibleFrame) else {
			fail("floating frame must be set")
			return
		}
		let visible = state.monitors[mainKey]!.visibleFrame
		expectEqual(frame.midX, visible.midX, accuracy: 1.0)
		expectEqual(frame.midY, visible.midY, accuracy: 1.0)
		expectInvariants(state)
	},

	TestCase("tiled window admitted as sliver is not rescued and receives slot from layout") {
		var state = testState()
		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "TestApp")

		let facts = WindowFacts(
			id: 1, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 1439, y: 899, width: 800, height: 600))
		state.admit(facts, app: app, source: .created, now: 10.0)

		expectEqual(state.records[1]?.placement, .tiled)
		expectEqual(state.records[1]?.pendingFloatRestore, false)
		expectInvariants(state)
	},
]

// MARK: - Zen session auto-exit at admission

private let zenAdmissionTests: [TestCase] = [
	TestCase("tiled admission into active zen workspace ends zen session") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])
		state.zen = ZenSession(monitor: mainKey, workspace: ws, focus: 1)

		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "TestApp")
		let facts = WindowFacts(
			id: 2, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		state.admit(facts, app: app, source: .created, now: 10.0)

		expectEqual(state.zen, nil)
		expect(state.events.contains(.zenEnded(.tiledAdmitted)))
		expectInvariants(state)
	},

	TestCase("floating admission into active zen workspace does not end zen session") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])
		state.zen = ZenSession(monitor: mainKey, workspace: ws, focus: 1)

		state.setReservation(PlacementReservation(kind: .float, monitor: mainKey, columnIndex: 0))

		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "TestApp")
		let facts = WindowFacts(
			id: 2, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		state.admit(facts, app: app, source: .created, now: 10.0)

		expect(state.zen != nil, "floating window admission must not end Zen")
		expectEqual(state.records[2]?.placement, .floating)
		expectInvariants(state)
	},

	TestCase("unmanaged admission does not end zen session") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])
		state.zen = ZenSession(monitor: mainKey, workspace: ws, focus: 1)

		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "TestApp")
		let facts = WindowFacts(
			id: 2, pid: 100, role: AXNames.windowRole, subrole: AXNames.dialogSubrole,
			frame: CGRect(x: 100, y: 100, width: 400, height: 300))
		state.admit(facts, app: app, source: .created, now: 10.0)

		expect(state.zen != nil, "unmanaged window admission must not end Zen")
		expectEqual(state.records[2]?.placement, .unmanaged)
		expectInvariants(state)
	},

	TestCase("launch aside admission into different workspace does not end zen session") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])
		state.zen = ZenSession(monitor: mainKey, workspace: ws, focus: 1)

		state.registerLaunchAside(bundleID: "com.aside.app", monitor: mainKey, now: 10.0)

		let app = AppFacts(pid: 200, bundleID: "com.aside.app", name: "AsideApp")
		let facts = WindowFacts(
			id: 2, pid: 200, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		state.admit(facts, app: app, source: .created, now: 10.5)

		expect(state.zen != nil, "launch-aside window in another workspace must not end Zen")
		expect(state.records[2]?.workspace != ws)
		expectInvariants(state)
	},

	TestCase("replacement admission into zen workspace does not end zen session") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1, 2]])
		state.zen = ZenSession(monitor: mainKey, workspace: ws, focus: 1)

		state.retire(2, reason: .destroyed, now: 10.0)

		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "App")
		let newFacts = WindowFacts(
			id: 3, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			title: "W2", frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		state.admit(newFacts, app: app, source: .created, now: 10.5)

		expect(state.zen != nil, "replacement window must not end Zen session")
		expectEqual(state.records[3]?.workspace, ws)
		expectInvariants(state)
	},
]

// MARK: - Replacement pairing

private let replacementPairingTests: [TestCase] = [
	TestCase("same process and equal title pairs immediately on admission") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[10]])

		state.retire(10, reason: .destroyed, now: 10.0)

		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "TestApp")
		let facts = WindowFacts(
			id: 20, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			title: "W10", frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		state.admit(facts, app: app, source: .created, now: 11.0)

		expectEqual(state.records[20]?.workspace, ws)
		expectEqual(state.testColumns(ws), [[20]])
		expect(state.events.contains(.rekeyed(from: 10, to: 20)))
		expectInvariants(state)
	},

	TestCase("same process and equal title takes precedence over same bundle and equal title") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[10, 20]])

		state.retire(10, reason: .destroyed, now: 10.0) // pid 100, title "W10"
		state.testAddWindow(20, placement: .tiled, workspace: ws, pid: 200, app: "TestApp", title: "W10")
		state.records[20]?.bundleID = "com.test.app"
		state.retire(20, reason: .destroyed, now: 10.0) // pid 200, bundle "com.test.app", title "W10"

		// New window has pid 100 and bundle "com.test.app".
		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "TestApp")
		let facts = WindowFacts(
			id: 30, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			title: "W10", frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		state.admit(facts, app: app, source: .created, now: 11.0)

		expect(state.events.contains(.rekeyed(from: 10, to: 30)), "must pair with window 10 having same pid")
		expect(!state.events.contains(.rekeyed(from: 20, to: 30)))
		expectInvariants(state)
	},

	TestCase("same bundle and equal title pairs across different processes when not launched aside") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[10]])
		state.records[10]?.bundleID = "com.test.app"

		state.retire(10, reason: .destroyed, now: 10.0)

		// New process pid 200 with same bundle ID.
		let app = AppFacts(pid: 200, bundleID: "com.test.app", name: "TestApp")
		let facts = WindowFacts(
			id: 20, pid: 200, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			title: "W10", frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		state.admit(facts, app: app, source: .created, now: 11.0)

		expect(state.events.contains(.rekeyed(from: 10, to: 20)))
		expectEqual(state.records[20]?.workspace, ws)
		expectEqual(state.testColumns(ws), [[20]])
		expectInvariants(state)
	},

	TestCase("cross process pairing is blocked when bundle is registered for launch aside") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[10]])
		state.records[10]?.bundleID = "com.aside.app"

		state.retire(10, reason: .destroyed, now: 10.0)

		state.registerLaunchAside(bundleID: "com.aside.app", monitor: mainKey, now: 10.5)

		// New process pid 200 for bundle registered as launch aside.
		let app = AppFacts(pid: 200, bundleID: "com.aside.app", name: "AsideApp")
		let facts = WindowFacts(
			id: 20, pid: 200, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			title: "W10", frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		state.admit(facts, app: app, source: .created, now: 11.0)

		expect(!state.events.contains(.rekeyed(from: 10, to: 20)))
		expect(state.records[20]?.workspace != ws, "must be claimed by launch-aside instead of replacing")
		expectInvariants(state)
	},

	TestCase("one to one pairing matches multiple windows without duplication") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[10], [20]])

		state.records[10]?.title = "Doc"
		state.records[10]?.observed.frame = CGRect(x: 0, y: 0, width: 500, height: 500)
		state.records[20]?.title = "Doc"
		state.records[20]?.observed.frame = CGRect(x: 800, y: 0, width: 500, height: 500)

		state.retire(10, reason: .destroyed, now: 10.0)
		state.retire(20, reason: .destroyed, now: 10.0)

		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "App")
		let facts1 = WindowFacts(
			id: 30, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			title: "Doc", frame: CGRect(x: 10, y: 10, width: 500, height: 500))
		let facts2 = WindowFacts(
			id: 40, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			title: "Doc", frame: CGRect(x: 810, y: 10, width: 500, height: 500))

		state.admit(facts1, app: app, source: .created, now: 11.0)
		state.admit(facts2, app: app, source: .created, now: 11.0)

		expect(state.events.contains(.rekeyed(from: 10, to: 30)))
		expect(state.events.contains(.rekeyed(from: 20, to: 40)))
		expectEqual(state.testColumns(ws), [[30], [40]])
		expectInvariants(state)
	},

	TestCase("frame distance tie breaker selects closest window among equal titles") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[10, 20]])

		state.records[10]?.title = "Doc"
		state.records[10]?.observed.frame = CGRect(x: 0, y: 0, width: 500, height: 500)
		state.records[20]?.title = "Doc"
		state.records[20]?.observed.frame = CGRect(x: 800, y: 0, width: 500, height: 500)

		state.retire(10, reason: .destroyed, now: 10.0)
		state.retire(20, reason: .destroyed, now: 10.0)

		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "App")
		// Admitted window at (810, 10) is much closer to retired window 20 than to window 10.
		let facts = WindowFacts(
			id: 30, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			title: "Doc", frame: CGRect(x: 810, y: 10, width: 500, height: 500))
		state.admit(facts, app: app, source: .created, now: 11.0)

		expect(state.events.contains(.rekeyed(from: 20, to: 30)))
		expect(!state.events.contains(.rekeyed(from: 10, to: 30)))
		expectInvariants(state)
	},

	TestCase("retired window within two second threshold is eligible for replacement") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[10]])

		state.retire(10, reason: .destroyed, now: 10.0)

		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "App")
		let facts = WindowFacts(
			id: 20, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			title: "W10", frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		state.admit(facts, app: app, source: .created, now: 11.9)

		expect(state.events.contains(.rekeyed(from: 10, to: 20)))
		expectInvariants(state)
	},

	TestCase("retired window exceeding two second threshold is not eligible for replacement") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[10]])

		state.retire(10, reason: .destroyed, now: 10.0)

		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "App")
		let facts = WindowFacts(
			id: 20, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			title: "W10", frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		state.admit(facts, app: app, source: .created, now: 12.1)

		expect(!state.events.contains(.rekeyed(from: 10, to: 20)))
		expectInvariants(state)
	},

	TestCase("barrier exit allows replacement after two second threshold and with empty titles") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[10]])
		state.records[10]?.title = ""

		state.setBarrier(.locked, active: true, now: 10.0)
		state.ingestDestroyed(id: 10, pid: 100, serverHas: false, now: 11.0)
		state.setBarrier(.locked, active: false, now: 40.0)

		// Rescan during barrier lift does not list window 10.
		state.ingestScan(pid: 100, result: .complete([]), serverHas: [], now: 41.0)

		// Admitted window with empty title arrives.
		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "App")
		let facts = WindowFacts(
			id: 20, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			title: "", frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		state.admit(facts, app: app, source: .startup, now: 41.5)

		state.liftBarrier(now: 42.0)

		expect(state.events.contains(.rekeyed(from: 10, to: 20)))
		expectEqual(state.records[20]?.workspace, ws)
		expectInvariants(state)
	},

	TestCase("different titles do not pair even with same process") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[10]])
		state.records[10]?.title = "OldTitle"

		state.retire(10, reason: .destroyed, now: 10.0)

		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "App")
		let facts = WindowFacts(
			id: 20, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			title: "NewTitle", frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		state.admit(facts, app: app, source: .created, now: 11.0)

		expect(!state.events.contains(.rekeyed(from: 10, to: 20)))
		expectInvariants(state)
	},

	TestCase("empty title does not pair outside barrier exit") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[10]])
		state.records[10]?.title = ""

		state.retire(10, reason: .destroyed, now: 10.0)

		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "App")
		let facts = WindowFacts(
			id: 20, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			title: "", frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		state.admit(facts, app: app, source: .created, now: 11.0)

		expect(!state.events.contains(.rekeyed(from: 10, to: 20)))
		expectInvariants(state)
	},

	TestCase("pairing rekeys window into old slot preserving slot memory and placement") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[10, 20], [30]])

		state.retire(20, reason: .destroyed, now: 10.0)

		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "App")
		let facts = WindowFacts(
			id: 40, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			title: "W20", frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		state.admit(facts, app: app, source: .created, now: 10.5)

		expectEqual(state.testColumns(ws), [[10, 40], [30]])
		expectInvariants(state)
	},

	TestCase("admitted first then retired in same ingest pairs during pairReplacements") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[10]])

		// Window 10 is in doubt (server still has it, pending destroy).
		state.records[10]?.liveness.pendingDestroySince = 10.0

		// New window 20 admitted while window 10 is still tracked.
		let app = AppFacts(pid: 100, bundleID: "com.test.app", name: "App")
		let facts = WindowFacts(
			id: 20, pid: 100, role: AXNames.windowRole, subrole: AXNames.standardWindowSubrole,
			title: "W10", frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		state.admit(facts, app: app, source: .created, now: 10.5)

		// Later in same ingest, window 10 is retired.
		state.retire(10, reason: .destroyed, now: 10.5)

		// End of ingest calls pairReplacements.
		state.pairReplacements(now: 10.5)

		expect(state.events.contains(.rekeyed(from: 10, to: 20)))
		expectEqual(state.records[20]?.workspace, ws)
		expectEqual(state.testColumns(ws), [[20]])
		expectInvariants(state)
	},
]
