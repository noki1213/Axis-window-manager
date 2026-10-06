//
//  ScenarioWorld.swift
//  Axis core tests
//
//  A simulated desktop environment providing a domain-specific language over TrackingState
//  for multi-step scenarios: displays, apps, windows, scan passes, window server snapshots,
//  signals, user commands, time travel, and state assertions.
//

import Foundation
import CoreGraphics

/// A simulated desktop driving the pure tracking core through realistic sequences of events.
struct ScenarioWorld {
	var state: TrackingState
	var currentTime: Time
	var displays: [DisplayFacts]
	var apps: [PID: AppFacts] = [:]
	var windows: [WindowID: WindowFacts] = [:]
	var serverWindows: [WindowID: ServerWindow] = [:]
	var capturedLogs: [String] = []
	var capturedEvents: [TrackingEvent] = []
	var lastPlan: Plan?

	init(
		displays: [DisplayFacts] = [testDisplay("Main", primary: true)],
		now: Time = 100.0,
		ownPID: PID = 999,
		barrier: Set<BarrierReason> = []
	) {
		self.displays = displays
		self.currentTime = now
		self.state = TrackingState(ownPID: ownPID, barrier: barrier)
		for display in displays {
			self.state.addMonitor(display)
		}
		drainOutputs()
	}

	// MARK: - Time travel

	mutating func advanceTime(by seconds: TimeInterval) {
		currentTime += seconds
	}

	mutating func setTime(_ time: Time) {
		currentTime = time
	}

	// MARK: - Desktop entities

	mutating func addApp(pid: PID, bundleID: String, name: String, isHidden: Bool = false) {
		let app = AppFacts(pid: pid, bundleID: bundleID, name: name, isHidden: isHidden)
		apps[pid] = app
		state.ingestApps([app], now: currentTime)
		drainOutputs()
	}

	mutating func addWindow(
		id: WindowID,
		pid: PID,
		title: String? = nil,
		frame: CGRect = CGRect(x: 100, y: 100, width: 800, height: 600),
		role: String = AXNames.windowRole,
		subrole: String = AXNames.standardWindowSubrole,
		hasCloseButton: Bool = true,
		isMinimized: Bool = false,
		isFullscreen: Bool = false,
		minSize: CGSize = CGSize(width: 200, height: 200),
		onServer: Bool = true,
		isOnScreen: Bool = true,
		layer: Int = 0,
		alpha: Double = 1.0
	) {
		let facts = WindowFacts(
			id: id,
			pid: pid,
			role: role,
			subrole: subrole,
			title: title ?? "W\(id)",
			frame: frame,
			isMinimized: isMinimized,
			isFullscreen: isFullscreen,
			hasCloseButton: hasCloseButton,
			minSize: minSize,
			takenAt: currentTime
		)
		windows[id] = facts
		if onServer {
			serverWindows[id] = ServerWindow(
				id: id,
				pid: pid,
				bounds: frame,
				layer: layer,
				alpha: alpha,
				isOnScreen: isOnScreen
			)
		} else {
			serverWindows[id] = nil
		}
	}

	mutating func updateWindow(
		id: WindowID,
		frame: CGRect? = nil,
		isMinimized: Bool? = nil,
		isFullscreen: Bool? = nil,
		title: String? = nil,
		isOnScreen: Bool? = nil
	) {
		guard var facts = windows[id] else { return }
		if let frame { facts.frame = frame }
		if let isMinimized { facts.isMinimized = isMinimized }
		if let isFullscreen { facts.isFullscreen = isFullscreen }
		if let title { facts.title = title }
		facts.takenAt = currentTime
		windows[id] = facts

		if var server = serverWindows[id] {
			if let frame { server.bounds = frame }
			if let isOnScreen { server.isOnScreen = isOnScreen }
			serverWindows[id] = server
		}
	}

	mutating func removeWindowFromServer(id: WindowID) {
		serverWindows[id] = nil
	}

	// MARK: - Passes and Ingest

