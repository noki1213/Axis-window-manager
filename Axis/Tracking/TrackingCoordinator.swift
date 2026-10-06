//
//	TrackingCoordinator.swift
//	Axis
//
//	Coordinates window tracking, event sources, refresh scheduling, and state transitions.
//	Main-thread single writer of TrackingState.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Coordinates event sources and the tracking pipeline.
@MainActor
final class TrackingCoordinator {
	static let shared = TrackingCoordinator()

	enum Mode {
		case shadow
	}

	// MARK: - State

	private(set) var mode: Mode = .shadow
	private(set) var isRunning: Bool = false
	private(set) var state: TrackingState

	private let axEventSource = AXEventSource()
	private let systemSignals = SystemSignals()
	private let watcher = WindowServerWatcher()

	// MARK: - Feature Event Fan-out Closures

	var onAdmitted: ((WindowID) -> Void)?
	var onRetired: ((WindowID, RetireReason) -> Void)?
	var onRekeyed: ((WindowID, WindowID) -> Void)?
	var onActiveChanged: ((MonitorKey, WorkspaceID?, WorkspaceID, ActiveChangeCause) -> Void)?
	var onZenEnded: ((ZenExitReason) -> Void)?
	var onFocusChanged: ((WindowID?, WindowID?) -> Void)?
	var onReturnFocus: ((String) -> Void)?
	var onLayoutApplied: ((WindowID?) -> Void)?

	// MARK: - Refresh Request Coalescing

	struct RefreshRequest {
		enum PIDs: Equatable {
			case none
			case some(Set<PID>)
			case all
		}

		var pids: PIDs = .none
		var windowsToRead: Set<WindowID> = []
		var readFocus: Bool = false
		var readFrames: Bool = false
		var destroyed: [WindowID: PID?] = [:]
		var reasons: Set<String> = []
		var deadline: Time = .infinity

		var isEmpty: Bool {
			pids == .none && windowsToRead.isEmpty && !readFocus && !readFrames && destroyed.isEmpty
		}

		mutating func merge(with other: RefreshRequest) {
			switch (pids, other.pids) {
			case (.all, _), (_, .all):
				pids = .all
			case (.some(let a), .some(let b)):
				pids = .some(a.union(b))
			case (.some(let a), .none):
				pids = .some(a)
			case (.none, .some(let b)):
				pids = .some(b)
			case (.none, .none):
				pids = .none
			}
			windowsToRead.formUnion(other.windowsToRead)
			readFocus = readFocus || other.readFocus
			readFrames = readFrames || other.readFrames
			destroyed.merge(other.destroyed) { first, _ in first }
			reasons.formUnion(other.reasons)
			deadline = min(deadline, other.deadline)
		}
	}

	private var pendingRequest: RefreshRequest?
	private var nextRequest: RefreshRequest?
	private var isPassInFlight: Bool = false
	private var refreshTimer: DispatchSourceTimer?

	// MARK: - Stability and Barrier Bookkeeping

	private var stabilityTimer: DispatchSourceTimer?
	private var lastStabilitySignature: DisplaySignature?
	private var stabilityConsecutiveTicks: Int = 0
	private var stabilityStartTime: Time = 0

	private var lockCheckTimer: DispatchSourceTimer?

	// MARK: - Shadow Self-Checks and Observer Deduplication

	private var recentlyRetiredInShadow: [WindowID: Time] = [:]
	private var loggedObserverFailures: [PID: AXObserverStatus] = [:]

	// MARK: - Initialization

	private init() {
		self.state = TrackingState(config: LayoutConfig(), ownPID: ProcessInfo.processInfo.processIdentifier, barrier: [])
	}

	// MARK: - Lifecycle

	func start(mode: Mode = .shadow) {
		guard !isRunning else { return }
		self.mode = mode
		self.isRunning = true

		let now = ProcessInfo.processInfo.systemUptime
		state = TrackingState(config: LayoutConfig(), ownPID: ProcessInfo.processInfo.processIdentifier, barrier: [])
		state.setBarrier(.starting, active: true, now: now)

		axEventSource.start { [weak self] signal in
			self?.receive(signal)
		}

		systemSignals.start { [weak self] signal in
			self?.receive(signal)
		}

		watcher.sink = { [weak self] signal in
			self?.receive(signal)
		}
		watcher.contextProvider = { [weak self] in
			self?.buildWatcherContext() ?? WindowServerWatcher.Context(isPaused: true)
		}
		watcher.start()

		// Register regular running applications
		for app in NSWorkspace.shared.runningApplications {
			guard app.activationPolicy == .regular,
				app.processIdentifier != state.ownPID,
				app.bundleIdentifier != SystemSignals.loginWindowBundleID else { continue }
			axEventSource.register(pid: app.processIdentifier)
		}

		// Reconcile initial displays
		state.reconcileTopology(DisplayReader.read(), now: now)
		drainLog()

		// Clear startup barrier and queue full initial scan
		state.setBarrier(.starting, active: false, now: now)
		drainLog()

		if SystemSignals.isScreenLocked() || SystemSignals.isLoginWindowFrontmost {
			raiseBarrier(.locked)
		}

		requestRefresh(pids: .all, readFocus: true, delay: 0, reason: "startup")
	}

