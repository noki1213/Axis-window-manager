//
//	TrackingCoordinator.swift
//	Axis
//
//	The single writer of the window-tracking state, on the main thread. Signals from the
//	Accessibility observers, the system notifications and the window-server watcher become
//	refresh work; one pass at a time gathers facts off the main thread (app scans, window reads,
//	the focused window), then observes the window server and ingests and normalizes on the main
//	thread. Barriers (startup, lock, sleep, display changes, Mission Control) hold the passes
//	back; once every reason has ended and the displays have been stable for a moment, the
//	monitors are reconciled and a full rescan lifts the barrier.
//
//	Shadow mode tracks and logs only: it plans nothing and writes nothing, so every window stays
//	with the window management that runs alongside it, and each line it logs starts with
//	"shadow:" so the two can be compared in the event log.
//
//	State-only mode makes the state the source of truth for workspaces, columns and the hide
//	stack: commands change it and their plans are executed. Windows come and go through the
//	caller (registrations, retirements and window facts), so no observer, watcher or scan runs.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class TrackingCoordinator {
	static let shared = TrackingCoordinator()

	enum Mode {
		/// Tracks and logs; never plans, writes, focuses or changes what other components see.
		case shadow
		/// Commands and registrations from the caller change the state and their plans are
		/// executed; nothing is discovered by the coordinator itself.
		case stateOnly
	}

	private(set) var mode: Mode = .shadow
	private(set) var isRunning = false
	/// Read through the core's queries; only the coordinator changes it.
	private(set) var state: TrackingState

	/// Windows that another component still moves by itself (Zen and the palette park and
	/// restore their windows); plans leave them alone.
	var externallyPositioned: () -> Set<WindowID> = { [] }

	// MARK: Feature events

	var onAdmitted: ((WindowID) -> Void)?
	var onRetired: ((WindowID, RetireReason) -> Void)?
	var onRekeyed: ((WindowID, WindowID) -> Void)?
	var onActiveChanged: ((MonitorKey, WorkspaceID?, WorkspaceID, ActiveChangeCause) -> Void)?
	var onZenEnded: ((ZenExitReason) -> Void)?
	var onFocusChanged: ((WindowID?, WindowID?) -> Void)?
	var onReturnFocus: ((String) -> Void)?

	// MARK: Sources

	private let axEventSource = AXEventSource()
	private let systemSignals = SystemSignals()
	private let watcher = WindowServerWatcher()
	private let ownPID = ProcessInfo.processInfo.processIdentifier

	// MARK: Passes

	private var pending = PendingWork()
	private var inFlight: CoordinatorPass?
	private var passCounter = 0
	private var lastPassEndedAt: Time = -.infinity
	private var passTimer: DispatchSourceTimer?
	private var passRateWindowStart: Time = 0
	private var passRateCount = 0
	private var passRateLoggedAt: Time = -.infinity

	// MARK: Barriers

	/// Reasons that ended but stay raised in the state until the displays have settled, so nothing
	/// is ingested or retired before the full rescan that lifts the barrier.
	private var endingReasons: Set<BarrierReason> = []
	/// Every raised reason has ended; the displays are sampled before the barrier lifts.
	private var isSettling = false
	/// The next pass is the full rescan that lifts the barrier.
	private var liftOnNextPass = false
	/// Goes up with every raised reason. A pass started under an older epoch gathered while a
	/// barrier went up, so its facts are dropped and its work is done again after the barrier.
	private var barrierEpoch = 0
	private var sampler: DispatchSourceTimer?
	private var samplerStartedAt: Time = 0
	private var sampledSignature: DisplaySignature?
	private var sampledSince: Time = 0
	private var lockTimer: DispatchSourceTimer?
	private var asleepTimer: DispatchSourceTimer?

	// MARK: Bookkeeping

	/// Tracked windows whose window notifications were handed to the observer thread.
	private var watchedWindows: Set<WindowID> = []
	/// What the window-server watcher reads 20 times a second; rebuilt only after a change.
	private var watcherContext: WindowServerWatcher.Context?
	/// Apps whose observer gave up, logged once until a new round of attempts fails again.
	private var observerGaveUpLogged: Set<PID> = []
	private var lastTopologyLine: String?
	private var lastInvariantProblems: [String] = []
	/// Windows the loop running alongside closed a second ago that the shadow still tracks.
	private var awaitingRetire: [WindowID: AwaitedRetire] = [:]
	/// Apps of tracked windows, so window handles are built without looking the process up.
	private var runningApps: [PID: NSRunningApplication] = [:]

	/// The barriers the watcher sits out. Mission Control is not one of them: the watcher is
	/// what notices it close.
	private static let watcherPausingBarriers: Set<BarrierReason> = [.starting, .locked, .asleep, .displayChanging]

	#if DEBUG
	private static let checksInvariantsInEveryMode = true
	#else
	private static let checksInvariantsInEveryMode = false
	#endif

	private init() {
		state = TrackingState(config: LayoutConfig(), ownPID: ProcessInfo.processInfo.processIdentifier)
	}

	// MARK: - Lifecycle

	/// Starts tracking. The "starting" barrier holds every pass until the displays are stable;
	/// then the monitors are read and a full scan admits the windows of every app.
	///
	/// In state-only mode the monitors are read at once and the state waits for the caller's
	/// registrations. `relaunchTiled`: windows that were tiled when Axis last quit, so they tile
	/// again even where a stacked column left them looking like small dialogs.
	func start(mode: Mode = .shadow, config: LayoutConfig = LayoutConfig(), relaunchTiled: Set<WindowID> = []) {
		guard !isRunning else { return }
		self.mode = mode
		isRunning = true
		let now = Self.uptime()
		state = TrackingState(config: config, ownPID: ownPID)
		state.relaunchTiled = relaunchTiled
		pending = PendingWork()
		inFlight = nil
		endingReasons = []
		isSettling = false
		liftOnNextPass = false
		barrierEpoch += 1
		watchedWindows = []
		watcherContext = nil
		observerGaveUpLogged = []
		lastTopologyLine = nil
		lastInvariantProblems = []
		awaitingRetire = [:]
		runningApps = [:]

		let timer = DispatchSource.makeTimerSource(queue: .main)
		timer.setEventHandler { [weak self] in
			self?.passTimerFired()
		}
		timer.schedule(deadline: .distantFuture)
		timer.resume()
		passTimer = timer

		guard mode != .stateOnly else {
			state.reconcileTopology(DisplayReader.read(), now: now)
			finishStep(now: now)
			return
		}
		state.setBarrier(.starting, active: true, now: now)
		drainLog()

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
			self?.currentWatcherContext() ?? WindowServerWatcher.Context(isPaused: true)
		}
		watcher.start()

		for app in NSWorkspace.shared.runningApplications where isTrackable(app) {
			axEventSource.register(pid: app.processIdentifier)
		}
		if SystemSignals.isScreenLocked() || SystemSignals.isLoginWindowFrontmost {
			raiseBarrier(.locked)
		}
		endBarrier(.starting)
	}

	func stop() {
		guard isRunning else { return }
		isRunning = false
		for timer in [passTimer, sampler, lockTimer, asleepTimer] {
			timer?.cancel()
		}
		passTimer = nil
		sampler = nil
		lockTimer = nil
		asleepTimer = nil
		inFlight = nil
		pending = PendingWork()
		watcher.stop()
		watcher.sink = nil
		watcher.contextProvider = nil
		systemSignals.stop()
		axEventSource.stop()
	}

	// MARK: - Signals

	private func receive(_ signal: TrackingSignal) {
		guard isRunning else { return }
		let now = Self.uptime()
		switch signal {
		case .windowCreated(let pid):
			state.livenessNoteCreated(pid: pid, now: now)
			pending.addScan(pid, due: now + CoordinatorTiming.event)

		case .windowDestroyed(let id, let pid):
			// The observer thread ended the window's watch. A window that turns out to be alive
			// comes back through the core's re-observe list with its new element.
			pending.addDestroyed(id, pid: pid, due: now + CoordinatorTiming.event)

		case .windowMiniaturized(let id, _), .windowDeminiaturized(let id, _):
			pending.addRead(id, due: now + CoordinatorTiming.event)

		case .windowMoved, .windowResized:
			pending.addFrames(due: now + CoordinatorTiming.frames)

		case .focusedWindowChanged:
			pending.addFocus(due: now + CoordinatorTiming.event)

		case .observerFailed(let pid):
			noteObserverFailure(pid)

		case .appLaunched(let pid):
			guard let app = trackableApp(pid) else { return }
			axEventSource.register(pid: pid)
			state.livenessNoteLaunched(Self.appFacts(app), now: now)
			pending.addScan(pid, due: now + CoordinatorTiming.launch)
			watcherContext = nil

		case .appTerminated(let pid):
			appQuit(pid, now: now)
			if state.barrier.isEmpty {
				state.pairReplacements(now: now)
				state.normalize(now: now)
			}
			finishStep(now: now)
			return

		case .appActivated(let pid):
			// An app can become a regular app after it launched; this registers it then.
			if trackableApp(pid) != nil {
				axEventSource.register(pid: pid)
			}
			pending.addFocus(due: now + CoordinatorTiming.event)
			watcherContext = nil

		case .appHidden(let pid), .appUnhidden(let pid):
			state.ingestApps(appFacts(for: [pid]), now: now)
			pending.addFrames(due: now + CoordinatorTiming.event)
			watcherContext = nil

		case .activeSpaceChanged:
			pending.addScanAll(due: now + CoordinatorTiming.spaceChange)
			pending.addFocus(due: now + CoordinatorTiming.spaceChange)

		case .screenParametersChanged:
			raiseBarrier(.displayChanging)
			// The configuration changed again: it has to stay unchanged from here on.
			sampledSignature = nil

		case .willSleep:
			raiseBarrier(.asleep)

		case .didWake:
			endBarrier(.asleep)

		case .screenLocked:
			raiseBarrier(.locked)

		case .screenUnlocked:
			endBarrier(.locked)

		case .leftMouseUp:
			// Someone is using the Mac: a wake notification that never came does not keep
			// tracking off.
			endBarrier(.asleep)
			pending.addFocus(due: now + CoordinatorTiming.frames)
			pending.addFrames(due: now + CoordinatorTiming.frames)

		case .missionControl(let active):
			if active {
				raiseBarrier(.missionControl)
			} else {
				endBarrier(.missionControl)
			}

		case .untrackedWindows(let pid, _), .missingWindows(let pid, _):
			// A scan decides: a window missing from the screen may be minimized, fullscreen or on
			// another Space, which only the app's window list and the window server can tell
			// apart from a closed one.
			pending.addScan(pid, due: now + CoordinatorTiming.frames)

		case .hiddenWindowsVisible:
			pending.addFrames(due: now + CoordinatorTiming.frames)
		}
		schedulePassTimer()
	}

	/// Drops what is kept for an app that quit and retires its windows (held during a barrier).
	private func appQuit(_ pid: PID, now: Time) {
		axEventSource.unregister(pid: pid)
		ElementCache.shared.remove(pid: pid)
		pending.scans[pid] = nil
		observerGaveUpLogged.remove(pid)
		state.ingestTerminated(pid: pid, now: now)
	}

	/// At most two lines per round of failing attempts: when the retry after the first failure
	/// failed too (an app still starting up often refuses once), and when the attempts give up.
	private func noteObserverFailure(_ pid: PID) {
		guard let status = axEventSource.observerStatus(of: pid) else { return }
		let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
		switch status {
		case .retrying(let retryAt, let failures, let error) where failures == 2:
			observerGaveUpLogged.remove(pid)
			let delay = max(0, retryAt - Self.uptime())
			event("track: observer failed for \(name) (error \(error), \(failures) attempts); retry in \(String(format: "%.1f", delay))s")
		case .gaveUp(let failures, let error):
			guard observerGaveUpLogged.insert(pid).inserted else { return }
			event("track: observer failed for \(name); gave up after \(failures) failures (error \(error))")
		default:
			break
		}
	}

	// MARK: - Barriers

	private func raiseBarrier(_ reason: BarrierReason) {
		let now = Self.uptime()
		barrierEpoch += 1
		liftOnNextPass = false
		isSettling = false
		endingReasons.remove(reason)
		if !state.barrier.contains(reason) {
			state.setBarrier(reason, active: true, now: now)
			drainLog()
		}
		if reason == .asleep {
			startAsleepTimer()
		}
		updateBarrierTimers()
		watcherContext = nil
		schedulePassTimer()
	}

	/// The reason is over. The barrier lifts once every reason is over and the displays have
	/// settled; `settled` says they just did.
	private func endBarrier(_ reason: BarrierReason, settled: Bool = false) {
		guard state.barrier.contains(reason), !endingReasons.contains(reason) else { return }
		endingReasons.insert(reason)
		watcherContext = nil
		if endingReasons.isSuperset(of: state.barrier) {
			if settled {
				exitBarrier()
				return
			}
			isSettling = true
		}
		updateBarrierTimers()
	}

	/// Clears every reason, reconciles the monitors and queues the full rescan that completes
	/// the exit (the core's `liftBarrier`).
	private func exitBarrier() {
		isSettling = false
		// A lock notification can go missing: the session state has the last word.
		if SystemSignals.isScreenLocked() || SystemSignals.isLoginWindowFrontmost {
			raiseBarrier(.locked)
			return
		}
		let displays = DisplayReader.read()
		guard !DisplaySignature(displays).isDegenerate else {
			// The configuration fell apart again since the last sample: settle once more.
			isSettling = true
			updateBarrierTimers()
			return
		}
		let now = Self.uptime()
		for reason in BarrierReason.allCases where endingReasons.contains(reason) {
			state.setBarrier(reason, active: false, now: now)
		}
		endingReasons = []
		state.reconcileTopology(displays, now: now)
		liftOnNextPass = true
		pending.addScanAll(due: now)
		pending.addFocus(due: now)
		updateBarrierTimers()
		finishStep(now: now)
	}

	private func updateBarrierTimers() {
		let active = state.barrier.subtracting(endingReasons)
		if active.contains(.displayChanging) || isSettling {
			startSampler()
		} else {
			stopTimer(&sampler)
		}
		if active.contains(.locked) {
			startLockTimer()
		} else {
			stopTimer(&lockTimer)
		}
		if !active.contains(.asleep) {
			stopTimer(&asleepTimer)
		}
	}

	private func startSampler() {
		guard sampler == nil else { return }
		samplerStartedAt = Self.uptime()
		sampledSignature = nil
		let timer = DispatchSource.makeTimerSource(queue: .main)
		timer.schedule(deadline: .now(), repeating: CoordinatorTiming.sampleInterval, leeway: .milliseconds(10))
		timer.setEventHandler { [weak self] in
			self?.sampleDisplays()
		}
		timer.resume()
		sampler = timer
	}

	/// Settled = the same non-degenerate configuration for `settledAfter`, or sampled for
	/// `settleCap` with something to show. macOS reports no screen or a zero-size one while it
	/// rebuilds the configuration; that never counts.
	private func sampleDisplays() {
		let now = Self.uptime()
		let signature = DisplayReader.signature()
		guard !signature.isDegenerate else {
			sampledSignature = nil
			return
		}
		if signature != sampledSignature {
			sampledSignature = signature
			sampledSince = now
		}
		let stable = now - sampledSince >= CoordinatorTiming.settledAfter - 0.001
		let capped = now - samplerStartedAt >= CoordinatorTiming.settleCap
		guard stable || capped else { return }
		stopTimer(&sampler)
		if state.barrier.contains(.displayChanging), !endingReasons.contains(.displayChanging) {
			endBarrier(.displayChanging, settled: true)
		} else if isSettling {
			exitBarrier()
		}
	}

	/// While locked, the session state is checked every few seconds: the unlock notification
	/// can go missing.
	private func startLockTimer() {
		guard lockTimer == nil else { return }
		let timer = DispatchSource.makeTimerSource(queue: .main)
		timer.schedule(deadline: .now() + CoordinatorTiming.lockCheckInterval,
			repeating: CoordinatorTiming.lockCheckInterval, leeway: .milliseconds(100))
		timer.setEventHandler { [weak self] in
			guard !SystemSignals.isScreenLocked(), !SystemSignals.isLoginWindowFrontmost else { return }
			self?.endBarrier(.locked)
		}
		timer.resume()
		lockTimer = timer
	}

	/// The wake notification can go missing, or the sleep never happen. The timer runs on the
	/// uptime clock, which stands still while the Mac sleeps, so it counts awake time only.
	private func startAsleepTimer() {
		stopTimer(&asleepTimer)
		let timer = DispatchSource.makeTimerSource(queue: .main)
		timer.schedule(deadline: .now() + CoordinatorTiming.asleepLimit)
		timer.setEventHandler { [weak self] in
			guard let self else { return }
			self.stopTimer(&self.asleepTimer)
			guard self.state.barrier.contains(.asleep), !self.endingReasons.contains(.asleep) else { return }
			self.event("barrier: no wake notification \(Int(CoordinatorTiming.asleepLimit))s after sleep was announced; ending asleep")
			self.endBarrier(.asleep)
		}
		timer.resume()
		asleepTimer = timer
	}

	private func stopTimer(_ timer: inout DispatchSourceTimer?) {
		timer?.cancel()
		timer = nil
	}

	// MARK: - Passes

	private func schedulePassTimer() {
		guard let passTimer else { return }
		guard isRunning, inFlight == nil, state.barrier.isEmpty, let due = pending.earliest else {
			// No pass while a barrier is up; its exit queues the rescan.
			passTimer.schedule(deadline: .distantFuture)
			return
		}
		let at = max(due, lastPassEndedAt + CoordinatorTiming.passSpacing)
		passTimer.schedule(deadline: .now() + max(0, at - Self.uptime()), leeway: .milliseconds(5))
	}

	private func passTimerFired() {
		guard isRunning, inFlight == nil, state.barrier.isEmpty else { return }
		let limit = Self.uptime() + CoordinatorTiming.coalescing
		guard let due = pending.earliest, due <= limit else {
			schedulePassTimer()
			return
		}
		let work = pending.take(dueBy: limit)
		let lifts = liftOnNextPass
		liftOnNextPass = false
		startPass(work, liftsBarrier: lifts)
	}

	/// Step 1: the gather, off the main thread. Scans and window reads answer within the
	/// enumerator's deadline; the gather's own deadline also covers the focused-window read.
	private func startPass(_ work: PassWork, liftsBarrier: Bool) {
		passCounter += 1
		notePassRate()
		let pass = CoordinatorPass(number: passCounter, epoch: barrierEpoch, liftsBarrier: liftsBarrier,
			work: work, pids: scanTargets(for: work))
		inFlight = pass
		let gather = PassGather()
		let reads = work.reads.sorted()
		gather.outstanding = (pass.pids.isEmpty ? 0 : 1) + (reads.isEmpty ? 0 : 1) + (work.focus ? 1 : 0)
		guard gather.outstanding > 0 else {
			completePass(pass, gather: gather)
			return
		}
		if !pass.pids.isEmpty {
			WindowEnumerator.scan(pids: pass.pids) { [weak self] results in
				gather.scans = results
				self?.gatherAnswered(pass, gather)
			}
		}
		if !reads.isEmpty {
			WindowEnumerator.read(windows: reads) { [weak self] result in
				gather.reads = result
				self?.gatherAnswered(pass, gather)
			}
		}
		if work.focus {
			FocusReader.read { [weak self] facts in
				gather.focus = facts
				self?.gatherAnswered(pass, gather)
			}
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + CoordinatorTiming.gatherDeadline) { [weak self] in
			self?.finishGather(pass, gather)
		}
	}

	private func gatherAnswered(_ pass: CoordinatorPass, _ gather: PassGather) {
		gather.outstanding -= 1
		if gather.outstanding <= 0 {
			finishGather(pass, gather)
		}
	}

	/// The first of "everything answered" and the deadline completes the pass; answers after
	/// that are dropped.
	private func finishGather(_ pass: CoordinatorPass, _ gather: PassGather) {
		guard !gather.isFinished else { return }
		gather.isFinished = true
		completePass(pass, gather: gather)
	}

	private func completePass(_ pass: CoordinatorPass, gather: PassGather) {
		guard inFlight?.number == pass.number else { return }
		inFlight = nil
		let now = Self.uptime()
		lastPassEndedAt = now
		guard isRunning else { return }
		guard pass.epoch == barrierEpoch, state.barrier.isEmpty else {
			// Facts gathered while a barrier went up may show the lock screen, a sleeping display or
			// Mission Control: the work is done again after the barrier.
			pending.requeue(pass.work, due: now)
			schedulePassTimer()
			return
		}
		let snapshot = PerfLog.measure("tracking.pass", threshold: CoordinatorTiming.slowPass) {
			ingest(pass, gather: gather, now: now)
		}
		if mode == .stateOnly {
			planAndExecute(snapshot, isCommand: false, includeHidePhase: true, now: now)
		}
		finishStep(now: now)
	}

	/// Steps 2 to 4: observe the window server, ingest, end the ingest, normalize. Returns the
	/// window-server snapshot the plan is made against.
	@discardableResult
	private func ingest(_ pass: CoordinatorPass, gather: PassGather, now: Time) -> ServerSnapshot {
		var scans = gather.scans ?? [:]
		for pid in pass.pids where scans[pid] == nil {
			// Not answered by the deadline: the app counts as not answering.
			scans[pid] = .timedOut
		}
		// An app that quit while it was scanned has no windows left to judge, and a failed scan
		// of it would schedule retries for a process that is gone.
		for pid in scans.keys.sorted() where !Self.isProcessAlive(pid) {
			scans[pid] = nil
			appQuit(pid, now: now)
		}
		let scannedPIDs = scans.keys.sorted()

		let snapshot = ServerProbe.onScreen(now: now)
		let candidates = state.probeCandidates(scans: scans, destroyed: Set(pass.work.destroyed.keys))
		let serverHas = Set(ServerProbe.exists(candidates, now: now).windows.keys)

		// App names, bundle identifiers and hidden flags first: admissions copy them.
		state.ingestApps(appFacts(for: scannedPIDs), now: now)
		state.ingestServer(snapshot)
		for pid in scannedPIDs {
			if let result = scans[pid] {
				state.ingestScan(pid: pid, result: result, serverHas: serverHas, now: now)
			}
		}
		if let reads = gather.reads {
			state.ingestWindowFacts(reads.facts, now: now)
			// No element to read, or the read failed: the app's next scan brings the window's facts.
			for id in reads.unknown + reads.failed.keys.sorted() {
				if let pid = state.records[id]?.pid {
					pending.addScan(pid, due: now + CoordinatorTiming.event)
				}
			}
		}
		for id in pass.work.destroyed.keys.sorted() {
			if let pid = pass.work.destroyed[id] {
				state.ingestDestroyed(id: id, pid: pid, serverHas: serverHas.contains(id), now: now)
			}
		}
		if let focus = gather.focus {
			state.ingestFocus(focus, now: now)
		}
		if pass.liftsBarrier && state.livenessState.liftPending {
			state.liftBarrier(now: now)
		} else {
			state.pairReplacements(now: now)
		}
		state.normalize(now: now)
		return snapshot
	}

	/// Everything after the state changed: log lines, feature events, self-checks, the window
	/// notifications, the watcher's expectations and the follow-ups the core asks for. In
	/// state-only mode nothing is scanned or read, so only the frame passes (delayed hide phases,
	/// fight checks) are kept.
	private func finishStep(now: Time) {
		drainLog()
		fanOutEvents()
		checkInvariants()
		if mode != .stateOnly {
			syncWindowWatches()
			watcherContext = nil
		}
		for followUp in state.followUps(now: now) {
			if mode == .stateOnly, !Self.isFramePass(followUp) {
				continue
			}
			pending.add(followUp)
		}
		schedulePassTimer()
	}

	private static func isFramePass(_ followUp: FollowUp) -> Bool {
		if case .frames = followUp.kind {
			return true
		}
		return false
	}

	private func scanTargets(for work: PassWork) -> [PID] {
		var pids = work.scans
		if work.scanAll {
			for app in NSWorkspace.shared.runningApplications where isTrackable(app) {
				pids.insert(app.processIdentifier)
			}
		}
		pids.remove(ownPID)
		return pids.sorted()
	}

	/// Passes come at most every few milliseconds by construction; a sustained high rate means a
	/// loop somewhere, worth a line.
	private func notePassRate() {
		let now = Self.uptime()
		if now - passRateWindowStart >= 1 {
			passRateWindowStart = now
			passRateCount = 0
		}
		passRateCount += 1
		guard passRateCount == CoordinatorTiming.highPassRate, now - passRateLoggedAt >= 60 else { return }
		passRateLoggedAt = now
		event("tracking: \(passRateCount) passes within 1s")
	}

	// MARK: - Window notifications

	/// Hands every tracked window that is not watched yet to the observer thread, and watches
	/// again the windows whose element came back after a destroyed notification.
	private func syncWindowWatches() {
		for id in state.livenessDrainReobserve() {
			watchedWindows.remove(id)
		}
		for (id, record) in state.records where !watchedWindows.contains(id) {
			guard let element = ElementCache.shared.windowElement(id) else { continue }
			axEventSource.watchWindow(id, pid: record.pid, element: element)
			watchedWindows.insert(id)
		}
	}

	// MARK: - Output

	private func drainLog() {
		for entry in state.drainLog() {
			let line = entry.message
			if line.hasPrefix("topology: ") {
				// Every barrier exit reconciles the monitors; an unchanged result is not news.
				guard line != lastTopologyLine else { continue }
				lastTopologyLine = line
			}
			event(line)
		}
	}

	/// One event-log line. In shadow mode tracking lines read "shadow: retire ..." and the other
	/// categories keep theirs ("shadow: barrier: up ...").
	private func event(_ line: String) {
		guard mode == .shadow else {
			PerfLog.event(line)
			return
		}
		let body = line.hasPrefix("track: ") ? String(line.dropFirst("track: ".count)) : line
		PerfLog.event("shadow: " + body)
	}

	private func fanOutEvents() {
		for event in state.drainEvents() {
			switch event {
			case .admitted(let id):
				onAdmitted?(id)
			case .retired(let id, let reason):
				axEventSource.unwatchWindow(id)
				watchedWindows.remove(id)
				ElementCache.shared.remove(window: id)
				if mode == .shadow {
					scheduleRetireCheck(id, reason: reason)
					if let awaited = awaitingRetire.removeValue(forKey: id) {
						let delay = String(format: "%.1f", Self.uptime() - awaited.closedAt)
						self.event("missing retire \(awaited.description) (old loop closed it; retired \(delay)s later, \(reason.logText))")
					}
				}
				onRetired?(id, reason)
			case .rekeyed(let from, let to):
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

	/// Structural rules of the state, after every step in debug builds and in shadow mode. Logged
	/// when the set of broken rules changes, not on every pass.
	private func checkInvariants() {
		guard Self.checksInvariantsInEveryMode || mode == .shadow else { return }
		let problems = state.checkInvariants()
		guard problems != lastInvariantProblems else { return }
		lastInvariantProblems = problems
		for problem in problems {
			event("tracking: invariant \(problem)")
		}
	}

	// MARK: - Shadow self-checks

	/// A retired window the window server still has two seconds later was retired wrongly,
	/// unless the notification said destroyed and the window sits off screen: an app that keeps
	/// a closed window around (retired on purpose) is logged apart.
	private func scheduleRetireCheck(_ id: WindowID, reason: RetireReason) {
		DispatchQueue.main.asyncAfter(deadline: .now() + CoordinatorTiming.retireCheckDelay) { [weak self] in
			guard let self, self.isRunning, self.mode == .shadow,
				let window = ServerProbe.exists([id], now: Self.uptime()).windows[id] else { return }
			if window.isOnScreen || reason != .destroyed {
				self.event("WRONG retire #\(id) (window server still has it 2s later\(window.isOnScreen ? ", on screen" : ""))")
			} else {
				self.event("retired #\(id) stays on the window server off screen (closed, kept by its app)")
			}
		}
	}

	/// The window loop that runs alongside saw a window close. A window still tracked a moment
	/// later although the window server no longer has it is a retire the shadow missed.
	func reportLegacyWindowClosed(_ id: WindowID) {
		guard isRunning, mode == .shadow else { return }
		scheduleCrossCheck(.legacyClosed(id, at: Self.uptime()), after: CoordinatorTiming.closeCheckDelay)
	}

	/// The window loop that runs alongside found a new window. One the shadow does not track a
	/// moment later is an admission it missed.
	func reportLegacyWindowAppeared(_ id: WindowID) {
		guard isRunning, mode == .shadow else { return }
		scheduleCrossCheck(.legacyAppeared(id), after: CoordinatorTiming.appearCheckDelay)
	}

	/// Checks run once nothing holds the shadow back (barrier, exit, a pass in flight), retried
	/// a few times; one that never finds it steady is dropped.
	private func scheduleCrossCheck(_ check: CrossCheck, after delay: TimeInterval, attempt: Int = 0) {
		DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
			self?.runCrossCheck(check, attempt: attempt)
		}
	}

	private func runCrossCheck(_ check: CrossCheck, attempt: Int) {
		guard isRunning, mode == .shadow else { return }
		let isSteady = state.barrier.isEmpty && !state.livenessState.liftPending && !liftOnNextPass && inFlight == nil
		guard isSteady else {
			if attempt < CoordinatorTiming.crossCheckAttempts {
				scheduleCrossCheck(check, after: CoordinatorTiming.crossCheckRetryDelay, attempt: attempt + 1)
			} else if case .retireOverdue(let id) = check {
				awaitingRetire[id] = nil
			}
			return
		}
		let now = Self.uptime()
		switch check {
		case .legacyClosed(let id, let closedAt):
			guard !state.tombstones.contains(id), ServerProbe.exists([id], now: now).windows[id] == nil else { return }
			guard let record = state.record(id) else {
				event("missing admit #\(id) (old loop tracked it until it closed; never admitted)")
				return
			}
			// Reported once: when the retire comes after all, or when it still has not come.
			awaitingRetire[id] = AwaitedRetire(description: PerfLog.describe(record), closedAt: closedAt)
			scheduleCrossCheck(.retireOverdue(id), after: CoordinatorTiming.retireOverdueDelay)
		case .retireOverdue(let id):
			guard let awaited = awaitingRetire.removeValue(forKey: id), state.isTracked(id) else { return }
			let delay = Int((now - awaited.closedAt).rounded())
			event("missing retire \(awaited.description) (old loop closed it and the window server no longer has it; still tracked \(delay)s later)")
		case .legacyAppeared(let id):
			guard !state.isTracked(id), let window = ServerProbe.exists([id], now: now).windows[id] else { return }
			if state.tombstones.contains(id) {
				if window.isOnScreen {
					event("WRONG retire #\(id) (old loop found it on screen again)")
				}
				return
			}
			// An app that does not answer is retried; its unreadable line already says so.
			guard state.apps[window.pid]?.unresponsiveSince == nil else { return }
			let name = NSRunningApplication(processIdentifier: window.pid)?.localizedName ?? "pid \(window.pid)"
			event("missing admit #\(id) of \(name) (old loop found it; not tracked 2s later)")
		}
	}

	// MARK: - Window-server watcher

	private func currentWatcherContext() -> WindowServerWatcher.Context {
		if let watcherContext {
			return watcherContext
		}
		let context = buildWatcherContext()
		watcherContext = context
		return context
	}

	/// The watcher sits out the barriers that make the window list meaningless, and the settling
	/// after them, except while Mission Control is the reason still up: only the watcher can
	/// tell that it closed.
	private var watcherIsPaused: Bool {
		let active = state.barrier.subtracting(endingReasons)
		if !active.isDisjoint(with: Self.watcherPausingBarriers) {
			return true
		}
		return !active.contains(.missionControl) && !state.barrier.isDisjoint(with: Self.watcherPausingBarriers)
	}

	private func buildWatcherContext() -> WindowServerWatcher.Context {
		var context = WindowServerWatcher.Context(isPaused: watcherIsPaused)
		guard !context.isPaused else { return context }
		var regular = Set<PID>()
		for app in NSWorkspace.shared.runningApplications where isTrackable(app) {
			regular.insert(app.processIdentifier)
		}
		context.regularPIDs = regular
		var unreadable = Set<PID>()
		for app in state.apps.values where app.unresponsiveSince != nil || app.lastScan == .incomplete {
			unreadable.insert(app.pid)
		}
		context.unreadablePIDs = unreadable
		context.tracked = Set(state.records.keys)
		// Hidden windows found visible matter to enforcement only. The shadow enforces nothing,
		// and its parked windows (a removed monitor's workspaces, say) are on screen for real.
		let checksHidden = mode != .shadow
		for (id, record) in state.records where Self.expectsOnScreen(record, apps: state.apps) {
			context.onScreen[id] = WindowServerWatcher.Context.Expectation(pid: record.pid,
				isHidden: checksHidden && record.visibility != .visible)
		}
		context.monitors = state.monitorOrder.compactMap { state.monitors[$0] }
		context.expectedFrame = { [weak self] id in
			self?.state.expectedFrame(id)
		}
		return context
	}

	/// Listed by its app, not minimized, fullscreen or hidden with its app, and visible or out of
	/// sight at a corner (which keeps a sliver on screen). Ghosts stay out: the window server does
	/// not list them, so they would be reported on every tick.
	private static func expectsOnScreen(_ record: WindowRecord, apps: [PID: AppState]) -> Bool {
		let observed = record.observed
		guard observed.listedInLastCompleteScan, !observed.isMinimized, !observed.isFullscreen,
			!observed.isServerGhost, apps[record.pid]?.isHidden != true
		else { return false }
		switch record.visibility {
		case .visible, .parked, .zenHidden, .paletteHidden:
			return true
		case .axisMinimized, .nativeMinimized, .nativeFullscreen, .otherSpace, .appHidden:
			return false
		}
	}

	// MARK: - Commands

	/// Runs a command on the state: `mutate` changes it, then the windows are observed and
	/// normalized as at the end of a pass and the outputs go out. Shadow mode plans and writes
	/// nothing; state-only mode executes the plan. `delaysHidePhase`: windows leaving the screen
	/// go a moment later, so a workspace switch shows the new windows before the old ones leave.
	func perform(_ name: String, delaysHidePhase: Bool = false, _ mutate: (inout TrackingState) -> Void) {
		guard isRunning else { return }
		PerfLog.measure("tracking.\(name)") {
			let now = Self.uptime()
			let snapshot = ServerProbe.onScreen(now: now)
			mutate(&state)
			if mode == .stateOnly {
				// Each command is an ingest of its own: a window it admitted pairs only with a
				// window retired shortly before, not with one a later command retires.
				state.pairReplacements(now: now)
			}
			state.ingestServer(snapshot)
			state.normalize(now: now)
			if mode == .stateOnly {
				planAndExecute(snapshot, isCommand: true, includeHidePhase: !delaysHidePhase, now: now)
			}
			finishStep(now: now)
		}
	}

	/// Changes bookkeeping that moves no window (which window has focus, ...): no plan follows.
	func note(_ mutate: (inout TrackingState) -> Void) {
		guard isRunning else { return }
		mutate(&state)
		finishStep(now: Self.uptime())
	}

	/// Facts of tracked windows read by the caller (minimized, fullscreen, title, frame). A window
	/// that changed state (minimized, fullscreen, restored from the Dock) or left or rejoined the
	/// layout changes where the others go, so only then a plan follows.
	func ingestWindowFacts(_ facts: [WindowFacts]) {
		guard isRunning else { return }
		let now = Self.uptime()
		let snapshot = ServerProbe.onScreen(now: now)
		let before = placementSignature()
		state.ingestWindowFacts(facts, now: now)
		state.ingestServer(snapshot)
		state.normalize(now: now)
		if mode == .stateOnly && placementSignature() != before {
			planAndExecute(snapshot, isCommand: false, includeHidePhase: true, now: now)
		}
		finishStep(now: now)
	}

	/// Puts every window Axis moved out of sight back where the state says it belongs (its slot,
	/// its last visible frame), before Axis quits.
	func prepareForQuit() {
		guard isRunning, mode == .stateOnly else { return }
		let plan = state.quitPlan()
		guard !plan.isEmpty else { return }
		WindowActuator.execute(plan)
	}

	/// A handle for a tracked window, built from the cached element and the record without asking
	/// the app anything; nil when the window or its app is gone.
	func windowInfo(_ id: WindowID) -> WindowInfo? {
		guard let record = state.records[id], let element = ElementCache.shared.windowElement(id),
			let app = runningApp(record.pid)
		else { return nil }
		let observed = record.observed
		let facts = WindowFacts(id: id, pid: record.pid, role: record.role, subrole: record.subrole, title: record.title,
			frame: observed.frame ?? .zero, isMinimized: observed.isMinimized, isFullscreen: observed.isFullscreen,
			hasCloseButton: record.hasCloseButton, minSize: observed.minSize, takenAt: observed.frameAt ?? 0)
		return WindowInfo(facts: facts, element: element, app: app)
	}

	/// The running app of a tracked window's process (its name and icon), nil once it quit.
	func runningApp(_ pid: PID) -> NSRunningApplication? {
		if let known = runningApps[pid], !known.isTerminated {
			return known
		}
		guard let found = NSRunningApplication(processIdentifier: pid), !found.isTerminated else {
			runningApps[pid] = nil
			return nil
		}
		runningApps[pid] = found
		return found
	}

	/// Plans against `snapshot` and executes the plan. In state-only mode a window the window
	/// server does not show gets no frame (unless it is unminimized in the same plan): without
	/// scans the state cannot tell a window on another Space or of a hidden app from one in view,
	/// and a slot written to it would pull it into the layout.
	private func planAndExecute(_ snapshot: ServerSnapshot, isCommand: Bool, includeHidePhase: Bool, now: Time) {
		let options = PlanOptions(isCommand: isCommand, includeHidePhase: includeHidePhase,
			mouseDown: SystemSignals.isLeftMouseDown, externallyPositioned: externallyPositioned())
		var plan = state.plan(snapshot: snapshot, options: options, now: now)
		if mode == .stateOnly {
			plan = Self.withoutUnseenFrames(plan, snapshot: snapshot)
		}
		// The planner's enforcement lines come before the actuator's frame lines.
		drainLog()
		guard !plan.isEmpty else { return }
		let results = WindowActuator.execute(plan)
		state.recordWrites(results, now: Self.uptime())
		// The window list read through Accessibility is cached briefly; frames just written make
		// it stale.
		AccessibilityManager.shared.invalidateWindowCache()
	}

	private static func withoutUnseenFrames(_ plan: Plan, snapshot: ServerSnapshot) -> Plan {
		var unminimized = Set<WindowID>()
		for action in plan.actions {
			if case .unminimize = action.kind {
				unminimized.insert(action.window)
			}
		}
		func keeps(_ action: PlanAction) -> Bool {
			guard case .setFrame = action.kind else { return true }
			return snapshot.windows[action.window] != nil || unminimized.contains(action.window)
		}
		func filtered(_ groups: [PlanGroup]) -> [PlanGroup] {
			groups.compactMap { group in
				let actions = group.actions.filter(keeps)
				return actions.isEmpty ? nil : PlanGroup(pid: group.pid, actions: actions)
			}
		}
		var result = plan
		result.show = filtered(plan.show)
		result.hide = filtered(plan.hide)
		return result
	}

	/// What decides where windows go: each window's state and whether the layout counts it.
	private func placementSignature() -> [WindowID: PlacementKey] {
		state.records.mapValues { PlacementKey(visibility: $0.visibility, isGhost: $0.observed.isServerGhost) }
	}

	// MARK: - Helpers

	/// Regular apps other than Axis and the login window: the apps whose windows are tracked.
	private func isTrackable(_ app: NSRunningApplication) -> Bool {
		app.activationPolicy == .regular && app.processIdentifier != ownPID
			&& app.bundleIdentifier != SystemSignals.loginWindowBundleID && !app.isTerminated
	}

	private func trackableApp(_ pid: PID) -> NSRunningApplication? {
		guard let app = NSRunningApplication(processIdentifier: pid), isTrackable(app) else { return nil }
		return app
	}

	private func appFacts(for pids: [PID]) -> [AppFacts] {
		pids.compactMap { pid in
			guard pid != ownPID, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return nil }
			return Self.appFacts(app)
		}
	}

	private static func appFacts(_ app: NSRunningApplication) -> AppFacts {
		AppFacts(pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: app.localizedName ?? "", isHidden: app.isHidden)
	}

	/// Whether the process exists; one owned by another user still counts.
	private static func isProcessAlive(_ pid: PID) -> Bool {
		kill(pid, 0) == 0 || errno != ESRCH
	}

	private static func uptime() -> Time {
		ProcessInfo.processInfo.systemUptime
	}
}