	@discardableResult
	mutating func runPass(
		scans: [PID: ScanResult]? = nil,
		serverSnapshot: ServerSnapshot? = nil,
		focus: FocusFacts? = nil,
		facts: [WindowFacts]? = nil,
		destroyed: [(id: WindowID, pid: PID?, serverHas: Bool)] = [],
		terminated: [PID] = [],
		planOptions: PlanOptions? = nil,
		executePlan: Bool = false,
		landed: [WindowID: CGRect] = [:]
	) -> Plan? {
		// 1. Ingest window server snapshot
		let snapshot = serverSnapshot ?? ServerSnapshot(Array(serverWindows.values), takenAt: currentTime)
		state.ingestServer(snapshot)

		// 2. Prepare scans
		let scanMap: [PID: ScanResult]
		if let scans {
			scanMap = scans
		} else {
			var map: [PID: ScanResult] = [:]
			for (pid, _) in apps {
				let appWindows = windows.values.filter { $0.pid == pid }
				map[pid] = .complete(Array(appWindows))
			}
			scanMap = map
		}

		// Calculate serverHas for probe candidates
		let candidates = state.probeCandidates(scans: scanMap, destroyed: Set(destroyed.map(\.id)))
		let serverHasSet = Set(candidates.filter { serverWindows[$0] != nil })

		for (pid, result) in scanMap {
			state.ingestScan(pid: pid, result: result, serverHas: serverHasSet, now: currentTime)
		}

		// 3. Single window facts
		if let facts {
			state.ingestWindowFacts(facts, now: currentTime)
		}

		// 4. Destroyed and terminated signals
		for item in destroyed {
			state.ingestDestroyed(id: item.id, pid: item.pid, serverHas: item.serverHas, now: currentTime)
		}
		for pid in terminated {
			state.ingestTerminated(pid: pid, now: currentTime)
		}

		// 5. Focus
		if let focus {
			state.ingestFocus(focus, now: currentTime)
		}

		// 6. Replacement pairing and normalization
		state.pairReplacements(now: currentTime)
		state.normalize(now: currentTime)

		// 7. Planning
		var currentPlan: Plan?
		if let options = planOptions {
			let p = state.plan(snapshot: snapshot, options: options, now: currentTime)
			currentPlan = p
			self.lastPlan = p
			if executePlan {
				let writes = Self.landedWrites(p, results: landed)
				state.recordWrites(writes, now: currentTime)
			}
		}

		drainOutputs()
		assertInvariants()
		return currentPlan
	}

	// MARK: - Direct Signals and Commands

	mutating func windowCreated(
		id: WindowID,
		pid: PID,
		title: String? = nil,
		frame: CGRect = CGRect(x: 100, y: 100, width: 800, height: 600),
		role: String = AXNames.windowRole,
		subrole: String = AXNames.standardWindowSubrole,
		hasCloseButton: Bool = true,
		source: AdmissionSource = .created
	) {
		addWindow(id: id, pid: pid, title: title, frame: frame, role: role, subrole: subrole, hasCloseButton: hasCloseButton)
		let appFacts = apps[pid] ?? AppFacts(pid: pid, bundleID: "com.test.\(pid)", name: "App\(pid)")
		let facts = windows[id]!
		state.admit(facts, app: appFacts, source: source, now: currentTime)
		state.normalize(now: currentTime)
		drainOutputs()
		assertInvariants()
	}

	mutating func windowDestroyed(id: WindowID, pid: PID? = nil, serverHas: Bool = false) {
		if !serverHas {
			serverWindows[id] = nil
		}
		state.ingestDestroyed(id: id, pid: pid, serverHas: serverHas, now: currentTime)
		state.pairReplacements(now: currentTime)
		state.normalize(now: currentTime)
		drainOutputs()
		assertInvariants()
	}

	mutating func appTerminated(pid: PID) {
		for (id, facts) in windows where facts.pid == pid {
			serverWindows[id] = nil
		}
		state.ingestTerminated(pid: pid, now: currentTime)
		state.pairReplacements(now: currentTime)
		state.normalize(now: currentTime)
		drainOutputs()
		assertInvariants()
	}

