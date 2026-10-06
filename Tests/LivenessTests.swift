//
//  LivenessTests.swift
//  Axis core tests
//
//  Verifies window tracking liveness: scans, misses, server presence, destroyed
//  and terminated notifications, barriers, tombstones, ghosts, and follow-ups.
//

import Foundation
import CoreGraphics

private let mainKey = testKey("Main")

let livenessTests: [TestCase] = scanLivenessTests
	+ destroyedAndTerminatedTests
	+ barrierLivenessTests
	+ tombstoneTests
	+ ghostAndProbeTests
	+ followUpTests
	+ focusLivenessTests
	+ launchAndSignalTests

// MARK: - Scan liveness and misses

private let scanLivenessTests: [TestCase] = [
	TestCase("failed scan marks app unresponsive without counting misses or retiring windows") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])

		state.ingestScan(pid: 100, result: .failed(AXErrorCode.cannotComplete), serverHas: [], now: 10.0)

		expectEqual(state.records[1]?.liveness.misses, 0)
		expectEqual(state.records[1]?.liveness.lastMissAt, nil)
		expect(state.records[1] != nil, "window must be kept alive")
		expectEqual(state.apps[100]?.unresponsiveSince, 10.0)
		expect(state.apps[100]?.nextRetryAt != nil, "retry must be scheduled")
		expectInvariants(state)
	},

	TestCase("timed out scan marks app unresponsive without counting misses or retiring windows") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])

		state.ingestScan(pid: 100, result: .timedOut, serverHas: [], now: 10.0)

		expectEqual(state.records[1]?.liveness.misses, 0)
		expectEqual(state.records[1]?.liveness.lastMissAt, nil)
		expect(state.records[1] != nil, "window must be kept alive")
		expectEqual(state.apps[100]?.unresponsiveSince, 10.0)
		expect(state.apps[100]?.nextRetryAt != nil, "retry must be scheduled")
		expectInvariants(state)
	},

	TestCase("incomplete scan updates listed windows without counting misses for unlisted windows") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1, 2]])

		let listed = WindowFacts(id: 1, pid: 100, title: "Updated Title")
		state.ingestScan(pid: 100, result: .incomplete([listed]), serverHas: [], now: 10.0)

		expectEqual(state.records[1]?.title, "Updated Title")
		expectEqual(state.records[2]?.liveness.misses, 0)
		expect(state.records[2] != nil, "unlisted window must not be retired by incomplete scan")
		expectInvariants(state)
	},

	TestCase("complete scan with window server presence keeps window and resets misses") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])
		state.records[1]?.liveness.misses = 1
		state.records[1]?.liveness.lastMissAt = 5.0

		// Complete scan misses window 1, but window server still has it.
		state.ingestScan(pid: 100, result: .complete([]), serverHas: [1], now: 10.0)

		expect(state.records[1] != nil, "window must be kept when window server has it")
		expectEqual(state.records[1]?.liveness.misses, 0)
		expectEqual(state.records[1]?.liveness.lastMissAt, nil)
		expectEqual(state.records[1]?.observed.serverHas, true)
		expectInvariants(state)
	},

	TestCase("complete scan missing window with window server presence logs keep only when misses were recorded") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])

		// Window 1 is unlisted in complete scan, window server still has it, but no previous misses.
		_ = state.drainLog()
		state.ingestScan(pid: 100, result: .complete([]), serverHas: [1], now: 10.0)
		let logsWithoutMisses = state.drainLog().map(\.message)
		expect(!logsWithoutMisses.contains { $0.contains("window server has it") },
			"keep must not be logged when window had no prior misses")

		// When misses were previously recorded, keep line must be logged.
		state.records[1]?.liveness.misses = 1
		state.records[1]?.liveness.lastMissAt = 10.0
		state.ingestScan(pid: 100, result: .complete([]), serverHas: [1], now: 10.15)
		let logsWithMisses = state.drainLog().map(\.message)
		expect(logsWithMisses.contains { $0.contains("window server has it") },
			"keep must be logged when window had misses")
		expectInvariants(state)
	},

	TestCase("complete scan missing window without window server presence records first miss") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])

		state.ingestScan(pid: 100, result: .complete([]), serverHas: [], now: 10.0)

		expect(state.records[1] != nil, "window must not be retired on first miss")
		expectEqual(state.records[1]?.liveness.misses, 1)
		expectEqual(state.records[1]?.liveness.lastMissAt, 10.0)
		expectEqual(state.records[1]?.observed.serverHas, false)
		expectInvariants(state)
	},

	TestCase("rapid consecutive misses under spacing threshold do not increment misses") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])

		state.ingestScan(pid: 100, result: .complete([]), serverHas: [], now: 10.0)
		expectEqual(state.records[1]?.liveness.misses, 1)

		// Miss arrives 50 ms later (less than 100 ms spacing threshold).
		state.ingestScan(pid: 100, result: .complete([]), serverHas: [], now: 10.05)

		expect(state.records[1] != nil, "window must not be retired by rapid scan")
		expectEqual(state.records[1]?.liveness.misses, 1)
		expectEqual(state.records[1]?.liveness.lastMissAt, 10.0)
		expectInvariants(state)
	},

	TestCase("second complete miss after spacing threshold with window server absence retires window") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])

		state.ingestScan(pid: 100, result: .complete([]), serverHas: [], now: 10.0)
		expectEqual(state.records[1]?.liveness.misses, 1)

		// Second miss arrives 150 ms later (spaced >= 0.1 s).
		state.ingestScan(pid: 100, result: .complete([]), serverHas: [], now: 10.15)

		expectEqual(state.records[1], nil)
		expect(state.events.contains(.retired(1, .absent)), "retirement event must be emitted")
		expectInvariants(state)
	},

	TestCase("window relisted in scan resets misses and clears pending destroy") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])
		state.records[1]?.liveness.misses = 1
		state.records[1]?.liveness.lastMissAt = 10.0
		state.records[1]?.liveness.pendingDestroySince = 10.0

		let listed = WindowFacts(id: 1, pid: 100, title: "W1")
		state.ingestScan(pid: 100, result: .complete([listed]), serverHas: [1], now: 10.2)

		expect(state.records[1] != nil, "window must be kept")
		expectEqual(state.records[1]?.liveness.misses, 0)
		expectEqual(state.records[1]?.liveness.lastMissAt, nil)
		expectEqual(state.records[1]?.liveness.pendingDestroySince, nil)
		expectEqual(state.livenessDrainReobserve(), [1])
		expectInvariants(state)
	},

	TestCase("complete scan clears unresponsive state when app recovers") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])

		state.ingestScan(pid: 100, result: .timedOut, serverHas: [], now: 10.0)
		expectEqual(state.apps[100]?.unresponsiveSince, 10.0)

		let listed = WindowFacts(id: 1, pid: 100, title: "W1")
		state.ingestScan(pid: 100, result: .complete([listed]), serverHas: [1], now: 11.0)

		expectEqual(state.apps[100]?.unresponsiveSince, nil)
		expectEqual(state.apps[100]?.retryCount, 0)
		expectEqual(state.apps[100]?.nextRetryAt, nil)
		expectInvariants(state)
	},
]

