//
//  Topology.swift
//  Axis
//
//  Reconciles the connected displays with the monitors the state knows: keeps monitors by display
//  UUID, restores a returning monitor's workspaces from memory, lets a new monitor adopt a removed
//  one's whole state, and moves the workspaces of a removed monitor to another one. Never resets.
//
//  Placeholder body: adds unknown displays and refreshes known ones; the full reconciliation is
//  not implemented yet.
//

import Foundation
import CoreGraphics

/// What a reconciliation did, for the `topology:` log line.
nonisolated struct TopologyChange: Equatable, Sendable {
	var kept: [MonitorKey]
	var added: [MonitorKey]
	var removed: [MonitorKey]
	/// Returning monitors whose workspaces came back from memory.
	var restored: [MonitorKey]
	/// New monitor -> the removed monitor whose whole state it took over.
	var adopted: [MonitorKey: MonitorKey]
	/// Removed monitors whose workspaces moved to another monitor.
	var migrated: [MonitorKey]
	/// The input was degenerate (no displays, a zero-size display) and nothing changed.
	var ignored: Bool

	init(kept: [MonitorKey] = [], added: [MonitorKey] = [], removed: [MonitorKey] = [], restored: [MonitorKey] = [],
		adopted: [MonitorKey: MonitorKey] = [:], migrated: [MonitorKey] = [], ignored: Bool = false) {
		self.kept = kept
		self.added = added
		self.removed = removed
		self.restored = restored
		self.adopted = adopted
		self.migrated = migrated
		self.ignored = ignored
	}

	var isEmpty: Bool {
		added.isEmpty && removed.isEmpty && restored.isEmpty && adopted.isEmpty && migrated.isEmpty
	}
}

/// Topology bookkeeping. Fields added here need default values.
nonisolated struct TopologyState: Equatable, Sendable {
	init() {}
}

nonisolated enum TopologyPolicy {
	/// When a monitor returns, whether it takes back the workspaces another monitor adopted on its
	/// behalf. Off: they stay where they are and the returning monitor starts with an empty
	/// workspace.
	static let returningMonitorReclaimsAdoptedWorkspaces = false
}

nonisolated extension TrackingState {
	/// Brings the monitors in line with `displays` (in display order).
	@discardableResult
	mutating func reconcileTopology(_ displays: [DisplayFacts], now: Time) -> TopologyChange {
		var change = TopologyChange()
		guard !displays.isEmpty else {
			change.ignored = true
			return change
		}
		for display in displays {
			if monitors[display.key] != nil {
				updateMonitor(display)
				change.kept.append(display.key)
			} else {
				addMonitor(display)
				change.added.append(display.key)
			}
		}
		let connected = displays.map(\.key)
		monitorOrder = connected + monitorOrder.filter { !connected.contains($0) }
		return change
	}
}
