//
//  Liveness.swift
//  Axis
//
//  Whether tracked windows still exist. A record leaves only through `retire`, and only on
//  verified evidence: a destroyed notification the window server confirms, the app terminating,
//  or two complete scans plus the window server all missing it. Unreadable apps never lose
//  windows, and nothing is retired while a barrier is up.
//
//  A pass ingests, in this order: the window-server snapshot (and the existence probe), the app
//  scans, single-window facts, destroyed and terminated signals, focus and app facts; then
//  `pairReplacements(now:)` ends the ingest. This file also keeps the per-app scan state
//  (unreadable apps, created signals, launch retries), focus as last read, and the barrier's
//  up and down bookkeeping.
//

import Foundation
import CoreGraphics

/// Liveness bookkeeping that is not per record. Fields added here need default values.
nonisolated struct LivenessState: Equatable, Sendable {
	/// Every reason raised since the barrier last went up, for the line logged when it lifts.
	var barrierReasons: Set<BarrierReason> = []
	/// The barrier set emptied and the desktop is being read again; `liftBarrier(now:)` finishes
	/// the exit. Scans are ingested meanwhile.
	var liftPending = false
	/// Apps whose scans were ingested since the barrier set emptied.
	var rescannedApps: Set<PID> = []
	/// When each app last signalled a window creation.
	var createdSignalAt: [PID: Time] = [:]
	/// Apps that launched recently, rescanned until they list a window.
	var launchRetries: [PID: LivenessLaunchRetry] = [:]
	/// The last tracked window that had focus. Unlike `focus.current` it outlives the window's
	/// retirement, so the next focus change can name the closed window as the previous one.
	var lastFocused: WindowID?
	/// Monitors whose empty workspaces are dropped when the ingest ends, after replacement pairing
	/// had the chance to put a new window in a retired window's place.
	var compactPending: Set<MonitorKey> = []
	/// Windows whose element came back after a destroyed notification: their window notifications
	/// have to be registered again.
	var reobserve: Set<WindowID> = []

	init() {}
}

/// Rescans of an app that launched and has not listed a window yet.
nonisolated struct LivenessLaunchRetry: Equatable, Sendable {
	var launchedAt: Time
	/// Scans ingested since the launch.
	var attempts: Int
	var nextAt: Time
}

nonisolated enum LivenessTiming {
	/// Misses closer together than this count once: one stall can make back-to-back scans miss
	/// the same window.
	static let missSpacing: TimeInterval = 0.1
	/// Complete scans that must miss a window, while the window server lacks it too, to retire it.
	static let missesToRetire = 2
	/// Delay of the scan that confirms a first miss or a destroyed notification.
	static let confirmDelay: TimeInterval = 0.15
	/// A window its app still lists but the window server does not show leaves the layout once it
	/// has been missing this long, over at least `ghostSnapshots` snapshots.
	static let ghostDelay: TimeInterval = 0.3
	static let ghostSnapshots = 2
	/// Confirm scans after a window went missing from the window server, from its first absence.
	static let ghostConfirmOffsets: [TimeInterval] = [0.15, 0.35, 1]
	/// Retry delays for an app that did not answer; the last one repeats.
	static let unreadableBackoff: [TimeInterval] = [0.5, 1, 2, 4, 5]
	/// Delays between rescans of a launching app that lists no window yet (the last one repeats),
	/// and how long after the launch to keep trying.
	static let launchBackoff: [TimeInterval] = [0.3, 1, 2, 4]
	static let launchWindow: TimeInterval = 10
	/// New windows count as created until a complete scan at least this long after the app's
	/// created signal, in case the first scan ran before the window was listed.
	static let createdGrace: TimeInterval = 0.5

	/// `to - from >= interval`, tolerant of rounding in sums of fractional seconds.
	static func elapsed(from: Time, to: Time, atLeast interval: TimeInterval) -> Bool {
		to - from >= interval - 1e-9
	}
}

// MARK: - Window server