	mutating func setBarrier(_ reason: BarrierReason, active: Bool) {
		state.setBarrier(reason, active: active, now: currentTime)
		drainOutputs()
		assertInvariants()
	}

	mutating func lock() {
		setBarrier(.locked, active: true)
	}

	mutating func unlock() {
		setBarrier(.locked, active: false)
	}

	mutating func liftBarrier() {
		state.liftBarrier(now: currentTime)
		drainOutputs()
		assertInvariants()
	}

	@discardableResult
	mutating func switchWorkspace(on monitor: MonitorKey = testKey("Main"), to target: WorkspaceTarget) -> WorkspaceID? {
		let res = state.switchWorkspace(on: monitor, to: target)
		state.normalize(now: currentTime)
		drainOutputs()
		assertInvariants()
		return res
	}

	@discardableResult
	mutating func zenEnter(_ id: WindowID) -> Bool {
		let res = state.zenEnter(id, now: currentTime)
		state.normalize(now: currentTime)
		drainOutputs()
		assertInvariants()
		return res
	}

	mutating func zenExit(_ reason: ZenExitReason) {
		state.zenExit(reason: reason)
		state.normalize(now: currentTime)
		drainOutputs()
		assertInvariants()
	}

	mutating func paletteBegin() {
		state.paletteBegin(now: currentTime)
		state.normalize(now: currentTime)
		drainOutputs()
		assertInvariants()
	}

	mutating func paletteEnd() {
		state.paletteEnd()
		state.normalize(now: currentTime)
		drainOutputs()
		assertInvariants()
	}

	mutating func hide(_ id: WindowID) {
		state.hide(id)
		state.normalize(now: currentTime)
		drainOutputs()
		assertInvariants()
	}

	@discardableResult
	mutating func unhideLast() -> WindowID? {
		let res = state.unhideLast()
		state.normalize(now: currentTime)
		drainOutputs()
		assertInvariants()
		return res
	}

	mutating func restoreHidden(_ id: WindowID, userInitiated: Bool = true) {
		state.restoreHidden(id, userInitiated: userInitiated)
		state.normalize(now: currentTime)
		drainOutputs()
		assertInvariants()
	}

	mutating func toggleFloat(_ id: WindowID) {
		_ = state.toggleFloat(id)
		state.normalize(now: currentTime)
		drainOutputs()
		assertInvariants()
	}

	mutating func registerLaunchAside(bundleID: String, monitor: MonitorKey = testKey("Main")) {
		state.registerLaunchAside(bundleID: bundleID, monitor: monitor, now: currentTime)
		drainOutputs()
		assertInvariants()
	}

	mutating func setReservation(_ reservation: PlacementReservation?) {
		state.setReservation(reservation)
		drainOutputs()
		assertInvariants()
	}

	@discardableResult
	mutating func reconcileTopology(_ displays: [DisplayFacts]) -> TopologyChange {
		self.displays = displays
		let change = state.reconcileTopology(displays, now: currentTime)
		drainOutputs()
		assertInvariants()
		return change
	}

	mutating func plan(options: PlanOptions = PlanOptions()) -> Plan {
		let snapshot = ServerSnapshot(Array(serverWindows.values), takenAt: currentTime)
		let p = state.plan(snapshot: snapshot, options: options, now: currentTime)
		self.lastPlan = p
		drainOutputs()
		return p
	}

	mutating func executePlan(_ plan: Plan, landed: [WindowID: CGRect] = [:]) {
		let writes = Self.landedWrites(plan, results: landed)
		state.recordWrites(writes, now: currentTime)
		drainOutputs()
	}

	mutating func normalize() {
		state.normalize(now: currentTime)
		drainOutputs()
		assertInvariants()
	}

	private mutating func drainOutputs() {
		capturedLogs.append(contentsOf: state.drainLog().map(\.message))
		capturedEvents.append(contentsOf: state.drainEvents())
	}