	func stop() {
		guard isRunning else { return }
		isRunning = false

		refreshTimer?.cancel()
		refreshTimer = nil
		stabilityTimer?.cancel()
		stabilityTimer = nil
		lockCheckTimer?.cancel()
		lockCheckTimer = nil

		watcher.stop()
		systemSignals.stop()
		axEventSource.stop()
	}

	// MARK: - Signal Processing

	private func receive(_ signal: TrackingSignal) {
		guard isRunning else { return }
		let now = ProcessInfo.processInfo.systemUptime

		switch signal {
		case .windowCreated(let pid):
			state.livenessNoteCreated(pid: pid, now: now)
			requestRefresh(pids: .some([pid]), delay: 0.016, reason: "window created")

		case .windowDestroyed(let id, let pid):
			axEventSource.unwatchWindow(id)
			requestRefresh(destroyed: [id: pid], delay: 0.016, reason: "window destroyed")

		case .windowMiniaturized(let id, _), .windowDeminiaturized(let id, _):
			requestRefresh(windowsToRead: [id], delay: 0.016, reason: "window miniaturized/deminiaturized")

		case .windowMoved, .windowResized:
			requestRefresh(readFrames: true, delay: 0.030, reason: "window moved/resized")

		case .focusedWindowChanged:
			requestRefresh(pids: .none, readFocus: true, delay: 0.016, reason: "focused window changed")

		case .observerFailed(let pid):
			handleObserverFailed(pid: pid)

		case .appLaunched(let pid):
			guard pid != state.ownPID else { return }
			axEventSource.register(pid: pid)
			if let app = NSRunningApplication(processIdentifier: pid) {
				let facts = AppFacts(
					pid: pid,
					bundleID: app.bundleIdentifier,
					name: app.localizedName ?? "",
					isHidden: app.isHidden)
				state.livenessNoteLaunched(facts, now: now)
			}
			requestRefresh(pids: .some([pid]), delay: 0.100, reason: "app launched")

		case .appTerminated(let pid):
			axEventSource.unregister(pid: pid)
			loggedObserverFailures.removeValue(forKey: pid)
			if state.barrier.isEmpty {
				state.ingestTerminated(pid: pid, now: now)
				drainLog()
				requestRefresh(pids: .none, delay: 0, reason: "app terminated")
			} else {
				state.ingestTerminated(pid: pid, now: now)
			}

		case .appActivated(let pid):
			axEventSource.register(pid: pid)
			requestRefresh(readFocus: true, delay: 0.016, reason: "app activated")

		case .appHidden(let pid):
			if var app = state.apps[pid] {
				app.isHidden = true
				state.apps[pid] = app
			}
			requestRefresh(readFrames: true, delay: 0.016, reason: "app hidden")

		case .appUnhidden(let pid):
			if var app = state.apps[pid] {
				app.isHidden = false
				state.apps[pid] = app
			}
			requestRefresh(readFrames: true, delay: 0.016, reason: "app unhidden")

		case .activeSpaceChanged:
			requestRefresh(pids: .all, readFocus: true, delay: 0.300, reason: "space changed")

		case .screenParametersChanged:
			raiseBarrier(.displayChanging)
			startStabilitySampler { [weak self] in
				guard let self = self else { return }
				self.clearBarrier(.displayChanging)
			}

		case .willSleep:
			raiseBarrier(.asleep)

		case .didWake:
			clearBarrier(.asleep)

		case .screenLocked:
			raiseBarrier(.locked)

		case .screenUnlocked:
			clearBarrier(.locked)

		case .leftMouseUp:
			if state.barrier.contains(.asleep) {
				clearBarrier(.asleep)
			}
			requestRefresh(readFocus: true, readFrames: true, delay: 0.030, reason: "left mouse up")

		case .missionControl(let active):
			if active {
				raiseBarrier(.missionControl)
			} else {
				clearBarrier(.missionControl)
			}

		case .untrackedWindows(let pid, _):
			requestRefresh(pids: .some([pid]), delay: 0.030, reason: "watcher untracked")

		case .missingWindows(let pid, let ids):
			var destroyedMap: [WindowID: PID?] = [:]
			for id in ids {
				destroyedMap[id] = pid
			}
			requestRefresh(pids: .some([pid]), destroyed: destroyedMap, delay: 0.030, reason: "watcher missing")

		case .hiddenWindowsVisible:
			requestRefresh(readFrames: true, delay: 0.030, reason: "watcher hidden visible")
		}
	}