nonisolated extension TrackingState {
	/// Ids to ask the window server about this pass: records of a pid that a complete scan did not
	/// list, plus tracked windows named by destroyed notifications (held ones included).
	func probeCandidates(scans: [PID: ScanResult], destroyed: Set<WindowID>) -> Set<WindowID> {
		var candidates = destroyed.filter { records[$0] != nil }
		for signal in pendingDuringBarrier {
			if case .destroyed(let id, _) = signal, records[id] != nil {
				candidates.insert(id)
			}
		}
		for (pid, result) in scans {
			guard case .complete(let windows) = result else { continue }
			let listed = Set(windows.map(\.id))
			for record in records.values where record.pid == pid && !listed.contains(record.id) {
				candidates.insert(record.id)
			}
		}
		return candidates
	}

	/// Window-server presence, on-screen state and bounds of tracked windows. An on-screen snapshot
	/// covers every record (absent = not on screen); an existence probe covers its ids (absent =
	/// gone). A window that should be on screen but is not becomes a ghost once it has been missing
	/// for `ghostDelay` over `ghostSnapshots` snapshots: the layout leaves it out while its column
	/// entry stays, and showing up again clears it. No ghost evidence is collected during a barrier.
	mutating func ingestServer(_ snapshot: ServerSnapshot) {
		let covered: [WindowID]
		let isProbe: Bool
		switch snapshot.scope {
		case .onScreen:
			covered = records.keys.sorted()
			isProbe = false
		case .ids(let ids):
			covered = ids.filter { records[$0] != nil }.sorted()
			isProbe = true
		}
		for id in covered {
			guard var record = records[id] else { continue }
			let window = snapshot.windows[id]
			if let window, snapshot.takenAt >= (record.observed.frameAt ?? -.infinity) {
				record.observed.frame = window.bounds
				record.observed.frameAt = snapshot.takenAt
			}
			let shown = window.map { !isProbe || $0.isOnScreen } ?? false
			if isProbe {
				record.observed.serverHas = window != nil
			} else if window != nil {
				record.observed.serverHas = true
			}
			record.observed.onScreen = shown
			if shown {
				livenessClearGhost(&record, logging: true)
			} else if !livenessExpectsOnScreen(record) {
				livenessClearGhost(&record, logging: false)
			} else if barrier.isEmpty {
				livenessNoteServerAbsence(&record, at: snapshot.takenAt)
			}
			records[id] = record
		}
	}

	/// Whether the window belongs in the window server's on-screen list: listed by its app, not
	/// minimized, fullscreen or hidden with its app, and visible or parked (a parked window keeps a
	/// sliver on screen).
	private func livenessExpectsOnScreen(_ record: WindowRecord) -> Bool {
		let observed = record.observed
		guard observed.listedInLastCompleteScan, !observed.isMinimized, !observed.isFullscreen,
			apps[record.pid]?.isHidden != true
		else { return false }
		switch record.visibility {
		case .visible, .parked, .zenHidden, .paletteHidden: return true
		case .axisMinimized, .nativeMinimized, .nativeFullscreen, .otherSpace, .appHidden: return false
		}
	}

	private mutating func livenessNoteServerAbsence(_ record: inout WindowRecord, at time: Time) {
		if let since = record.observed.serverAbsentSince {
			if time > since {
				record.observed.serverAbsentCount += 1
			}
		} else {
			record.observed.serverAbsentSince = time
			record.observed.serverAbsentCount = 1
		}
		guard !record.observed.isServerGhost, let since = record.observed.serverAbsentSince,
			record.observed.serverAbsentCount >= LivenessTiming.ghostSnapshots,
			LivenessTiming.elapsed(from: since, to: time, atLeast: LivenessTiming.ghostDelay)
		else { return }
		record.observed.isServerGhost = true
		log("track: ghost \(describe(record)) (missing from the window server for \(String(format: "%.1f", time - since))s while its app lists it); out of layout")
	}

	private mutating func livenessClearGhost(_ record: inout WindowRecord, logging: Bool) {
		let wasGhost = record.observed.isServerGhost
		record.observed.serverAbsentSince = nil
		record.observed.serverAbsentCount = 0
		record.observed.isServerGhost = false
		if wasGhost && logging {
			log("track: \(describe(record)) is back on the window server")
		}
	}
}

// MARK: - Scans and window facts