// MARK: - Pass bookkeeping

private nonisolated enum CoordinatorTiming {
	/// After window, focus, activation and hide notifications, so a burst shares one pass.
	static let event: TimeInterval = 0.016
	/// After moves, resizes, mouse-ups and watcher findings, which come in streams.
	static let frames: TimeInterval = 0.03
	/// A launching app gets a moment before its first scan; the core rescans it until it lists a window.
	static let launch: TimeInterval = 0.1
	/// A Space switch settles before every app is scanned.
	static let spaceChange: TimeInterval = 0.3
	/// Work due this soon after a pass starts joins it.
	static let coalescing: TimeInterval = 0.02
	/// Shortest gap between the end of one pass and the start of the next.
	static let passSpacing: TimeInterval = 0.01
	/// Passes started within one second that make the rate worth a line.
	static let highPassRate = 60
	/// A gather not answered by then goes on with what it has. Scans and reads answer by the
	/// enumerator's deadline; the focused-window read has none of its own.
	static let gatherDeadline: TimeInterval = WindowEnumerator.awaiterDeadline + 0.2
	/// Ingests slower than this on the main thread are logged.
	static let slowPass: TimeInterval = 0.005
	static let sampleInterval: TimeInterval = 0.1
	/// The display configuration has settled once it stayed the same this long, or once it was
	/// sampled for `settleCap` with something to show.
	static let settledAfter: TimeInterval = 0.5
	static let settleCap: TimeInterval = 5
	static let lockCheckInterval: TimeInterval = 2
	/// Awake time after a sleep announcement without a wake notification that ends the barrier.
	static let asleepLimit: TimeInterval = 60
	static let retireCheckDelay: TimeInterval = 2
	static let closeCheckDelay: TimeInterval = 1
	/// After the close check found the window still tracked.
	static let retireOverdueDelay: TimeInterval = 4
	static let appearCheckDelay: TimeInterval = 2
	static let crossCheckRetryDelay: TimeInterval = 1
	static let crossCheckAttempts = 10
}