	// MARK: - Observer Failure Handling

	private func handleObserverFailed(pid: PID) {
		let status = axEventSource.observerStatus(of: pid) ?? .pending
		if loggedObserverFailures[pid] == status {
			return
		}
		loggedObserverFailures[pid] = status

		let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
		let detail: String
		switch status {
		case .retrying(let retryAt, _, _):
			let remaining = max(0, retryAt - ProcessInfo.processInfo.systemUptime)
			detail = "retry in \(Int(remaining.rounded()))s"
		case .gaveUp(let failures, let error):
			detail = "gave up after \(failures) failures (error \(error))"
		default:
			detail = "retry in 2s"
		}
		PerfLog.event("shadow: observer failed for \(appName); \(detail)")
	}

	// MARK: - Barrier Management

	private func raiseBarrier(_ reason: BarrierReason) {
		let now = ProcessInfo.processInfo.systemUptime
		stabilityTimer?.cancel()
		stabilityTimer = nil
		state.setBarrier(reason, active: true, now: now)
		drainLog()
		if reason == .locked {
			startLockCheckTimer()
		}
	}

	private func clearBarrier(_ reason: BarrierReason) {
		let now = ProcessInfo.processInfo.systemUptime
		if reason == .locked {
			stopLockCheckTimer()
		}
		guard state.barrier.contains(reason) else { return }
		state.setBarrier(reason, active: false, now: now)
		drainLog()

		if state.barrier.isEmpty {
			startStabilitySampler { [weak self] in
				guard let self = self else { return }
				let exitNow = ProcessInfo.processInfo.systemUptime
				self.state.reconcileTopology(DisplayReader.read(), now: exitNow)
				self.drainLog()
				self.requestRefresh(pids: .all, readFocus: true, delay: 0, reason: "barrier exit")
			}
		}
	}

	private func startLockCheckTimer() {
		lockCheckTimer?.cancel()
		let timer = DispatchSource.makeTimerSource(queue: .main)
		timer.schedule(deadline: .now() + 2.0, repeating: 2.0, leeway: .milliseconds(100))
		timer.setEventHandler { [weak self] in
			guard let self = self else { return }
			if !SystemSignals.isScreenLocked() && !SystemSignals.isLoginWindowFrontmost {
				self.clearBarrier(.locked)
			}
		}
		timer.resume()
		self.lockCheckTimer = timer
	}

	private func stopLockCheckTimer() {
		lockCheckTimer?.cancel()
		lockCheckTimer = nil
	}

