//
//  ScenarioTests.swift
//  Axis core tests
//
//  Multi-step scenario tests verifying end-to-end window tracking behavior
//  against a simulated desktop environment.
//

import Foundation
import CoreGraphics

private let mainKey = testKey("Main")
private let externalKey = testKey("External")

let scenarioTests: [TestCase] = [
	// MARK: - Scan Liveness and Misses

	TestCase("scanMissWithServerPresence") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		for id: WindowID in 1...5 {
			world.addWindow(id: id, pid: 100, frame: CGRect(x: CGFloat(id * 100), y: 100, width: 600, height: 600))
		}
		world.runPass()

		let initialActive = world.state.testActive()
		let initialColumns = world.state.testColumns(initialActive)
		expectEqual(initialColumns.flatMap { $0 }.count, 5)

		// Complete scan misses window 1, but window server still has all 5 windows.
		let remainingWindows = (2...5).map { world.windows[WindowID($0)]! }
		world.advanceTime(by: 0.2)
		world.runPass(scans: [100: .complete(remainingWindows)])

		world.expectTracked(1, true)
		expectEqual(world.state.records[1]?.liveness.misses, 0)
		world.expectColumns(initialActive, initialColumns)

		// Window 1 returns in the scan 1.7 seconds later.
		world.advanceTime(by: 1.7)
		world.runPass()
		world.expectTracked(1, true)
		world.expectColumns(initialActive, initialColumns)
	},

	TestCase("timeoutDuringZen") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "Ghostty")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.addWindow(id: 2, pid: 100, frame: CGRect(x: 800, y: 100, width: 600, height: 600))
		world.runPass()

		expect(world.zenEnter(1))
		world.expectZen(active: true, focus: 1)
		world.expectVisibility(2, .zenHidden)

		// Scan times out while window server still holds all windows.
		world.advanceTime(by: 0.3)
		world.runPass(scans: [100: .timedOut])

		world.expectZen(active: true, focus: 1)
		world.expectTracked(1, true)
		world.expectTracked(2, true)
		expectEqual(world.state.apps[100]?.unresponsiveSince, world.currentTime)
	},

	TestCase("sporadicMissesDuringZen") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "Keysurf")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.addWindow(id: 2, pid: 100, frame: CGRect(x: 800, y: 100, width: 600, height: 600))
		world.runPass()

		expect(world.zenEnter(1))
		world.expectZen(active: true, focus: 1)

		// Repeat transient AX misses over several minutes; window server still has the windows.
		for _ in 1...10 {
			world.advanceTime(by: 30.0)
			world.runPass(scans: [100: .complete([world.windows[1]!])])
			world.expectZen(active: true, focus: 1)
			expectEqual(world.state.records[2]?.liveness.misses, 0)
		}
	},

	TestCase("stormOtherAppStillAdmitted") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.appA", name: "AppA")
		world.addApp(pid: 200, bundleID: "com.test.appB", name: "AppB")
		world.addApp(pid: 300, bundleID: "com.test.appC", name: "AppC")

		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.addWindow(id: 2, pid: 200, frame: CGRect(x: 800, y: 100, width: 600, height: 600))
		world.runPass()

		let ws = world.state.testActive()
		world.expectColumns(ws, [[1], [2]])

		// Apps A and B time out, while App C creates a new window.
		world.advanceTime(by: 0.5)
		world.addWindow(id: 3, pid: 300, frame: CGRect(x: 1000, y: 100, width: 600, height: 600))
		world.state.apps[300]?.createdSignalPending = true
		world.runPass(scans: [
			100: .timedOut,
			200: .timedOut,
			300: .complete([world.windows[3]!]),
		])

		world.expectTracked(1, true)
		world.expectTracked(2, true)
		world.expectTracked(3, true)
		world.expectColumns(ws, [[1], [2], [3]])
	},

	TestCase("helperNeverTracked") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()

		// A 1x1 helper window without close button or standard subrole appears.
		world.addWindow(
			id: 2, pid: 100, frame: CGRect(x: 0, y: 0, width: 1, height: 1),
			role: AXNames.windowRole, subrole: "AXUnknown", hasCloseButton: false
		)
		world.runPass()
		world.expectTracked(2, false)

		// It flickers out of the scan.
		world.removeWindowFromServer(id: 2)
		world.windows[2] = nil
		world.runPass()
		world.expectTracked(2, false)
		world.expectActiveColumns(on: "Main", [[1]])
	},

	TestCase("ghostLeavesLayout") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.addWindow(id: 2, pid: 100, frame: CGRect(x: 800, y: 100, width: 600, height: 600))
		world.runPass()

		// Window server drops window 2 while app still reports it.
		world.removeWindowFromServer(id: 2)
		world.runPass()

		// Advance past ghost threshold over two snapshots.
		world.advanceTime(by: 0.35)
		world.runPass()

		expectEqual(world.state.records[2]?.observed.isServerGhost, true)
		expectEqual(world.state.isDrawable(2), false)

		// Window reappears on window server.
		world.advanceTime(by: 0.2)
		world.addWindow(id: 2, pid: 100, frame: CGRect(x: 800, y: 100, width: 600, height: 600))
		world.runPass()

		expectEqual(world.state.records[2]?.observed.isServerGhost, false)
		expectEqual(world.state.isDrawable(2), true)
	},

	TestCase("tombstone") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()

		world.windowDestroyed(id: 1, pid: 100, serverHas: false)
		world.expectTracked(1, false)
		expect(world.state.tombstones.contains(1))

		// Stale AX scan still includes the destroyed window.
		world.runPass(scans: [100: .complete([world.windows[1]!])])
		world.expectTracked(1, false)
	},

	TestCase("cgGapKeepsColumns") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.addWindow(id: 2, pid: 100, frame: CGRect(x: 800, y: 100, width: 600, height: 600))
		world.runPass()

		let ws = world.state.testActive()
		world.expectColumns(ws, [[1], [2]])

		// Window server momentarily reports no on-screen windows.
		world.runPass(serverSnapshot: ServerSnapshot([], takenAt: world.currentTime))
		world.expectColumns(ws, [[1], [2]])
	},

	TestCase("lockKeepsColumns") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.addWindow(id: 2, pid: 100, frame: CGRect(x: 800, y: 100, width: 600, height: 600))
		world.runPass()

		let ws = world.state.testActive()
		world.expectColumns(ws, [[1], [2]])
		world.lock()

		// While locked, scan fails and destroyed notification arrives.
		world.advanceTime(by: 1.0)
		world.windowDestroyed(id: 1, pid: 100, serverHas: false)
		world.runPass(scans: [100: .failed(AXErrorCode.cannotComplete)])

		world.expectTracked(1, true)
		world.expectColumns(ws, [[1], [2]])
		expectEqual(world.state.pendingDuringBarrier.count, 1)

		// Unlock and rescan.
		world.unlock()
		world.liftBarrier()
		world.runPass(scans: [100: .complete([world.windows[2]!])])

		world.expectTracked(1, false)
		world.expectColumns(ws, [[2]])
	},

	TestCase("busyAppKeepsSlot") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.appA", name: "AppA")
		world.addApp(pid: 200, bundleID: "com.test.appB", name: "AppB")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.addWindow(id: 2, pid: 200, frame: CGRect(x: 800, y: 100, width: 600, height: 600))
		world.runPass()

		// App B becomes unresponsive.
		world.advanceTime(by: 0.5)
		world.runPass(scans: [200: .failed(AXErrorCode.cannotComplete)])
		expect(world.state.apps[200]?.unresponsiveSince != nil)

		let plan = world.plan()
		// Writes for unresponsive app are skipped.
		expect(plan.actions.allSatisfy { $0.pid != 200 })
		world.expectActiveColumns(on: "Main", [[1], [2]])
	},

	TestCase("closeWhileBusyCompacts") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.appA", name: "AppA")
		world.addApp(pid: 200, bundleID: "com.test.appB", name: "AppB")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()

		let ws1 = world.state.testActive()
		let ws2 = world.switchWorkspace(to: .next)!
		world.addWindow(id: 2, pid: 200, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()
		world.expectColumns(ws2, [[2]])

		// App B becomes unresponsive, then window 2 closes.
		world.state.apps[200]?.unresponsiveSince = world.currentTime
		world.windowDestroyed(id: 2, pid: 200, serverHas: false)

		world.expectTracked(2, false)
		// Empty workspace ws2 is compacted away.
		expectEqual(world.state.workspaces[ws2], nil)
		world.expectActiveWorkspace(on: "Main", ws1)
	},

	TestCase("closeDuringSwitch") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()

		let ws1 = world.state.testActive()
		let ws2 = world.switchWorkspace(to: .next)!
		world.addWindow(id: 2, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()

		// Switch back to ws1 while window 1 is destroyed concurrently.
		world.windowDestroyed(id: 1, pid: 100, serverHas: false)
		world.switchWorkspace(to: .id(ws1))

		world.expectTracked(1, false)
		world.expectTracked(2, true)
	},

	// MARK: - Visibility and Sessions

	TestCase("fullscreenRoundTrip") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.addWindow(id: 2, pid: 100, frame: CGRect(x: 800, y: 100, width: 600, height: 600))
		world.runPass()

		let ws = world.state.testActive()
		world.expectColumns(ws, [[1], [2]])

		// Window 1 enters native fullscreen.
		world.updateWindow(id: 1, isFullscreen: true)
		world.runPass()

		world.expectVisibility(1, .nativeFullscreen)
		world.expectColumns(ws, [[2]])
		expect(world.state.records[1]?.slotMemory != nil)

		// Window 1 exits fullscreen.
		world.updateWindow(id: 1, isFullscreen: false)
		world.runPass()

		world.expectVisibility(1, .visible)
		world.expectColumns(ws, [[1], [2]])
	},

	TestCase("hideRoundTrip") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.addWindow(id: 2, pid: 100, frame: CGRect(x: 800, y: 100, width: 600, height: 600))
		world.runPass()

		let ws = world.state.testActive()
		world.expectColumns(ws, [[1], [2]])

		world.hide(1)
		world.expectVisibility(1, .axisMinimized)
		world.expectColumns(ws, [[2]])

		let restored = world.unhideLast()
		expectEqual(restored, 1)
		world.expectVisibility(1, .visible)
		world.expectColumns(ws, [[1], [2]])
	},

	TestCase("missionControlBarrier") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()

		world.setBarrier(.missionControl, active: true)
		world.advanceTime(by: 1.0)
		world.runPass()

		world.setBarrier(.missionControl, active: false)
		world.liftBarrier()
		world.expectActiveColumns(on: "Main", [[1]])
	},

	TestCase("createdDuringSwitch") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()

		let ws2 = world.switchWorkspace(to: .next)!
		world.windowCreated(id: 2, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))

		world.expectTracked(2, true)
		world.expectWorkspace(2, ws2)
		world.expectColumns(ws2, [[2]])
	},

	TestCase("lateRelayoutReapplied") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "Ghostty")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass(planOptions: PlanOptions(), executePlan: true)

		let expectedSlot = world.state.expectedFrame(1)!
		// App resizes window to a smaller frame after creation.
		let clampedFrame = CGRect(x: expectedSlot.origin.x, y: expectedSlot.origin.y, width: expectedSlot.width - 50, height: expectedSlot.height - 50)
		world.updateWindow(id: 1, frame: clampedFrame)

		let plan = world.plan()
		expectEqual(plan.actions.first?.window, 1)
		expectEqual(plan.actions.first?.kind, .setFrame(expectedSlot))
	},

	TestCase("newWindowFocusMonitor") {
		let display1 = testDisplay("Main", primary: true, displayID: 1)
		let display2 = testDisplay("External", x: 1440, primary: false, displayID: 2)
		var world = ScenarioWorld(displays: [display1, display2])
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")

		world.state.focus.lastTrackedMonitor = externalKey
		world.windowCreated(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 800, height: 600))

		let extActive = world.state.activeWorkspace(externalKey)
		world.expectWorkspace(1, extActive)
	},

	TestCase("launchAside") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.aside", name: "AsideApp")
		world.registerLaunchAside(bundleID: "com.test.aside", monitor: mainKey)

		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()

		world.expectTracked(1, true)
		world.expectVisibility(1, .parked(.workspaceInactive))
		expect(world.capturedEvents.contains(where: {
			if case .returnFocus(let bundle) = $0 { return bundle == "com.test.aside" }
			return false
		}))
	},

	TestCase("launchAsideFloating") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.aside", name: "AsideApp")
		world.registerLaunchAside(bundleID: "com.test.aside", monitor: mainKey)

		// Small dialog window that classifies as unmanaged/floating.
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 300, height: 200), subrole: AXNames.dialogSubrole)
		world.runPass()

		world.expectTracked(1, true)
		world.expectPlacement(1, .floating)
		world.expectVisibility(1, .parked(.workspaceInactive))
	},

	TestCase("busyAtStartupAdmittedLater") {
		var world = ScenarioWorld()
		world.setBarrier(.starting, active: true)
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 800, height: 600))

		// Startup scan times out.
		world.runPass(scans: [100: .timedOut])
		world.expectTracked(1, false)

		// Startup barrier lifts and app answers later.
		world.advanceTime(by: 1.0)
		world.setBarrier(.starting, active: false)
		world.runPass(scans: [100: .complete([world.windows[1]!])])
		world.liftBarrier()

		world.expectTracked(1, true)
		world.expectActiveColumns(on: "Main", [[1]])
	},

	TestCase("closeAndOpenSamePass") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, title: "Doc A", frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		world.runPass()

		// Window 1 closes and Window 2 opens with different title in the same pass.
		world.addWindow(id: 2, pid: 100, title: "Settings", frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		world.runPass(
			scans: [100: .complete([world.windows[2]!])],
			destroyed: [(id: 1, pid: 100, serverHas: false)]
		)

		world.expectTracked(1, false)
		world.expectTracked(2, true)
		world.expectActiveColumns(on: "Main", [[2]])
	},

	TestCase("parkedMovedOnScreen") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		world.runPass(planOptions: PlanOptions(), executePlan: true)

		let ws2 = world.switchWorkspace(to: .next)!
		world.addWindow(id: 2, pid: 100, frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		world.runPass(planOptions: PlanOptions(), executePlan: true)

		world.switchWorkspace(to: .prev)
		world.expectVisibility(2, .parked(.workspaceInactive))

		// Parked window 2 is moved on-screen by an outside actor.
		let onScreenFrame = CGRect(x: 200, y: 200, width: 600, height: 400)
		world.updateWindow(id: 2, frame: onScreenFrame)

		let plan = world.plan()
		expect(plan.actions.contains { $0.window == 2 && $0.kind == .park(CGPoint(x: 1439, y: 899)) })
	},

	TestCase("unparkAfterSetPosition") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		world.runPass(planOptions: PlanOptions(), executePlan: true)

		world.switchWorkspace(to: .next)
		world.expectVisibility(1, .parked(.workspaceInactive))

		// Switch back; unpark should generate a write even if ledger previously targeted the slot.
		world.switchWorkspace(to: .prev)
		let plan = world.plan(options: PlanOptions(isCommand: true))
		expect(plan.show.flatMap(\.actions).contains { $0.window == 1 })
	},

	TestCase("noWriteLoop") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		world.runPass(planOptions: PlanOptions(), executePlan: true)

		let slot = world.state.expectedFrame(1)!
		let clamped = CGRect(x: slot.origin.x, y: slot.origin.y, width: 800, height: 600)

		// Simulate app repeatedly refusing requested size within fight window.
		for _ in 1...PlannerPolicy.fightLimit {
			world.advanceTime(by: 0.2)
			let plan = world.plan()
			world.executePlan(plan, landed: [1: clamped])
		}

		// Planner gives up after fight limit reached.
		world.advanceTime(by: 0.1)
		let finalPlan = world.plan()
		expect(finalPlan.isEmpty)
	},

	TestCase("compactionDuringSwitch") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()

		let ws1 = world.state.testActive()
		let ws2 = world.switchWorkspace(to: .next)!
		world.addWindow(id: 2, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()

		world.windowDestroyed(id: 1, pid: 100, serverHas: false)
		world.switchWorkspace(to: .id(ws2))

		expectEqual(world.state.workspaces[ws1], nil)
		world.expectActiveWorkspace(on: "Main", ws2)
		world.expectColumns(ws2, [[2]])
	},

	// MARK: - Topology

	TestCase("reconnectNewDisplayID") {
		let initial = testDisplay("External", displayID: 2)
		var world = ScenarioWorld(displays: [testDisplay("Main", primary: true), initial])
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")

		let extWs = world.state.activeWorkspace(initial.key)!
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()
		world.state.moveWindowToMonitor(1, to: initial.key, edge: .left)
		world.normalize()

		// Disconnect External.
		world.reconcileTopology([testDisplay("Main", primary: true)])
		expectEqual(world.state.memory[initial.key]?.order.contains(extWs), true)

		// Reconnect with same UUID key but different displayID.
		let reconnected = testDisplay("External", displayID: 8)
		world.reconcileTopology([testDisplay("Main", primary: true), reconnected])

		world.expectWorkspace(1, extWs)
		world.expectColumns(extWs, [[1]])
	},

	TestCase("monitorAddedNoReset") {
		var world = ScenarioWorld(displays: [testDisplay("Main", primary: true)])
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()

		let ws1 = world.state.testActive()
		let ws2 = world.switchWorkspace(to: .next)!
		world.addWindow(id: 2, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()

		// Plug in external monitor.
		let external = testDisplay("External", x: 1440, primary: false, displayID: 2)
		let change = world.reconcileTopology([testDisplay("Main", primary: true), external])

		expectEqual(change.added, [external.key])
		world.expectColumns(ws1, [[1]])
		world.expectColumns(ws2, [[2]])
		expectEqual(world.state.monitors[mainKey]?.order.count, 2)
	},

	TestCase("stagedTopology") {
		var world = ScenarioWorld(displays: [testDisplay("Main", primary: true)])
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()

		// Intermediate transient 0 screens is ignored.
		let degenerate = world.reconcileTopology([])
		expect(degenerate.ignored)
		world.expectActiveColumns(on: "Main", [[1]])

		// Staged transitions settle idempotently.
		let finalDisplays = [testDisplay("Main", primary: true), testDisplay("External", x: 1440, displayID: 2)]
		world.reconcileTopology(finalDisplays)
		world.reconcileTopology(finalDisplays)

		expectEqual(world.state.monitorOrder.count, 2)
		world.expectActiveColumns(on: "Main", [[1]])
	},

	TestCase("clamshellAdopt") {
		let builtin = testDisplay("Builtin", primary: true, displayID: 1)
		var world = ScenarioWorld(displays: [builtin])
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()

		let ws = world.state.testActive(builtin.name)

		// 1:1 monitor swap: lid closed, external plugged in.
		let external = testDisplay("External", primary: true, displayID: 2)
		let change = world.reconcileTopology([external])

		expectEqual(change.adopted[external.key], builtin.key)
		world.expectWorkspace(1, ws)
		world.expectActiveWorkspace(on: "External", ws)
	},

	TestCase("twoToOne") {
		let dispA = testDisplay("A", x: 0, primary: true, displayID: 1)
		let dispB = testDisplay("B", x: 1440, primary: false, displayID: 2)
		var world = ScenarioWorld(displays: [dispA, dispB])
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")

		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()
		world.addWindow(id: 2, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()
		world.state.moveWindowToMonitor(2, to: dispB.key, edge: .left)
		world.normalize()

		let wsA = world.state.records[1]?.workspace
		let wsB = world.state.records[2]?.workspace

		// Both monitors disconnect, replaced by single virtual monitor.
		let virtualDisp = testDisplay("Virtual", width: 1920, height: 1080, primary: true, displayID: 3)
		let change = world.reconcileTopology([virtualDisp])

		expectEqual(change.adopted.count + change.migrated.count, 2)
		expect(world.state.workspaces[wsA!] != nil)
		expect(world.state.workspaces[wsB!] != nil)
		expectEqual(world.state.monitors[virtualDisp.key]?.order.contains(wsA!), true)
		expectEqual(world.state.monitors[virtualDisp.key]?.order.contains(wsB!), true)
	},

	TestCase("replacedWhileLocked") {
		var world = ScenarioWorld(displays: [testDisplay("Main", primary: true)])
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()

		world.lock()

		// Display replaced while locked.
		let replacement = testDisplay("Replacement", primary: true, displayID: 5)
		world.reconcileTopology([replacement])

		world.unlock()
		world.liftBarrier()
		world.runPass()

		world.expectTracked(1, true)
		expectEqual(world.state.primaryMonitor, replacement.key)
	},

	// MARK: - Lock, Sleep and Wake

	TestCase("zenSurvivesLock") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.addWindow(id: 2, pid: 100, frame: CGRect(x: 800, y: 100, width: 600, height: 600))
		world.runPass()

		expect(world.zenEnter(1))
		world.expectZen(active: true, focus: 1)

		world.lock()
		world.advanceTime(by: 5.0)
		world.runPass(scans: [100: .failed(AXErrorCode.cannotComplete)])

		world.expectZen(active: true, focus: 1)

		world.unlock()
		world.liftBarrier()
		world.runPass()

		world.expectZen(active: true, focus: 1)
	},

	TestCase("emptyScansDuringLock") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()

		world.lock()
		world.runPass(scans: [100: .complete([])])

		world.expectTracked(1, true)
		world.expectActiveColumns(on: "Main", [[1]])
	},

	TestCase("wakeRekey") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, title: "Document", frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.addWindow(id: 2, pid: 100, title: "Terminal", frame: CGRect(x: 800, y: 100, width: 600, height: 600))
		world.runPass()

		let ws = world.state.testActive()
		world.expectColumns(ws, [[1], [2]])

		// Sleep and wake: Window 2 keeps its ID, Window 1 is replaced by Window 101 with the same title.
		world.lock()
		world.unlock()

		world.windowDestroyed(id: 1, pid: 100, serverHas: false)
		world.addWindow(id: 101, pid: 100, title: "Document", frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.state.apps[100]?.createdSignalPending = true
		world.liftBarrier()

		world.runPass(scans: [100: .complete([
			world.windows[2]!,
			world.windows[101]!,
		])])

		world.expectTracked(1, false)
		world.expectTracked(2, true)
		world.expectTracked(101, true)
		world.expectColumns(ws, [[101], [2]])
	},

	// MARK: - Zen and Interplay

	TestCase("zenIgnoresOtherMonitorChanges") {
		let dispA = testDisplay("Main", primary: true, displayID: 1)
		let dispB = testDisplay("External", x: 1440, primary: false, displayID: 2)
		var world = ScenarioWorld(displays: [dispA, dispB])
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")

		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()

		expect(world.zenEnter(1))
		world.expectZen(active: true, focus: 1)

		// New window created on External monitor.
		world.state.focus.lastTrackedMonitor = dispB.key
		world.windowCreated(id: 2, pid: 100, frame: CGRect(x: 1500, y: 100, width: 800, height: 600))

		world.expectZen(active: true, focus: 1)
	},

	TestCase("zenKeepsForFloatingAdmission") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()

		expect(world.zenEnter(1))
		world.expectZen(active: true, focus: 1)

		// Floating dialog admitted on Zen monitor.
		world.addWindow(id: 2, pid: 100, frame: CGRect(x: 100, y: 100, width: 300, height: 200), subrole: AXNames.dialogSubrole)
		world.runPass()

		world.expectZen(active: true, focus: 1)
		world.expectPlacement(2, .unmanaged)
	},

	TestCase("zenExitsWhenHiddenWindowCloses") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.addWindow(id: 2, pid: 100, frame: CGRect(x: 800, y: 100, width: 600, height: 600))
		world.runPass()

		expect(world.zenEnter(1))
		world.expectZen(active: true, focus: 1)
		world.expectVisibility(2, .zenHidden)

		world.windowDestroyed(id: 2, pid: 100, serverHas: false)

		world.expectZen(active: false)
		expect(world.capturedEvents.contains(.zenEnded(.hiddenClosed)))
	},

	TestCase("zenFocusCloses") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.addWindow(id: 2, pid: 100, frame: CGRect(x: 800, y: 100, width: 600, height: 600))
		world.runPass()

		expect(world.zenEnter(1))
		world.expectZen(active: true, focus: 1)

		world.windowDestroyed(id: 1, pid: 100, serverHas: false)

		world.expectZen(active: false)
		expect(world.capturedEvents.contains(.zenEnded(.focusClosed)))
	},

	TestCase("launchAsideDuringZen") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addApp(pid: 200, bundleID: "com.test.aside", name: "AsideApp")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()

		expect(world.zenEnter(1))
		world.expectZen(active: true, focus: 1)

		world.registerLaunchAside(bundleID: "com.test.aside", monitor: mainKey)
		world.addWindow(id: 2, pid: 200, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()

		world.expectZen(active: true, focus: 1)
		world.expectVisibility(2, .parked(.workspaceInactive))
	},

	TestCase("closesDuringZen") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()

		let ws1 = world.state.testActive()
		let ws2 = world.switchWorkspace(to: .next)!
		world.addWindow(id: 2, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.addWindow(id: 3, pid: 100, frame: CGRect(x: 800, y: 100, width: 600, height: 600))
		world.runPass()

		world.switchWorkspace(to: .id(ws1))
		expect(world.zenEnter(1))
		world.expectZen(active: true, focus: 1)

		// Close windows in inactive workspace ws2.
		world.windowDestroyed(id: 2, pid: 100, serverHas: false)
		world.windowDestroyed(id: 3, pid: 100, serverHas: false)

		world.expectTracked(2, false)
		world.expectTracked(3, false)
		expectEqual(world.state.workspaces[ws2], nil)
		world.expectZen(active: true, focus: 1)
	},

	TestCase("parkedRelisted") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()

		let ws1 = world.state.testActive()
		let ws2 = world.switchWorkspace(to: .next)!
		world.addWindow(id: 2, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()

		world.switchWorkspace(to: .id(ws1))
		world.expectVisibility(2, .parked(.workspaceInactive))

		// Scan re-lists parked window with its bottom corner coordinates.
		world.updateWindow(id: 2, frame: CGRect(x: 1439, y: 899, width: 800, height: 600))
		world.runPass()

		world.expectWorkspace(2, ws2)
		world.expectVisibility(2, .parked(.workspaceInactive))
	},

	TestCase("paletteRoundTrip") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()

		let ws1 = world.state.testActive()
		let ws2 = world.switchWorkspace(to: .next)!
		world.addWindow(id: 2, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()

		world.switchWorkspace(to: .id(ws1))

		world.paletteBegin()
		world.expectVisibility(1, .paletteHidden)
		world.expectVisibility(2, .parked(.workspaceInactive))

		world.paletteEnd()
		world.expectVisibility(1, .visible)
		world.expectVisibility(2, .parked(.workspaceInactive))
	},

	// MARK: - Classification and Placement

	TestCase("noReclassification") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		world.runPass()
		world.expectPlacement(1, .tiled)

		// Window shrinks below dialog threshold; should not flip to floating.
		world.updateWindow(id: 1, frame: CGRect(x: 100, y: 100, width: 300, height: 200))
		world.runPass()
		world.expectPlacement(1, .tiled)
	},

	TestCase("relaunchStacked") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.state.relaunchTiled.insert(1)

		// Small window that would normally classify as unmanaged.
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 300, height: 200))
		world.runPass()

		world.expectPlacement(1, .tiled)
		world.expectActiveColumns(on: "Main", [[1]])
	},

	TestCase("officeSubrole") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.microsoft.Powerpoint", name: "PowerPoint")
		world.addWindow(
			id: 1, pid: 100,
			frame: CGRect(x: 100, y: 100, width: 800, height: 600),
			role: AXNames.windowRole, subrole: "AXUnknown", hasCloseButton: true
		)
		world.runPass()

		world.expectPlacement(1, .tiled)
		world.expectActiveColumns(on: "Main", [[1]])
	},

	TestCase("unmanagedState") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.apple.systempreferences", name: "Settings")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		world.runPass()

		world.expectTracked(1, true)
		world.expectPlacement(1, .unmanaged)
		world.expectWorkspace(1, nil)
		world.expectActiveColumns(on: "Main", [])
	},

	// MARK: - Focus Rules and Compaction

	TestCase("switchToEmpty") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.runPass()

		let emptyWs = world.switchWorkspace(to: .next)!
		let context = FollowContext(
			focused: 1,
			previous: 1,
			changedAt: world.currentTime
		)
		let decision = FocusRules.followDecision(context, in: world.state, now: world.currentTime + 1.0)
		expectEqual(decision, .stay)
		world.expectActiveWorkspace(on: "Main", emptyWs)
	},

	TestCase("closeHandoff") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		world.addWindow(id: 1, pid: 100, frame: CGRect(x: 100, y: 100, width: 600, height: 600))
		world.addWindow(id: 2, pid: 100, frame: CGRect(x: 800, y: 100, width: 600, height: 600))
		world.runPass()

		world.windowDestroyed(id: 1, pid: 100, serverHas: false)

		let context = FollowContext(
			focused: nil,
			previous: 1,
			changedAt: world.currentTime,
			previousMonitor: mainKey
		)
		let decision = FocusRules.followDecision(context, in: world.state, now: world.currentTime + 1.0)
		expectEqual(decision, .focus(2))
	},

	TestCase("negativeCompaction") {
		var world = ScenarioWorld()
		world.addApp(pid: 100, bundleID: "com.test.app", name: "App")
		let row = world.state.testSetRow(negatives: 2, nonNegatives: 2, active: 0)
		// row: [ws-2, ws-1, ws0, ws1]
		let wsMinus2 = row[0]
		let wsMinus1 = row[1]
		let ws0 = row[2]

		world.state.testSetColumns(wsMinus2, [[1]])
		world.state.testSetColumns(ws0, [[2]])

		// wsMinus1 is empty. Compact negatives toward -1.
		world.state.compact(mainKey, keepingActive: false)

		expectEqual(world.state.workspaces[wsMinus1], nil)
		expectEqual(world.state.number(of: wsMinus2), -1)
		expectEqual(world.state.testNumbers(), [-1, 0])
	},
]