// MARK: - Destroyed and terminated

private let destroyedAndTerminatedTests: [TestCase] = [
	TestCase("destroyed notification when window server lacks id retires window immediately") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])

		state.ingestDestroyed(id: 1, pid: 100, serverHas: false, now: 10.0)

		expectEqual(state.records[1], nil)
		expect(state.events.contains(.retired(1, .destroyed)), "retirement event must be emitted")
		expectInvariants(state)
	},

	TestCase("destroyed notification when window server still has id waits for confirmation") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])

		state.ingestDestroyed(id: 1, pid: 100, serverHas: true, now: 10.0)

		expect(state.records[1] != nil, "window must not be retired while window server has it")
		expectEqual(state.records[1]?.liveness.pendingDestroySince, 10.0)
		expectInvariants(state)
	},

	TestCase("complete scan confirming absence of pending destroyed window retires it") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])

		state.ingestDestroyed(id: 1, pid: 100, serverHas: true, now: 10.0)
		expect(state.records[1] != nil, "window must still exist before scan")

		state.ingestScan(pid: 100, result: .complete([]), serverHas: [], now: 10.15)

		expectEqual(state.records[1], nil)
		expect(state.events.contains(.retired(1, .destroyed)), "must be retired with destroyed reason")
		expectInvariants(state)
	},

	TestCase("complete scan re-listing pending destroyed window keeps it and marks reobserve") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])

		state.ingestDestroyed(id: 1, pid: 100, serverHas: true, now: 10.0)

		let listed = WindowFacts(id: 1, pid: 100, title: "W1")
		state.ingestScan(pid: 100, result: .complete([listed]), serverHas: [1], now: 10.15)

		expect(state.records[1] != nil, "window must be preserved when re-listed")
		expectEqual(state.records[1]?.liveness.pendingDestroySince, nil)
		expectEqual(state.livenessDrainReobserve(), [1])
		expectInvariants(state)
	},

	TestCase("destroyed notification for untracked or tombstoned window is ignored") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])

		state.ingestDestroyed(id: 999, pid: 100, serverHas: false, now: 10.0)
		expect(state.events.isEmpty, "no events for untracked window")

		state.ingestDestroyed(id: 1, pid: 100, serverHas: false, now: 10.0)
		state.events = []
		state.ingestDestroyed(id: 1, pid: 100, serverHas: false, now: 11.0)
		expect(state.events.isEmpty, "no events for already tombstoned window")
		expectInvariants(state)
	},

	TestCase("app termination retires all records of the process") {
		var state = testState()
		let ws = state.testActive()
		state.testAddWindow(4, placement: .tiled, workspace: ws, pid: 200)
		state.testSetColumns(ws, [[1, 2], [3], [4]])

		state.ingestTerminated(pid: 100, now: 10.0)

		expectEqual(state.records[1], nil)
		expectEqual(state.records[2], nil)
		expectEqual(state.records[3], nil)
		expect(state.records[4] != nil, "windows of other apps must remain")
		expectEqual(state.apps[100], nil)
		expect(state.events.contains(.retired(1, .appTerminated)))
		expect(state.events.contains(.retired(2, .appTerminated)))
		expect(state.events.contains(.retired(3, .appTerminated)))
		expectInvariants(state)
	},

	TestCase("app termination for untracked app changes nothing") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])

		state.ingestTerminated(pid: 999, now: 10.0)

		expect(state.records[1] != nil, "existing windows must be untouched")
		expectInvariants(state)
	},
]

