//
//  WriteLedger.swift
//  Axis
//
//  Remembers the last write to each window and what the window did with it, so a result the app
//  clamped (minimum size, cell snapping) is accepted, and a window something keeps moving away is
//  given up on for a while instead of fought in a loop.
//

import Foundation
import CoreGraphics

nonisolated extension TrackingState {
	/// Records what the actuator's writes did; an app that could not complete one is marked
	/// unresponsive.
	///
	/// A write of the same kind and target as the window's last one keeps its fight count (the
	/// planner counts a fight when it plans the correction); a new target starts over. A write the
	/// app did not answer is not recorded, since the window did not move: the app is skipped until
	/// a scan of it succeeds.
	mutating func recordWrites(_ results: [WriteResult], now: Time) {
		for result in results {
			if result.error == AXErrorCode.cannotComplete {
				if var app = apps[result.pid], app.unresponsiveSince == nil {
					app.unresponsiveSince = now
					apps[result.pid] = app
					let name = app.name.isEmpty ? "pid \(result.pid)" : app.name
					log("enforce: app \(name) did not answer a write; skipping its windows until it answers")
				}
				continue
			}
			guard records[result.window] != nil else { continue }
			let previous = ledger[result.window].flatMap {
				$0.kind == result.kind && PlannerPolicy.isSameTarget(result.kind, $0.target, result.target) ? $0 : nil
			}
			ledger[result.window] = LastWrite(target: result.target, kind: result.kind, result: result.result, at: now,
				fights: previous?.fights ?? 0, gaveUpUntil: previous?.gaveUpUntil)
		}
	}
}