nonisolated extension TrackingState {
	/// One app's scan; `serverHas` = the probed ids the window server still has. Ignored while a
	/// barrier is up. A failed or timed-out scan changes no window: the app is marked unreadable and
	/// retried. An incomplete scan updates and admits the windows it lists but proves nothing about
	/// the others. A complete scan also judges the app's windows it does not list: kept while the
	/// window server has them, else missed (retired at the second miss, the misses at least
	/// `missSpacing` apart), and retired at once after a destroyed notification.
	mutating func ingestScan(pid: PID, result: ScanResult, serverHas: Set<WindowID>, now: Time) {
		guard barrier.isEmpty, pid != ownPID else { return }
		admissionExpireLaunchAside(now: now)
		if livenessState.liftPending {
			livenessState.rescannedApps.insert(pid)
		}
		var app = apps[pid] ?? AppState(pid: pid)
		app.lastScanAt = now
		switch result {
		case .failed(let code):
			app.lastScan = .failed(code)
			livenessMarkUnreadable(&app, detail: "error \(code)", now: now)
		case .timedOut:
			app.lastScan = .timedOut
			livenessMarkUnreadable(&app, detail: "timed out", now: now)
		case .incomplete:
			app.lastScan = .incomplete
		case .complete:
			app.lastScan = .complete
			if app.unresponsiveSince != nil {
				log("track: app \(Self.livenessAppName(app)) readable again")
			}
			app.unresponsiveSince = nil
			app.retryCount = 0
			app.nextRetryAt = nil
		}
		apps[pid] = app
		switch result {
		case .failed, .timedOut:
			livenessAdvanceLaunchRetry(pid, listsWindow: false, now: now)
			return
		case .complete, .incomplete:
			break
		}

		// Facts naming a retired window are stale: the Accessibility API can list a window for a
		// moment after it closed.
		var listed: [WindowFacts] = []
		var listedIDs = Set<WindowID>()
		for facts in result.windows where facts.pid == pid && !tombstones.contains(facts.id) {
			if listedIDs.insert(facts.id).inserted {
				listed.append(facts)
			}
		}

		for facts in listed {
			guard var record = records[facts.id], record.pid == pid else { continue }
			let dismissed = record.liveness.pendingDestroySince != nil
			record.observed.listedInLastCompleteScan = true
			record.liveness.misses = 0
			record.liveness.lastMissAt = nil
			record.liveness.pendingDestroySince = nil
			livenessApply(facts, to: &record)
			records[facts.id] = record
			if dismissed {
				livenessState.reobserve.insert(facts.id)
				log("track: keep \(describe(record)) (listed again after a destroyed notification)")
			}
		}

		// Unlisted windows are judged before new ones are admitted, so a new window can take the
		// place of one retired here; a scan with new windows leaves the compaction to the end of
		// the ingest for the same reason.
		if result.isComplete {
			let hasNewWindows = listed.contains { records[$0.id] == nil }
			let unlisted = records.values.filter { $0.pid == pid && !listedIDs.contains($0.id) }.map(\.id).sorted()
			for id in unlisted {
				livenessJudgeUnlisted(id, serverHas: serverHas.contains(id), deferCompaction: hasNewWindows, now: now)
			}
		}

		let source = livenessAdmissionSource(for: pid)
		let appFacts = AppFacts(pid: pid, bundleID: app.bundleID, name: app.name, isHidden: app.isHidden)
		var admittedCreated = false
		for facts in listed where records[facts.id] == nil {
			if admit(facts, app: appFacts, source: source, now: now) != nil && source == .created {
				admittedCreated = true
			}
		}

		livenessAdvanceLaunchRetry(pid, listsWindow: listed.contains { records[$0.id] != nil }, now: now)
		guard var updated = apps[pid] else { return }
		if updated.createdSignalPending && livenessState.launchRetries[pid] == nil {
			let graceOver = livenessState.createdSignalAt[pid].map {
				LivenessTiming.elapsed(from: $0, to: now, atLeast: LivenessTiming.createdGrace)
			} ?? true
			if admittedCreated || (result.isComplete && graceOver) {
				updated.createdSignalPending = false
				livenessState.createdSignalAt[pid] = nil
			}
		}
		if !result.isComplete {
			// Rescan an app that answers only in part while it was unreadable before or a window it
			// just created may be the part that did not answer.
			if updated.unresponsiveSince != nil || updated.createdSignalPending {
				Self.livenessScheduleRetry(&updated, now: now)
			} else {
				updated.retryCount = 0
				updated.nextRetryAt = nil
			}
		}
		apps[pid] = updated
	}

	/// Fresh facts of single windows (minimized, deminiaturized, title changes). Facts of untracked
	/// or retired windows are ignored, and nothing is ingested while a barrier is up.
	mutating func ingestWindowFacts(_ facts: [WindowFacts], now: Time) {
		guard barrier.isEmpty else { return }
		for fact in facts {
			guard !tombstones.contains(fact.id), var record = records[fact.id], record.pid == fact.pid else { continue }
			livenessApply(fact, to: &record)
			records[fact.id] = record
		}
	}

	/// Copies what a fresh read says about a tracked window. The frame is taken only when the read
	/// is newer than the frame already known and than Axis's last write to the window.
	private func livenessApply(_ facts: WindowFacts, to record: inout WindowRecord) {
		record.title = facts.title
		record.observed.isMinimized = facts.isMinimized
		record.observed.isFullscreen = facts.isFullscreen
		record.observed.minSize = facts.minSize
		let newest = max(record.observed.frameAt ?? -.infinity, ledger[record.id]?.at ?? -.infinity)
		if facts.frame != .zero && facts.takenAt >= newest {
			record.observed.frame = facts.frame
			record.observed.frameAt = facts.takenAt
		}
	}

	private mutating func livenessJudgeUnlisted(_ id: WindowID, serverHas: Bool, deferCompaction: Bool, now: Time) {
		guard var record = records[id] else { return }
		if record.liveness.pendingDestroySince != nil {
			livenessRetire(id, reason: .destroyed, deferCompaction: deferCompaction, now: now)
			return
		}
		let wasListed = record.observed.listedInLastCompleteScan
		record.observed.listedInLastCompleteScan = false
		if serverHas {
			// On another Space, or an app that stopped listing a window it still has: alive.
			let hadMisses = record.liveness.misses > 0
			record.observed.serverHas = true
			record.liveness.misses = 0
			record.liveness.lastMissAt = nil
			records[id] = record
			if wasListed || hadMisses {
				log("track: keep \(describe(record)) (missing from complete scan, window server has it)")
			}
			return
		}
		record.observed.serverHas = false
		record.observed.onScreen = false
		let spaced = record.liveness.lastMissAt.map {
			LivenessTiming.elapsed(from: $0, to: now, atLeast: LivenessTiming.missSpacing)
		} ?? true
		if spaced {
			record.liveness.misses += 1
			record.liveness.lastMissAt = now
		}
		records[id] = record
		if record.liveness.misses >= LivenessTiming.missesToRetire {
			livenessRetire(id, reason: .absent, deferCompaction: deferCompaction, now: now)
		} else if spaced {
			log("track: miss \(describe(record)) (missing from complete scan and window server); confirming")
		}
	}

	/// Where the windows a scan finds for the first time come from: the startup scan, a creation
	/// the app signalled, or anything else.
	private func livenessAdmissionSource(for pid: PID) -> AdmissionSource {
		if livenessState.liftPending && livenessState.barrierReasons.contains(.starting) {
			return .startup
		}
		return apps[pid]?.createdSignalPending == true ? .created : .discovered
	}

	private mutating func livenessMarkUnreadable(_ app: inout AppState, detail: String, now: Time) {
		if app.unresponsiveSince == nil {
			app.unresponsiveSince = now
			log("track: app \(Self.livenessAppName(app)) unreadable (\(detail)); windows kept")
		}
		Self.livenessScheduleRetry(&app, now: now)
	}

	private static func livenessScheduleRetry(_ app: inout AppState, now: Time) {
		let delays = LivenessTiming.unreadableBackoff
		app.nextRetryAt = now + delays[min(app.retryCount, delays.count - 1)]
		app.retryCount += 1
	}

	private mutating func livenessAdvanceLaunchRetry(_ pid: PID, listsWindow: Bool, now: Time) {
		guard var retry = livenessState.launchRetries[pid] else { return }
		retry.attempts += 1
		let delays = LivenessTiming.launchBackoff
		retry.nextAt = now + delays[min(retry.attempts - 1, delays.count - 1)]
		if listsWindow || retry.nextAt > retry.launchedAt + LivenessTiming.launchWindow {
			livenessState.launchRetries[pid] = nil
		} else {
			livenessState.launchRetries[pid] = retry
		}
	}

	private static func livenessAppName(_ app: AppState) -> String {
		if !app.name.isEmpty { return app.name }
		return app.bundleID ?? "pid \(app.pid)"
	}
}