// MARK: - Barrier liveness

private let barrierLivenessTests: [TestCase] = [
	TestCase("barrier active ignores scans and window facts") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])

		state.setBarrier(.locked, active: true, now: 10.0)

		// Scan is ignored.
		state.ingestScan(pid: 100, result: .complete([]), serverHas: [], now: 11.0)
		expectEqual(state.records[1]?.liveness.misses, 0)

		// Facts are ignored.
		state.ingestWindowFacts([WindowFacts(id: 1, pid: 100, title: "New Title")], now: 11.0)
		expectEqual(state.records[1]?.title, "W1")

		expectInvariants(state)
	},

	TestCase("barrier active queues destroyed and terminated notifications") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1, 2]])

		state.setBarrier(.locked, active: true, now: 10.0)

		state.ingestDestroyed(id: 1, pid: 100, serverHas: false, now: 11.0)
		state.ingestTerminated(pid: 200, now: 12.0)

		expect(state.records[1] != nil, "window must not be retired during barrier")
		expectEqual(state.pendingDuringBarrier.count, 2)
		expectInvariants(state)
	},

	TestCase("barrier lift replays queued terminated signals") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])
		state.testAddWindow(2, placement: .tiled, workspace: ws, pid: 200)

		state.setBarrier(.locked, active: true, now: 10.0)
		state.ingestTerminated(pid: 200, now: 11.0)

		state.setBarrier(.locked, active: false, now: 12.0)
		state.liftBarrier(now: 13.0)

		expect(state.records[1] != nil, "window 1 must remain")
		expectEqual(state.records[2], nil)
		expect(state.events.contains(.retired(2, .appTerminated)))
		expect(state.pendingDuringBarrier.isEmpty, "signals queue must be emptied")
		expectInvariants(state)
	},

	TestCase("barrier lift replays queued destroyed signal with rescan verification") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1, 2]])

		state.setBarrier(.locked, active: true, now: 10.0)
		state.ingestDestroyed(id: 1, pid: 100, serverHas: false, now: 11.0)
		state.ingestDestroyed(id: 2, pid: 100, serverHas: false, now: 11.0)

		state.setBarrier(.locked, active: false, now: 12.0)

		// Rescan during liftPending lists window 1 but omits window 2.
		let listed = WindowFacts(id: 1, pid: 100, title: "W1")
		state.ingestScan(pid: 100, result: .complete([listed]), serverHas: [1], now: 12.5)

		state.liftBarrier(now: 13.0)

		expect(state.records[1] != nil, "window listed in rescan must be kept")
		expectEqual(state.livenessDrainReobserve(), [1])
		expectEqual(state.records[2], nil)
		expect(state.events.contains(.retired(2, .destroyed)))
		expectInvariants(state)
	},

	TestCase("barrier lift resets all miss counters on tracked windows") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])
		state.records[1]?.liveness.misses = 1
		state.records[1]?.liveness.lastMissAt = 9.0

		state.setBarrier(.locked, active: true, now: 10.0)
		state.setBarrier(.locked, active: false, now: 12.0)
		state.liftBarrier(now: 13.0)

		expectEqual(state.records[1]?.liveness.misses, 0)
		expectEqual(state.records[1]?.liveness.lastMissAt, nil)
		expectInvariants(state)
	},
]

