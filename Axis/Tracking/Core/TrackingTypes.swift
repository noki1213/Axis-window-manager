//
//  TrackingTypes.swift
//  Axis
//
//  Identifier and clock types shared by the window-tracking core. The core is pure value-type
//  logic that imports only Foundation and CoreGraphics, so it can be built and tested without
//  AppKit or the Accessibility API.
//

import Foundation
import CoreGraphics

/// A window's identifier on the window server (the CGWindowID that the Accessibility bridge
/// reports for a window element). Unique across apps for as long as the window exists.
typealias WindowID = UInt32

/// A process identifier.
typealias PID = Int32

/// A point in monotonic time, in seconds (ProcessInfo.systemUptime). The core never reads a
/// clock: callers pass the current time in, so every decision can be replayed in a test.
typealias Time = TimeInterval

/// Identifies one workspace for the lifetime of the process.
/// The raw value comes from a counter that only goes up, so an ID is never reused after its
/// workspace is deleted. The number shown to the user is a separate, compacted index.
nonisolated struct WorkspaceID: Hashable, Comparable, Sendable {
	let raw: Int

	static func < (lhs: WorkspaceID, rhs: WorkspaceID) -> Bool {
		lhs.raw < rhs.raw
	}
}

/// Identifies one physical display in a way that survives reconnects and display-ID changes.
/// The raw value is the display's UUID string; it falls back to "display-<id>" when the system
/// reports no UUID, and displays that report the same UUID get a "#<n>" suffix in display-ID order.
nonisolated struct MonitorKey: Hashable, Sendable {
	let raw: String
}
