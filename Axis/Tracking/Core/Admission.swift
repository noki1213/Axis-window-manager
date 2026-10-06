//
//  Admission.swift
//  Axis
//
//  Turns a newly seen window into a record: pairs it with a just-retired window it replaces,
//  claims it for a launch-aside app, uses a placement reservation, or puts it on the monitor
//  that had focus (created windows) or the one holding it (anything else).
//
//  Placeholder bodies: the placement ladder is not implemented yet.
//

import Foundation
import CoreGraphics

/// Admission bookkeeping (recently retired windows for replacement pairing, ...).
/// Fields added here need default values.
nonisolated struct AdmissionState: Equatable, Sendable {
	init() {}
}

nonisolated extension TrackingState {
	/// Admits a window the core does not track yet. Returns its id, nil when it is not admitted
	/// (ignored class, tombstoned, already tracked).
	@discardableResult
	mutating func admit(_ facts: WindowFacts, app: AppFacts, source: AdmissionSource, now: Time) -> WindowID? {
		nil
	}

	/// Pairs windows admitted in this ingest with windows of the same app and title retired
	/// shortly before, handing over their place.
	mutating func pairReplacements(now: Time) {}

	/// The app's windows admitted from now on go to a workspace of their own on `monitor`.
	mutating func registerLaunchAside(bundleID: String, monitor: MonitorKey, now: Time) {}

	mutating func setReservation(_ reservation: PlacementReservation?) {
		self.reservation = reservation
	}

	/// Called by `retire` after the record left the state.
	mutating func admissionNoteRetire(_ retired: RetiredWindow) {}
}