// MARK: - Tombstones

private let tombstoneTests: [TestCase] = [
	TestCase("retired window is tombstoned and ignores single-window facts") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])

		state.retire(1, reason: .destroyed, now: 10.0)
		expect(state.tombstones.contains(1), "retired window must be tombstoned")

		// Late Accessibility notification sends facts for retired window.
		state.ingestWindowFacts([WindowFacts(id: 1, pid: 100, title: "Stale")], now: 11.0)
		expectEqual(state.records[1], nil)
		expectInvariants(state)
	},

	TestCase("tombstoned id in complete scan is not re-admitted") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])

		state.retire(1, reason: .destroyed, now: 10.0)

		let facts = WindowFacts(id: 1, pid: 100, title: "Stale")
		state.ingestScan(pid: 100, result: .complete([facts]), serverHas: [1], now: 11.0)

		expectEqual(state.records[1], nil)
		expectInvariants(state)
	},

	TestCase("admit returns nil for tombstoned window id") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])

		state.retire(1, reason: .destroyed, now: 10.0)

		let facts = WindowFacts(id: 1, pid: 100, title: "Stale")
		let app = AppFacts(pid: 100, bundleID: "com.test", name: "Test")
		let admittedID = state.admit(facts, app: app, source: .created, now: 11.0)

		expectEqual(admittedID, nil)
		expectEqual(state.records[1], nil)
		expectInvariants(state)
	},
]

// MARK: - Window-server ghosts and probe candidates

private let ghostAndProbeTests: [TestCase] = [
	TestCase("window server absence for listed visible window marks absence count and time") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])

		// Snapshot with no on-screen windows.
		state.ingestServer(ServerSnapshot(windows: [:], scope: .onScreen, takenAt: 10.0))

		expectEqual(state.records[1]?.observed.serverAbsentSince, 10.0)
		expectEqual(state.records[1]?.observed.serverAbsentCount, 1)
		expectEqual(state.records[1]?.observed.isServerGhost, false)
		expect(state.isDrawable(1), "window missing for only 1 snapshot is still drawable")
		expectInvariants(state)
	},

	TestCase("window missing across multiple snapshots for ghost delay becomes server ghost") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])

		state.ingestServer(ServerSnapshot(windows: [:], scope: .onScreen, takenAt: 10.0))
		expectEqual(state.records[1]?.observed.isServerGhost, false)

		// Second snapshot at 10.35 s (delay >= 0.3 s and snapshots >= 2).
		state.ingestServer(ServerSnapshot(windows: [:], scope: .onScreen, takenAt: 10.35))

		expectEqual(state.records[1]?.observed.serverAbsentCount, 2)
		expectEqual(state.records[1]?.observed.isServerGhost, true)
		expectEqual(state.isDrawable(1), false)
		expectInvariants(state)
	},

	TestCase("server ghost reappearing on window server clears ghost state") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])

		state.ingestServer(ServerSnapshot(windows: [:], scope: .onScreen, takenAt: 10.0))
		state.ingestServer(ServerSnapshot(windows: [:], scope: .onScreen, takenAt: 10.35))
		expectEqual(state.records[1]?.observed.isServerGhost, true)

		let window = ServerWindow(id: 1, pid: 100, bounds: CGRect(x: 10, y: 10, width: 500, height: 400), layer: 0, alpha: 1, isOnScreen: true)
		state.ingestServer(ServerSnapshot(windows: [1: window], scope: .onScreen, takenAt: 11.0))

		expectEqual(state.records[1]?.observed.isServerGhost, false)
		expectEqual(state.records[1]?.observed.serverAbsentSince, nil)
		expectEqual(state.records[1]?.observed.serverAbsentCount, 0)
		expect(state.isDrawable(1), "window should be drawable again")
		expectInvariants(state)
	},

	TestCase("probe candidates collects unlisted records from complete scans and destroyed ids") {
		var state = testState()
		let ws = state.testActive()
		state.testAddWindow(3, placement: .tiled, workspace: ws, pid: 200)
		state.testSetColumns(ws, [[1, 2], [3]])

		let completeScan = ScanResult.complete([WindowFacts(id: 1, pid: 100)])
		let candidates = state.probeCandidates(scans: [100: completeScan], destroyed: [3])

		expect(candidates.contains(2), "unlisted window 2 of pid 100 must be probed")
		expect(candidates.contains(3), "destroyed window 3 must be probed")
		expect(!candidates.contains(1), "listed window 1 must not be probed")
		expectInvariants(state)
	},

	TestCase("probe candidates excludes unlisted windows from incomplete or failed scans") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1, 2]])

		let incompleteScan = ScanResult.incomplete([WindowFacts(id: 1, pid: 100)])
		let candidates = state.probeCandidates(scans: [100: incompleteScan], destroyed: [])

		expect(!candidates.contains(2), "incomplete scan must not trigger probe for unlisted window")
		expectInvariants(state)
	},
]