/// Refresh work waiting for a pass. Each item keeps the time it is due and a pass takes only
/// what is due, so a retry the core scheduled seconds ahead is not pulled forward by unrelated
/// activity (which would make pass after pass wait for an app that does not answer).
private nonisolated struct PendingWork {
	nonisolated struct Destroyed {
		var pid: PID
		var due: Time
	}

	var scanAll: Time?
	var scans: [PID: Time] = [:]
	var reads: [WindowID: Time] = [:]
	var destroyed: [WindowID: Destroyed] = [:]
	var focus: Time?
	var frames: Time?

	var earliest: Time? {
		var result = Swift.min(scanAll ?? .infinity, focus ?? .infinity, frames ?? .infinity)
		for due in scans.values where due < result {
			result = due
		}
		for due in reads.values where due < result {
			result = due
		}
		for item in destroyed.values where item.due < result {
			result = item.due
		}
		return result.isFinite ? result : nil
	}

	mutating func addScanAll(due: Time) {
		scanAll = Swift.min(scanAll ?? due, due)
	}

	mutating func addScan(_ pid: PID, due: Time) {
		scans[pid] = Swift.min(scans[pid] ?? due, due)
	}

	mutating func addRead(_ id: WindowID, due: Time) {
		reads[id] = Swift.min(reads[id] ?? due, due)
	}

	mutating func addDestroyed(_ id: WindowID, pid: PID, due: Time) {
		if let existing = destroyed[id] {
			destroyed[id]?.due = Swift.min(existing.due, due)
		} else {
			destroyed[id] = Destroyed(pid: pid, due: due)
		}
	}

	mutating func addFocus(due: Time) {
		focus = Swift.min(focus ?? due, due)
	}

	mutating func addFrames(due: Time) {
		frames = Swift.min(frames ?? due, due)
	}

	mutating func add(_ followUp: FollowUp) {
		switch followUp.kind {
		case .scan(let pid):
			addScan(pid, due: followUp.at)
		case .readWindow(let id):
			addRead(id, due: followUp.at)
		case .frames:
			addFrames(due: followUp.at)
		}
	}

	/// Takes the items due by `limit`. Every pass reads the window server, so pending frame work
	/// is done by any pass, and a scan of every app does each single scan.
	mutating func take(dueBy limit: Time) -> PassWork {
		var work = PassWork()
		if let due = scanAll, due <= limit {
			work.scanAll = true
			scanAll = nil
			scans.removeAll()
		}
		for (pid, due) in scans where due <= limit {
			work.scans.insert(pid)
		}
		for pid in work.scans {
			scans[pid] = nil
		}
		for (id, due) in reads where due <= limit {
			work.reads.insert(id)
		}
		for id in work.reads {
			reads[id] = nil
		}
		for (id, item) in destroyed where item.due <= limit {
			work.destroyed[id] = item.pid
		}
		for id in work.destroyed.keys {
			destroyed[id] = nil
		}
		if let due = focus, due <= limit {
			work.focus = true
			focus = nil
		}
		frames = nil
		return work
	}

	/// Puts back the work of a pass whose facts were dropped.
	mutating func requeue(_ work: PassWork, due: Time) {
		if work.scanAll {
			addScanAll(due: due)
		}
		for pid in work.scans {
			addScan(pid, due: due)
		}
		for id in work.reads {
			addRead(id, due: due)
		}
		for (id, pid) in work.destroyed {
			addDestroyed(id, pid: pid, due: due)
		}
		if work.focus {
			addFocus(due: due)
		}
		addFrames(due: due)
	}
}