	private func startStabilitySampler(completion: @escaping () -> Void) {
		stabilityTimer?.cancel()
		stabilityConsecutiveTicks = 0
		lastStabilitySignature = nil
		stabilityStartTime = ProcessInfo.processInfo.systemUptime

		let timer = DispatchSource.makeTimerSource(queue: .main)
		timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(10))
		timer.setEventHandler { [weak self] in
			guard let self = self else { return }
			let now = ProcessInfo.processInfo.systemUptime
			let sig = DisplayReader.signature()

			if sig.isDegenerate {
				self.stabilityConsecutiveTicks = 0
				self.lastStabilitySignature = nil
				return
			}

			if sig == self.lastStabilitySignature {
				self.stabilityConsecutiveTicks += 1
			} else {
				self.lastStabilitySignature = sig
				self.stabilityConsecutiveTicks = 1
			}

			if self.stabilityConsecutiveTicks >= 5 || (now - self.stabilityStartTime >= 5.0 && !sig.isDegenerate) {
				self.stabilityTimer?.cancel()
				self.stabilityTimer = nil
				completion()
			}
		}
		timer.resume()
		self.stabilityTimer = timer
	}

	// MARK: - Coalescing and Refresh Scheduling

	private func requestRefresh(
		pids: RefreshRequest.PIDs = .none,
		windowsToRead: Set<WindowID> = [],
		readFocus: Bool = false,
		readFrames: Bool = false,
		destroyed: [WindowID: PID?] = [:],
		delay: TimeInterval,
		reason: String
	) {
		let now = ProcessInfo.processInfo.systemUptime
		let req = RefreshRequest(
			pids: pids,
			windowsToRead: windowsToRead,
			readFocus: readFocus,
			readFrames: readFrames,
			destroyed: destroyed,
			reasons: [reason],
			deadline: now + delay
		)

		if isPassInFlight {
			if nextRequest == nil {
				nextRequest = req
			} else {
				nextRequest?.merge(with: req)
			}
			return
		}

		if pendingRequest == nil {
			pendingRequest = req
		} else {
			pendingRequest?.merge(with: req)
		}

		schedulePassTimer()
	}

	private func schedulePassTimer() {
		guard let req = pendingRequest else { return }
		refreshTimer?.cancel()
		let now = ProcessInfo.processInfo.systemUptime
		let delay = max(0, req.deadline - now)

		let timer = DispatchSource.makeTimerSource(queue: .main)
		timer.schedule(deadline: .now() + delay, leeway: .milliseconds(5))
		timer.setEventHandler { [weak self] in
			self?.refreshTimer?.cancel()
			self?.refreshTimer = nil
			self?.checkAndStartPass()
		}
		timer.resume()
		self.refreshTimer = timer
	}

	private func checkAndStartPass() {
		guard !isPassInFlight, let request = pendingRequest else { return }
		if !state.barrier.isEmpty {
			return
		}
		pendingRequest = nil
		executePass(request: request)
	}

	// MARK: - Pipeline Execution

	private func executePass(request: RefreshRequest) {
		isPassInFlight = true

		// Step 1: Gather (async, off main)
		let pidsToScan: [PID]
		switch request.pids {
		case .all:
			pidsToScan = NSWorkspace.shared.runningApplications
				.filter { $0.activationPolicy == .regular && $0.processIdentifier != state.ownPID && $0.bundleIdentifier != SystemSignals.loginWindowBundleID }
				.map(\.processIdentifier)
		case .some(let set):
			pidsToScan = Array(set).filter { $0 != state.ownPID }
		case .none:
			pidsToScan = []
		}

		let windowsToRead = Array(request.windowsToRead)
		let shouldReadFocus = request.readFocus

		let group = DispatchGroup()
		var scanResults: [PID: ScanResult] = [:]
		var readResult = WindowReadResult()
		var focusFacts: FocusFacts?

		if !pidsToScan.isEmpty {
			group.enter()
			WindowEnumerator.scan(pids: pidsToScan) { results in
				scanResults = results
				group.leave()
			}
		}

		if !windowsToRead.isEmpty {
			group.enter()
			WindowEnumerator.read(windows: windowsToRead) { results in
				readResult = results
				group.leave()
			}
		}

		if shouldReadFocus {
			group.enter()
			FocusReader.read { facts in
				focusFacts = facts
				group.leave()
			}
		}

		group.notify(queue: .main) { [weak self] in
			guard let self = self else { return }
			self.completePass(
				request: request,
				scanResults: scanResults,
				readResult: readResult,
				focusFacts: focusFacts
			)
		}
	}

	private func completePass(
		request: RefreshRequest,
		scanResults: [PID: ScanResult],
		readResult: WindowReadResult,
		focusFacts: FocusFacts?
	) {
		let now = ProcessInfo.processInfo.systemUptime

		// Step 2: Observe (main)
		let snapshot = ServerProbe.onScreen(now: now)
		let probeCandidates = state.probeCandidates(scans: scanResults, destroyed: Set(request.destroyed.keys))
		let probeSnapshot = ServerProbe.exists(probeCandidates, now: now)
		let serverHas = Set(probeSnapshot.windows.keys)

		// Step 3: Ingest (main)
		state.ingestServer(snapshot)

		for (pid, result) in scanResults {
			state.ingestScan(pid: pid, result: result, serverHas: serverHas, now: now)
		}

		if !readResult.facts.isEmpty {
			state.ingestWindowFacts(readResult.facts, now: now)
		}

		for (id, pid) in request.destroyed {
			state.ingestDestroyed(id: id, pid: pid, serverHas: serverHas.contains(id), now: now)
		}

		if let focus = focusFacts {
			state.ingestFocus(focus, now: now)
		}

		// Register observation for newly admitted and re-observed elements
		for id in state.records.keys {
			if let element = ElementCache.shared.windowElement(id), let pid = state.records[id]?.pid {
				axEventSource.watchWindow(id, pid: pid, element: element)
			}
		}

		let reobserve = state.livenessDrainReobserve()
		for id in reobserve {
			if let element = ElementCache.shared.windowElement(id), let pid = state.records[id]?.pid {
				axEventSource.watchWindow(id, pid: pid, element: element)
			}
		}

		if state.barrier.isEmpty && state.livenessState.liftPending {
			state.liftBarrier(now: now)
		} else {
			state.pairReplacements(now: now)
		}

		// Step 4: Normalize
		state.normalize(now: now)

		// Step 5: Plan
		_ = state.plan(snapshot: snapshot, options: PlanOptions(), now: now)

		// Step 6: Execute
		// Mode .shadow ONLY: never execute plans or move any window

		// Step 7: Drain log and fan out feature events
		drainLog()
		fanOutEvents()

		// Step 8: Schedule follow-ups
		scheduleFollowUps(now: now)

		isPassInFlight = false

		if let next = nextRequest {
			nextRequest = nil
			if pendingRequest == nil {
				pendingRequest = next
			} else {
				pendingRequest?.merge(with: next)
			}
			schedulePassTimer()
		}
	}

	// MARK: - Follow-up Scheduling

	private func scheduleFollowUps(now: Time) {
		let followUps = state.followUps(now: now)
		for followUp in followUps {
			let delay = max(0, followUp.at - now)
			switch followUp.kind {
			case .scan(let pid):
				requestRefresh(pids: .some([pid]), delay: delay, reason: followUp.reason)
			case .readWindow(let id):
				requestRefresh(windowsToRead: [id], delay: delay, reason: followUp.reason)
			case .frames:
				requestRefresh(readFrames: true, delay: delay, reason: followUp.reason)
			}
		}
	}

	// MARK: - Logging and Feature Fan-out

	private func drainLog() {
		let logs = state.drainLog()
		for entry in logs {
			let line = entry.message
			let formatted: String
			if line.hasPrefix("track: admit ") {
				formatted = "shadow: admit " + line.dropFirst("track: admit ".count)
			} else if line.hasPrefix("track: retire ") {
				formatted = "shadow: retire " + line.dropFirst("track: retire ".count)
			} else if line.hasPrefix("track: keep ") {
				formatted = "shadow: keep " + line.dropFirst("track: keep ".count)
			} else if line.hasPrefix("track: app ") && line.contains("unreadable") {
				formatted = "shadow: app " + line.dropFirst("track: app ".count)
			} else if line.hasPrefix("track: ") {
				formatted = "shadow: " + line.dropFirst("track: ".count)
			} else if line.hasPrefix("barrier: ") {
				formatted = "shadow: barrier: " + line.dropFirst("barrier: ".count)
			} else if line.hasPrefix("topology: ") {
				formatted = "shadow: topology: " + line.dropFirst("topology: ".count)
			} else if line.hasPrefix("shadow:") {
				formatted = line
			} else {
				formatted = "shadow: " + line
			}
			PerfLog.event(formatted)
		}
	}

	private func fanOutEvents() {
		let events = state.drainEvents()
		for event in events {
			switch event {
			case .admitted(let id):
				onAdmitted?(id)
			case .retired(let id, let reason):
				axEventSource.unwatchWindow(id)
				recordShadowRetire(id)
				onRetired?(id, reason)
			case .rekeyed(let from, let to):
				axEventSource.unwatchWindow(from)
				if let element = ElementCache.shared.windowElement(to), let pid = state.records[to]?.pid {
					axEventSource.watchWindow(to, pid: pid, element: element)
				}
				onRekeyed?(from, to)
			case .activeChanged(let monitor, let from, let to, let cause):
				onActiveChanged?(monitor, from, to, cause)
			case .zenEnded(let reason):
				onZenEnded?(reason)
			case .focusChanged(let from, let to):
				onFocusChanged?(from, to)
			case .returnFocus(let bundleID):
				onReturnFocus?(bundleID)
			}
		}
	}

	// MARK: - Shadow Self-Checks and Cross-Checks

	private func recordShadowRetire(_ id: WindowID) {
		recentlyRetiredInShadow[id] = ProcessInfo.processInfo.systemUptime
		DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
			guard let self = self, self.mode == .shadow else { return }
			let now = ProcessInfo.processInfo.systemUptime
			let probe = ServerProbe.exists([id], now: now)
			if probe.windows[id] != nil {
				PerfLog.event("shadow: WRONG retire #\(id) (window server still has it 2s later)")
			}
		}
	}

	func reportLegacyWindowClosed(_ id: WindowID) {
		guard mode == .shadow else { return }
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
			guard let self = self, self.mode == .shadow else { return }
			if self.state.tombstones.contains(id) || self.recentlyRetiredInShadow[id] != nil {
				return
			}
			let now = ProcessInfo.processInfo.systemUptime
			let probe = ServerProbe.exists([id], now: now)
			if probe.windows[id] == nil {
				PerfLog.event("shadow: missing retire #\(id) (old loop closed it and the window server no longer has it)")
			}
		}
	}

	func reportLegacyWindowAppeared(_ id: WindowID) {
		// Hook for appearance cross-check
	}

	// MARK: - Watcher Context Provider

	private func buildWatcherContext() -> WindowServerWatcher.Context {
		var context = WindowServerWatcher.Context(isPaused: !state.barrier.isEmpty)
		context.regularPIDs = Set(
			NSWorkspace.shared.runningApplications
				.filter { $0.activationPolicy == .regular && $0.processIdentifier != state.ownPID && $0.bundleIdentifier != SystemSignals.loginWindowBundleID }
				.map(\.processIdentifier)
		)
		context.unreadablePIDs = Set(
			state.apps.values.filter { $0.unresponsiveSince != nil || $0.lastScan == .incomplete }.map(\.pid)
		)
		context.tracked = Set(state.records.keys)

		var onScreen: [WindowID: WindowServerWatcher.Context.Expectation] = [:]
		for (id, record) in state.records {
			guard record.observed.listedInLastCompleteScan,
				!record.observed.isMinimized,
				!record.observed.isFullscreen,
				state.apps[record.pid]?.isHidden != true,
				!record.observed.isServerGhost else { continue }
			switch record.visibility {
			case .visible, .parked, .zenHidden, .paletteHidden:
				onScreen[id] = WindowServerWatcher.Context.Expectation(
					pid: record.pid,
					isHidden: state.isHidden(id))
			case .axisMinimized, .nativeMinimized, .nativeFullscreen, .otherSpace, .appHidden:
				break
			}
		}
		context.onScreen = onScreen
		context.monitors = Array(state.monitors.values)
		context.expectedFrame = { [weak self] id in
			self?.state.expectedFrame(id)
		}
		return context
	}

	// MARK: - Command API Stubs

	@discardableResult
	func perform(_ name: String, hidePhaseDelay: TimeInterval = 0, mutate: (inout TrackingState) -> Void) -> Plan? {
		let now = ProcessInfo.processInfo.systemUptime
		let snapshot = ServerProbe.onScreen(now: now)
		mutate(&state)
		state.ingestServer(snapshot)
		state.normalize(now: now)
		let plan = state.plan(snapshot: snapshot, options: PlanOptions(isCommand: true), now: now)
		if mode != .shadow {
			let results = WindowActuator.execute(plan)
			state.recordWrites(results, now: now)
		}
		drainLog()
		fanOutEvents()
		scheduleFollowUps(now: now)
		return plan
	}

	func switchWorkspace(on monitor: MonitorKey, to target: WorkspaceTarget) {
		perform("switchWorkspace") { state in
			state.switchWorkspace(on: monitor, to: target)
		}
	}

	func tile(on monitor: MonitorKey? = nil) {
		perform("tile") { _ in }
	}

	func moveWindow(_ id: WindowID, direction: MoveDirection) {
		perform("moveWindow") { state in
			_ = state.moveWindow(id, direction)
		}
	}

	func toggleFloat(_ id: WindowID) {
		perform("toggleFloat") { state in
			_ = state.toggleFloat(id)
		}
	}

	func hideWindow(_ id: WindowID) {
		perform("hideWindow") { state in
			state.hide(id)
		}
	}

	func unhideLastWindow() {
		perform("unhideLastWindow") { state in
			_ = state.unhideLast()
		}
	}

	func zenEnter(_ id: WindowID) {
		let now = ProcessInfo.processInfo.systemUptime
		perform("zenEnter") { state in
			state.zenEnter(id, now: now)
		}
	}

	func zenExit(reason: ZenExitReason = .user) {
		perform("zenExit") { state in
			state.zenExit(reason: reason)
		}
	}
}