// MARK: - Follow-ups

private let followUpTests: [TestCase] = [
	TestCase("follow-ups schedule confirm scan for unconfirmed miss") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])

		state.ingestScan(pid: 100, result: .complete([]), serverHas: [], now: 10.0)

		let followUps = state.livenessFollowUps(now: 10.0)
		expect(followUps.contains { $0.reason == "confirm miss" && abs($0.at - 10.15) < 1e-4 })
		expectInvariants(state)
	},

	TestCase("follow-ups schedule confirm scan for pending destroyed window") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])

		state.ingestDestroyed(id: 1, pid: 100, serverHas: true, now: 10.0)

		let followUps = state.livenessFollowUps(now: 10.0)
		expect(followUps.contains { $0.reason == "confirm destroy" && abs($0.at - 10.15) < 1e-4 })
		expectInvariants(state)
	},

	TestCase("follow-ups schedule confirm scan for window server absence") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])

		state.ingestServer(ServerSnapshot(windows: [:], scope: .onScreen, takenAt: 10.0))

		let followUps = state.livenessFollowUps(now: 10.0)
		expect(followUps.contains { $0.reason == "confirm window-server absence" && abs($0.at - 10.15) < 1e-4 })
		expectInvariants(state)
	},

	TestCase("follow-ups schedule unreadable retry with backoff") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])

		state.ingestScan(pid: 100, result: .failed(AXErrorCode.cannotComplete), serverHas: [], now: 10.0)

		let followUps = state.livenessFollowUps(now: 10.0)
		expect(followUps.contains { $0.reason == "unreadable retry" && abs($0.at - 10.5) < 1e-4 })
		expectInvariants(state)
	},

	TestCase("no follow-ups returned while barrier is active") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])
		state.ingestDestroyed(id: 1, pid: 100, serverHas: true, now: 10.0)

		state.setBarrier(.locked, active: true, now: 10.0)
		let followUps = state.livenessFollowUps(now: 10.0)

		expect(followUps.isEmpty, "follow-ups must be empty during barrier")
		expectInvariants(state)
	},
]

// MARK: - Focus liveness

