//
//  Liveness.swift
//  Axis
//
//  Whether tracked windows still exist. A record leaves only through `retire`, and only on
//  verified evidence: a destroyed notification the window server confirms, the app terminating,
//  or two complete scans plus the window server all missing it. Unreadable apps never lose
//  windows, and nothing is retired while a barrier is up.
//
//  Placeholder bodies: the rules are not implemented yet.
//

import Foundation
import CoreGraphics

/// Liveness bookkeeping that is not per record (confirm schedules, barrier replay, log dedupe).
/// Fields added here need default values.
nonisolated struct LivenessState: Equatable, Sendable {
	init() {}
}

nonisolated extension TrackingState {
	/// Ids to ask the window server about this pass: records of a pid that a complete scan did not
	/// list, plus ids named by destroyed notifications.
	func probeCandidates(scans: [PID: ScanResult], destroyed: Set<WindowID>) -> Set<WindowID> {
		var candidates = destroyed
		for (pid, result) in scans {
			guard case .complete(let windows) = result else { continue }
			let listed = Set(windows.map(\.id))
			for record in records.values where record.pid == pid && !listed.contains(record.id) {
				candidates.insert(record.id)
			}
		}
		return candidates
	}

	/// Window-server presence, on-screen state and bounds of tracked windows; ghost detection.
	mutating func ingestServer(_ snapshot: ServerSnapshot) {}

	/// One app's scan; `serverHas` = the probed ids the window server still has.
	mutating func ingestScan(pid: PID, result: ScanResult, serverHas: Set<WindowID>, now: Time) {}

	/// Fresh facts of single windows (minimized, deminiaturized, title changes).
	mutating func ingestWindowFacts(_ facts: [WindowFacts], now: Time) {}

	/// A destroyed notification; `serverHas` = the window server still lists the id.
	mutating func ingestDestroyed(id: WindowID, pid: PID?, serverHas: Bool, now: Time) {}

	mutating func ingestTerminated(pid: PID, now: Time) {}

	mutating func ingestFocus(_ facts: FocusFacts, now: Time) {}

	/// App facts (hidden flag, names) for the apps they name.
	mutating func ingestApps(_ apps: [AppFacts], now: Time) {}

	mutating func setBarrier(_ reason: BarrierReason, active: Bool, now: Time) {
		if active {
			if barrier.isEmpty {
				barrierSince = now
			}
			barrier.insert(reason)
		} else {
			barrier.remove(reason)
		}
	}

	/// Called once the barrier set is empty and the display geometry is stable.
	mutating func liftBarrier(now: Time) {}

	/// Confirm scans, unreadable retries, launch retries.
	func livenessFollowUps(now: Time) -> [FollowUp] {
		[]
	}

	/// Called by `retire` after the record left the state.
	mutating func livenessNoteRetire(_ retired: RetiredWindow) {}
}