// MARK: - Destroyed and terminated

nonisolated extension TrackingState {
	/// A destroyed notification; `serverHas` = the window server still lists the id. The window is
	/// retired when the window server lacks it, else the confirm scan decides (a complete scan
	/// without it retires it, one listing it keeps it). Unknown and retired ids are stale and
	/// ignored; while a barrier is up the signal is held.
	mutating func ingestDestroyed(id: WindowID, pid: PID?, serverHas: Bool, now: Time) {
		guard let record = records[id] else { return }
		guard barrier.isEmpty else {
			let held = pendingDuringBarrier.contains { signal in
				if case .destroyed(let other, _) = signal { return other == id }
				return false
			}
			if !held {
				pendingDuringBarrier.append(.destroyed(id, pid: pid ?? record.pid))
			}
			return
		}
		if !serverHas {
			livenessRetire(id, reason: .destroyed, now: now)
		} else if record.liveness.pendingDestroySince == nil {
			records[id]?.liveness.pendingDestroySince = now
			log("track: pending destroy \(describe(record)) (window server still has it)")
		}
	}

	/// The app quit: all its windows are retired (held while a barrier is up).
	mutating func ingestTerminated(pid: PID, now: Time) {
		guard barrier.isEmpty else {
			if !pendingDuringBarrier.contains(.terminated(pid)) {
				pendingDuringBarrier.append(.terminated(pid))
			}
			return
		}
		livenessApplyTerminated(pid, now: now)
	}

	/// Called by `retire` after the record left the state.
	mutating func livenessNoteRetire(_ retired: RetiredWindow) {
		livenessState.reobserve.remove(retired.record.id)
	}

	/// Windows whose notifications must be registered again because their element came back after
	/// a destroyed notification, lowest id first. The coordinator drains them after every pass.
	mutating func livenessDrainReobserve() -> [WindowID] {
		defer { livenessState.reobserve = [] }
		return livenessState.reobserve.sorted()
	}

	/// Retires a window on liveness evidence. When a window admitted in this ingest may take its
	/// place (or the barrier is coming down) its workspace is compacted only when the ingest ends.
	private mutating func livenessRetire(_ id: WindowID, reason: RetireReason, deferCompaction: Bool = false, now: Time) {
		guard let record = records[id] else { return }
		let deferred = deferCompaction || livenessState.liftPending || admissionMayBeReplaced(record)
		let retired = retire(id, reason: reason, now: now, compacting: !deferred)
		if deferred, let monitor = retired?.monitor {
			livenessState.compactPending.insert(monitor)
		}
	}

	private mutating func livenessApplyTerminated(_ pid: PID, now: Time) {
		for id in records.values.filter({ $0.pid == pid }).map(\.id).sorted() {
			livenessRetire(id, reason: .appTerminated, now: now)
		}
		apps[pid] = nil
		livenessState.launchRetries[pid] = nil
		livenessState.createdSignalAt[pid] = nil
	}

	/// A destroyed notification held during the barrier: the rescan decides when it covered the
	/// app completely, else the window server does.
	private mutating func livenessApplyHeldDestroy(_ id: WindowID, now: Time) {
		guard let record = records[id] else { return }
		let rescanned = livenessState.rescannedApps.contains(record.pid) && apps[record.pid]?.lastScan == .complete
		if rescanned {
			if record.observed.listedInLastCompleteScan {
				livenessState.reobserve.insert(id)
				log("track: keep \(describe(record)) (destroyed during the barrier but listed again)")
			} else {
				livenessRetire(id, reason: .destroyed, now: now)
			}
		} else if !record.observed.serverHas {
			livenessRetire(id, reason: .destroyed, now: now)
		} else if record.liveness.pendingDestroySince == nil {
			records[id]?.liveness.pendingDestroySince = now
			log("track: pending destroy \(describe(record)) (window server still has it)")
		}
	}
}