private let focusLivenessTests: [TestCase] = [
	TestCase("focus on tracked window updates current, previous, and last tracked monitor") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1, 2]])

		let facts1 = FocusFacts(frontmostPID: 100, frontmostBundleID: "com.test", focused: 1)
		state.ingestFocus(facts1, now: 10.0)
		expectEqual(state.focus.current, 1)
		expectEqual(state.focus.currentMonitor, mainKey)
		expectEqual(state.focus.lastTrackedMonitor, mainKey)

		let facts2 = FocusFacts(frontmostPID: 100, frontmostBundleID: "com.test", focused: 2)
		state.ingestFocus(facts2, now: 11.0)
		expectEqual(state.focus.current, 2)
		expectEqual(state.focus.previous, 1)
		expectInvariants(state)
	},

	TestCase("focus on untracked window clears current while preserving last tracked monitor") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])

		let facts1 = FocusFacts(frontmostPID: 100, frontmostBundleID: "com.test", focused: 1)
		state.ingestFocus(facts1, now: 10.0)
		expectEqual(state.focus.lastTrackedMonitor, mainKey)

		// Focus moves to untracked window (e.g. system menu or panel).
		let facts2 = FocusFacts(frontmostPID: 200, frontmostBundleID: "com.other", focused: 999)
		state.ingestFocus(facts2, now: 11.0)

		expectEqual(state.focus.current, nil)
		expectEqual(state.focus.currentMonitor, nil)
		expectEqual(state.focus.lastTrackedMonitor, mainKey)
		expectInvariants(state)
	},

	TestCase("focus read error preserves previous focus state") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])

		let facts1 = FocusFacts(frontmostPID: 100, frontmostBundleID: "com.test", focused: 1)
		state.ingestFocus(facts1, now: 10.0)

		let errorFacts = FocusFacts(frontmostPID: 100, frontmostBundleID: "com.test", focused: nil, error: AXErrorCode.cannotComplete)
		state.ingestFocus(errorFacts, now: 11.0)

		expectEqual(state.focus.current, 1)
		expectEqual(state.focus.currentMonitor, mainKey)
		expectInvariants(state)
	},
]

// MARK: - Launch and creation signals

private let launchAndSignalTests: [TestCase] = [
	TestCase("app launched schedules launch retries and marks created signal pending") {
		var state = testState()
		let app = AppFacts(pid: 100, bundleID: "com.test", name: "TestApp")
		state.livenessNoteLaunched(app, now: 10.0)

		expectEqual(state.apps[100]?.createdSignalPending, true)
		expectEqual(state.livenessState.launchRetries[100]?.launchedAt, 10.0)
		expectEqual(state.livenessState.launchRetries[100]?.attempts, 0)
		let followUps = state.livenessFollowUps(now: 10.0)
		expect(followUps.contains { $0.reason == "launch retry" })
		expectInvariants(state)
	},

	TestCase("created signal sets pending creation flag on app") {
		var state = testState()
		state.livenessNoteCreated(pid: 100, now: 10.0)

		expectEqual(state.apps[100]?.createdSignalPending, true)
		expectInvariants(state)
	},

	TestCase("busy app at startup retried and admitted as discovered once readable") {
		var state = testState()
		let ws = state.testActive()
		_ = ws

		// Startup with starting barrier.
		state.setBarrier(.starting, active: true, now: 0.0)
		state.setBarrier(.starting, active: false, now: 1.0)
		// App launched at startup but scan times out.
		state.ingestScan(pid: 100, result: .timedOut, serverHas: [], now: 1.1)
		expectEqual(state.apps[100]?.unresponsiveSince, 1.1)
		expectEqual(state.records.isEmpty, true)

		// Lift barrier.
		state.liftBarrier(now: 1.2)

		// App becomes readable later at 3.0 s.
		let facts = WindowFacts(id: 1, pid: 100, title: "Doc", frame: CGRect(x: 100, y: 100, width: 800, height: 600))
		state.ingestScan(pid: 100, result: .complete([facts]), serverHas: [1], now: 3.0)

		expect(state.records[1] != nil, "window must be admitted")
		expectEqual(state.records[1]?.source, .discovered)
		expectEqual(state.apps[100]?.unresponsiveSince, nil)
		expectInvariants(state)
	},

	TestCase("ingestApps updates bundle id and app name on state and tracked records") {
		var state = testState()
		let ws = state.testActive()
		state.testSetColumns(ws, [[1]])
		expectEqual(state.records[1]?.appName, "App")

		let app = AppFacts(pid: 100, bundleID: "com.updated", name: "UpdatedApp", isHidden: true)
		state.ingestApps([app], now: 10.0)

		expectEqual(state.apps[100]?.bundleID, "com.updated")
		expectEqual(state.apps[100]?.name, "UpdatedApp")
		expectEqual(state.apps[100]?.isHidden, true)
		expectEqual(state.records[1]?.bundleID, "com.updated")
		expectEqual(state.records[1]?.appName, "UpdatedApp")
		expectInvariants(state)
	},
]
