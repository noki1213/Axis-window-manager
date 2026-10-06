//
//  WriteLedger.swift
//  Axis
//
//  Remembers the last write to each window and what the window did with it, so a result the app
//  clamped (minimum size, cell snapping) is accepted, and a window something keeps moving away is
//  given up on for a while instead of fought in a loop.
//
//  Placeholder body: the ledger is not implemented yet.
//

import Foundation
import CoreGraphics

nonisolated extension TrackingState {
	/// Records what the actuator's writes did; an app that could not complete one is marked
	/// unresponsive.
	mutating func recordWrites(_ results: [WriteResult], now: Time) {}
}