// MARK: - Apps, focus

nonisolated extension TrackingState {
	/// App facts (hidden flag, names) for the apps they name; other apps are left as they are.
	mutating func ingestApps(_ facts: [AppFacts], now: Time) {
		for app in facts where app.pid != ownPID {
			var state = apps[app.pid] ?? AppState(pid: app.pid)
			if let bundleID = app.bundleID {
				state.bundleID = bundleID
			}
			if !app.name.isEmpty {
				state.name = app.name
			}
			state.isHidden = app.isHidden
			apps[app.pid] = state
			for id in records.keys.sorted() where records[id]?.pid == app.pid {
				if let bundleID = app.bundleID, records[id]?.bundleID != bundleID {
					records[id]?.bundleID = bundleID
				}
				if !app.name.isEmpty, records[id]?.appName != app.name {
					records[id]?.appName = app.name
				}
			}
		}
	}

	/// An app launched: its windows count as created, and it is rescanned until it lists a window
	/// (its observer may not be in place when its first window appears).
	mutating func livenessNoteLaunched(_ app: AppFacts, now: Time) {
		guard app.pid != ownPID else { return }
		var state = apps[app.pid] ?? AppState(pid: app.pid)
		if let bundleID = app.bundleID {
			state.bundleID = bundleID
		}
		if !app.name.isEmpty {
			state.name = app.name
		}
		state.isHidden = app.isHidden
		state.launchedAt = now
		state.createdSignalPending = true
		apps[app.pid] = state
		livenessState.createdSignalAt[app.pid] = now
		livenessState.launchRetries[app.pid] = LivenessLaunchRetry(
			launchedAt: now, attempts: 0, nextAt: now + LivenessTiming.launchBackoff[0])
	}

	/// The app signalled a window creation: windows its next scans find are created ones.
	mutating func livenessNoteCreated(pid: PID, now: Time) {
		guard pid != ownPID else { return }
		var state = apps[pid] ?? AppState(pid: pid)
		state.createdSignalPending = true
		apps[pid] = state
		livenessState.createdSignalAt[pid] = now
	}

	/// The focused window and frontmost app. Focus on a window the core does not track leaves
	/// `current` empty and never moves `lastTrackedMonitor`, so a new window taking focus does not
	/// change where created windows go. A read error keeps the last focus. An app launched aside
	/// that takes focus while its hold lasts gets it handed back.
	mutating func ingestFocus(_ facts: FocusFacts, now: Time) {
		let frontmostChanged = facts.frontmostBundleID != focus.frontmostBundleID
		focus.frontmostPID = facts.frontmostPID
		focus.frontmostBundleID = facts.frontmostBundleID
		admissionExpireLaunchAside(now: now)
		var focusChanged = false
		if facts.error == nil {
			let newCurrent = facts.focused.flatMap { records[$0] != nil ? $0 : nil }
			let oldCurrent = focus.current
			if newCurrent != oldCurrent {
				focusChanged = true
				if let newCurrent, let last = livenessState.lastFocused, last != newCurrent {
					focus.previous = last
				}
				focus.current = newCurrent
				focus.changedAt = now
				emit(.focusChanged(from: oldCurrent, to: newCurrent))
			}
			if let newCurrent {
				livenessState.lastFocused = newCurrent
				focus.currentMonitor = livenessMonitor(of: newCurrent)
				if let monitor = focus.currentMonitor {
					focus.lastTrackedMonitor = monitor
				}
			} else {
				focus.currentMonitor = nil
			}
		}
		if let bundleID = facts.frontmostBundleID, let until = launchAside[bundleID]?.holdFocusUntil, until > now,
			frontmostChanged || focusChanged {
			log("launch-aside: \(bundleID) took focus; handing it back")
			emit(.returnFocus(bundleID: bundleID))
		}
	}

	/// The monitor of a tracked window: its workspace's host, or for an unmanaged window the monitor
	/// holding it.
	private func livenessMonitor(of id: WindowID) -> MonitorKey? {
		if let location = location(id) {
			return location.monitor
		}
		return records[id]?.observed.frame.flatMap { monitorKey(for: $0) }
	}
}