	static func landedWrites(_ plan: Plan, results: [WindowID: CGRect] = [:]) -> [WriteResult] {
		plan.actions.map { action in
			switch action.kind {
			case .setFrame(let frame):
				return WriteResult(
					window: action.window, pid: action.pid, kind: .frame, target: frame,
					result: results[action.window] ?? frame
				)
			case .park(let origin):
				let target = CGRect(origin: origin, size: action.observed?.size ?? .zero)
				return WriteResult(
					window: action.window, pid: action.pid, kind: .park, target: target,
					result: results[action.window] ?? target
				)
			case .minimize:
				return WriteResult(window: action.window, pid: action.pid, kind: .minimize, target: .zero)
			case .unminimize:
				return WriteResult(window: action.window, pid: action.pid, kind: .unminimize, target: .zero)
			}
		}
	}

	// MARK: - Assertions

	func expectTracked(_ id: WindowID, _ expected: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
		expectEqual(state.isTracked(id), expected, "window \(id) tracked", file: file, line: line)
	}

	func expectVisibility(_ id: WindowID, _ expected: Visibility, file: StaticString = #filePath, line: UInt = #line) {
		expectEqual(state.visibility(id), expected, "window \(id) visibility", file: file, line: line)
	}

	func expectPlacement(_ id: WindowID, _ expected: Placement, file: StaticString = #filePath, line: UInt = #line) {
		expectEqual(state.placement(id), expected, "window \(id) placement", file: file, line: line)
	}

	func expectWorkspace(_ id: WindowID, _ expected: WorkspaceID?, file: StaticString = #filePath, line: UInt = #line) {
		expectEqual(state.records[id]?.workspace, expected, "window \(id) workspace", file: file, line: line)
	}

	func expectColumns(_ workspace: WorkspaceID, _ expected: [[WindowID]], file: StaticString = #filePath, line: UInt = #line) {
		expectEqual(state.testColumns(workspace), expected, "workspace \(workspace) columns", file: file, line: line)
	}

	func expectActiveColumns(on monitor: String = "Main", _ expected: [[WindowID]], file: StaticString = #filePath, line: UInt = #line) {
		let key = testKey(monitor)
		guard let active = state.activeWorkspace(key) else {
			fail("no active workspace for monitor \(monitor)", file: file, line: line)
			return
		}
		expectEqual(state.testColumns(active), expected, "\(monitor) active workspace columns", file: file, line: line)
	}

	func expectActiveWorkspace(on monitor: String = "Main", _ expected: WorkspaceID, file: StaticString = #filePath, line: UInt = #line) {
		expectEqual(state.activeWorkspace(testKey(monitor)), expected, "\(monitor) active workspace", file: file, line: line)
	}

	func expectActiveWorkspaceNumber(on monitor: String = "Main", _ expected: Int, file: StaticString = #filePath, line: UInt = #line) {
		guard let active = state.activeWorkspace(testKey(monitor)),
			let num = state.number(of: active) else {
			fail("active workspace missing on \(monitor)", file: file, line: line)
			return
		}
		expectEqual(num, expected, "\(monitor) active workspace number", file: file, line: line)
	}

	func expectZen(active: Bool, focus: WindowID? = nil, file: StaticString = #filePath, line: UInt = #line) {
		expectEqual(state.zen != nil, active, "zen active", file: file, line: line)
		if let focus {
			expectEqual(state.zen?.focus, focus, "zen focus", file: file, line: line)
		}
	}

	func expectLogContains(_ needle: String, file: StaticString = #filePath, line: UInt = #line) {
		let match = capturedLogs.contains { $0.contains(needle) }
		expect(match, "expected log containing \"\(needle)\", captured logs: \(capturedLogs)", file: file, line: line)
	}

	func assertInvariants(file: StaticString = #filePath, line: UInt = #line) {
		expectInvariants(state, file: file, line: line)
	}
}