/// What one pass gathers and ingests. Every pass also observes the window server.
private nonisolated struct PassWork: Sendable {
	var scanAll = false
	var scans: Set<PID> = []
	var reads: Set<WindowID> = []
	var destroyed: [WindowID: PID] = [:]
	var focus = false
}

private nonisolated struct CoordinatorPass: Sendable {
	let number: Int
	let epoch: Int
	let liftsBarrier: Bool
	let work: PassWork
	/// The apps scanned, resolved when the pass started.
	let pids: [PID]
}

/// The answers of one pass's gather, collected on the main thread.
@MainActor
private final class PassGather {
	var scans: [PID: ScanResult]?
	var reads: WindowReadResult?
	var focus: FocusFacts?
	var outstanding = 0
	var isFinished = false
}

private nonisolated enum CrossCheck: Sendable {
	/// `at`: when the loop running alongside reported the close.
	case legacyClosed(WindowID, at: Time)
	case retireOverdue(WindowID)
	case legacyAppeared(WindowID)
}

private nonisolated struct AwaitedRetire {
	var description: String
	var closedAt: Time
}

/// A window's state and whether the layout counts it, compared before and after window facts.
private nonisolated struct PlacementKey: Equatable {
	var visibility: Visibility
	var isGhost: Bool
}