// MARK: - Barrier and follow-ups

nonisolated extension TrackingState {
	/// Raises or clears one barrier reason. While any is set nothing is ingested or retired, and
	/// destroyed and terminated signals wait in `pendingDuringBarrier`. Once the set is empty the
	/// desktop is read again (scans are ingested from then on) and `liftBarrier(now:)` completes
	/// the exit.
	mutating func setBarrier(_ reason: BarrierReason, active: Bool, now: Time) {
		if active {
			guard !barrier.contains(reason) else { return }
			if barrier.isEmpty && !livenessState.liftPending {
				barrierSince = now
				livenessState.barrierReasons = []
			}
			barrier.insert(reason)
			livenessState.barrierReasons.insert(reason)
			livenessState.liftPending = false
			livenessState.rescannedApps = []
			log("barrier: up (\(reason.logName))")
		} else {
			guard barrier.contains(reason) else { return }
			barrier.remove(reason)
			livenessState.barrierReasons.insert(reason)
			if barrier.isEmpty {
				livenessState.liftPending = true
				livenessState.rescannedApps = []
			}
		}
	}

	/// Completes a barrier exit. Call once the barrier set is empty, the display geometry is stable,
	/// the topology is reconciled and the rescan of every app has been ingested (the first full scan
	/// at launch is ingested the same way, its windows admitted as startup ones). Applies the
	/// destroyed and terminated signals held during the barrier (a destroyed window is retired when
	/// the rescan no longer lists it, or without a complete rescan when the window server lacks it,
	/// else confirmed later), resets misses, pairs the windows re-created meanwhile with the ones
	/// they replace, and ends the ingest.
	mutating func liftBarrier(now: Time) {
		guard barrier.isEmpty, livenessState.liftPending || !pendingDuringBarrier.isEmpty else { return }
		livenessState.liftPending = true
		let signals = pendingDuringBarrier
		pendingDuringBarrier = []
		for signal in signals {
			switch signal {
			case .terminated(let pid):
				livenessApplyTerminated(pid, now: now)
			case .destroyed(let id, _):
				livenessApplyHeldDestroy(id, now: now)
			}
		}
		for id in records.keys.sorted() {
			guard let liveness = records[id]?.liveness, liveness.misses != 0 || liveness.lastMissAt != nil else { continue }
			records[id]?.liveness.misses = 0
			records[id]?.liveness.lastMissAt = nil
		}
		livenessState.liftPending = false
		pairReplacements(now: now)
		let reasons = BarrierReason.allCases.filter { livenessState.barrierReasons.contains($0) }.map(\.logName)
		let duration = barrierSince.map { " after \(String(format: "%.1f", now - $0))s" } ?? ""
		log("barrier: down\(duration) (\(reasons.joined(separator: ", "))); rescanned \(livenessState.rescannedApps.count) apps")
		barrierSince = nil
		livenessState.barrierReasons = []
		livenessState.rescannedApps = []
	}

	/// Scans to schedule: confirm scans (first misses, destroyed notifications, window-server
	/// absences), unreadable retries and launch retries, one per app at its earliest time. A confirm
	/// scan is due until a scan of the app is ingested at or after its time. None during a barrier.
	func livenessFollowUps(now: Time) -> [FollowUp] {
		guard barrier.isEmpty else { return [] }
		var earliest: [PID: (at: Time, reason: String)] = [:]
		func request(_ pid: PID, at time: Time, _ reason: String) {
			if let current = earliest[pid], current.at <= time { return }
			earliest[pid] = (time, reason)
		}
		for record in records.values {
			let lastScan = apps[record.pid]?.lastScanAt ?? -.infinity
			if record.liveness.misses > 0, let missAt = record.liveness.lastMissAt,
				missAt + LivenessTiming.confirmDelay > lastScan {
				request(record.pid, at: missAt + LivenessTiming.confirmDelay, "confirm miss")
			}
			if let since = record.liveness.pendingDestroySince, since + LivenessTiming.confirmDelay > lastScan {
				request(record.pid, at: since + LivenessTiming.confirmDelay, "confirm destroy")
			}
			if let since = record.observed.serverAbsentSince,
				let time = LivenessTiming.ghostConfirmOffsets.map({ since + $0 }).first(where: { $0 > lastScan }) {
				request(record.pid, at: time, "confirm window-server absence")
			}
		}
		for app in apps.values {
			if let time = app.nextRetryAt {
				request(app.pid, at: time, "unreadable retry")
			}
		}
		for (pid, retry) in livenessState.launchRetries {
			request(pid, at: retry.nextAt, "launch retry")
		}
		return earliest.keys.sorted().compactMap { pid in
			earliest[pid].map { FollowUp(at: $0.at, kind: .scan(pid), reason: $0.reason) }
		}
	}
}
