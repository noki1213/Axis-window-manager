//
//  Topology.swift
//  Axis
//
//  Reconciles the connected displays with the monitors the state knows: keeps monitors by display
//  UUID, restores a returning monitor's workspaces from memory, lets a new monitor adopt a removed
//  one's whole state, and moves the workspaces of a removed monitor to another one. Never resets.
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

	/// Disambiguates displays that report the same UUID: the one with the lowest display ID keeps
	/// the plain key, and the others get "#2", "#3", ... in display-ID order.
	static func disambiguate(_ displays: [DisplayFacts]) -> [DisplayFacts] {
		guard displays.count > 1 else { return displays }
		func baseKey(from raw: String) -> String {
			if let hashIndex = raw.lastIndex(of: "#"),
				raw[raw.index(after: hashIndex)...].allSatisfy(\.isNumber) {
				return String(raw[..<hashIndex])
			}
			return raw
		}
		var result = displays
		let grouped = Dictionary(grouping: displays.indices, by: { baseKey(from: displays[$0].key.raw) })
		for (base, indices) in grouped where indices.count > 1 {
			let sortedIndices = indices.sorted(by: { displays[$0].displayID < displays[$1].displayID })
			for (rank, index) in sortedIndices.enumerated() {
				let uniqueRaw = rank == 0 ? base : "\(base)#\(rank + 1)"
				result[index].key = MonitorKey(raw: uniqueRaw)
			}
		}
		return result
	}
}

nonisolated enum TopologyPolicy {
	/// When a monitor returns, whether it takes back the workspaces another monitor adopted on its
	/// behalf. Off: they stay where they are and the returning monitor starts with an empty
	/// workspace.
	static var returningMonitorReclaimsAdoptedWorkspaces = false
}

nonisolated extension TrackingState {
	/// Brings the monitors in line with `displays` (in display order).
	@discardableResult
	mutating func reconcileTopology(_ displays: [DisplayFacts], now: Time) -> TopologyChange {
		var change = TopologyChange()

		// Degenerate input: no displays or any display with non-positive or sub-point dimension.
		guard !displays.isEmpty else {
			change.ignored = true
			return change
		}
		for display in displays {
			if display.frame.width <= 1 || display.frame.height <= 1
				|| display.visibleFrame.width <= 1 || display.visibleFrame.height <= 1 {
				change.ignored = true
				return change
			}
		}

		let uniqueDisplays = TopologyState.disambiguate(displays)
		let oldOrder = monitorOrder
		let oldMonitors = monitors
		let oldKeys = Set(oldMonitors.keys)
		let newKeys = uniqueDisplays.map(\.key)
		let newKeySet = Set(newKeys)

		// Kept monitors: update geometry and display identity.
		for display in uniqueDisplays where oldKeys.contains(display.key) {
			updateMonitor(display)
			change.kept.append(display.key)
		}

		let addedDisplays = uniqueDisplays.filter { !oldKeys.contains($0.key) }
		var unassignedRemoved = oldOrder.filter { !newKeySet.contains($0) }

		// Added with memory -> restore workspaces.
		var unhandledAdded: [DisplayFacts] = []
		for display in addedDisplays {
			if let mem = memory[display.key] {
				if mem.adoptedBy != nil && !TopologyPolicy.returningMonitorReclaimsAdoptedWorkspaces {
					// Adopted workspaces remain where they were adopted; the returning monitor
					// will receive a fresh empty workspace.
					memory.removeValue(forKey: display.key)
					unhandledAdded.append(display)
				} else {
					topologyRestoreMonitor(display, memory: mem)
					change.added.append(display.key)
					change.restored.append(display.key)
				}
			} else {
				unhandledAdded.append(display)
			}
		}

		// Added without memory, while removed monitors are unassigned -> adopt whole state.
		var remainingAdded: [DisplayFacts] = []
		for display in unhandledAdded {
			if !unassignedRemoved.isEmpty {
				let oldKey = unassignedRemoved.removeFirst()
				guard let oldMonitor = monitors[oldKey] else { continue }
				for wsID in oldMonitor.order {
					workspaces[wsID]?.host = display.key
				}
				monitors[display.key] = MonitorState(
					key: display.key,
					displayID: display.displayID,
					name: display.name,
					frame: display.frame,
					visibleFrame: display.visibleFrame,
					isPrimary: display.isPrimary,
					order: oldMonitor.order,
					negativeCount: oldMonitor.negativeCount,
					active: oldMonitor.active,
					activeBeforeHosting: oldMonitor.activeBeforeHosting
				)
				memory[oldKey] = MonitorMemory(
					key: oldKey,
					name: oldMonitor.name,
					order: oldMonitor.order,
					negativeCount: oldMonitor.negativeCount,
					active: oldMonitor.active,
					adoptedBy: display.key,
					at: now
				)
				monitors.removeValue(forKey: oldKey)
				change.added.append(display.key)
				change.removed.append(oldKey)
				change.adopted[display.key] = oldKey
			} else {
				remainingAdded.append(display)
			}
		}

		// Added with nothing to adopt -> start with a fresh empty workspace.
		for display in remainingAdded {
			addMonitor(display)
			change.added.append(display.key)
		}

		// Removed and not adopted -> save memory and migrate workspaces to the primary monitor.
		let primaryKey = uniqueDisplays.first(where: { $0.isPrimary })?.key ?? uniqueDisplays.first?.key
		for oldKey in unassignedRemoved {
			guard let oldMonitor = monitors[oldKey] else { continue }
			memory[oldKey] = MonitorMemory(
				key: oldKey,
				name: oldMonitor.name,
				order: oldMonitor.order,
				negativeCount: oldMonitor.negativeCount,
				active: oldMonitor.active,
				adoptedBy: nil,
				at: now
			)
			if let primaryKey, var primaryState = monitors[primaryKey] {
				if primaryState.activeBeforeHosting == nil {
					primaryState.activeBeforeHosting = primaryState.active
				}
				for wsID in oldMonitor.order {
					workspaces[wsID]?.host = primaryKey
					workspaces[wsID]?.side = .nonNegative
					primaryState.order.append(wsID)
				}
				monitors[primaryKey] = primaryState
			}
			monitors.removeValue(forKey: oldKey)
			change.removed.append(oldKey)
			change.migrated.append(oldKey)
		}

		// Order connected monitors by display order.
		monitorOrder = uniqueDisplays.map(\.key)

		// Emit active workspace changes for kept monitors whose active workspace changed.
		for key in change.kept {
			if let oldState = oldMonitors[key], let newState = monitors[key], oldState.active != newState.active {
				emit(.activeChanged(monitor: key, from: oldState.active, to: newState.active, cause: .topology))
			}
		}

		// End Zen when its monitor or active workspace is no longer present.
		if let currentZen = zen {
			if monitors[currentZen.monitor] == nil || monitors[currentZen.monitor]?.active != currentZen.workspace {
				zenExit(reason: .monitorGone)
			}
		}

		// End window palette session on topology changes.
		if palette != nil {
			paletteEnd()
		}

		// Keep focus monitors and placement reservation valid.
		if let currentM = focus.currentMonitor, monitors[currentM] == nil {
			focus.currentMonitor = primaryMonitor
		}
		if let lastTrackedM = focus.lastTrackedMonitor, monitors[lastTrackedM] == nil {
			focus.lastTrackedMonitor = primaryMonitor
		}
		if let res = reservation, monitors[res.monitor] == nil {
			reservation = nil
		}

		// Log reconciliation summary.
		let beforeText = oldOrder.map { describeMonitor($0) }.joined(separator: ", ")
		let afterText = monitorOrder.map { describeMonitor($0) }.joined(separator: ", ")
		let keptText = change.kept.map { describeMonitor($0) }.joined(separator: ", ")
		let restoredText = change.restored.map { describeMonitor($0) }.joined(separator: ", ")
		let adoptedText = change.adopted.keys.sorted().map { "\(describeMonitor($0)): \(describeMonitor(change.adopted[$0]!))" }.joined(separator: ", ")
		let migratedText = change.migrated.map { describeMonitor($0) }.joined(separator: ", ")
		log("topology: before [\(beforeText)] after [\(afterText)] kept [\(keptText)] restored [\(restoredText)] adopted [\(adoptedText)] migrated [\(migratedText)]")

		return change
	}

	private mutating func topologyRestoreMonitor(_ display: DisplayFacts, memory mem: MonitorMemory) {
		let stillExisting = Set(mem.order.filter { workspaces[$0] != nil })
		for wsID in mem.order where stillExisting.contains(wsID) {
			guard var ws = workspaces[wsID] else { continue }
			let currentHost = ws.host
			if currentHost != display.key, var hostState = monitors[currentHost] {
				if let idx = hostState.order.firstIndex(of: wsID) {
					hostState.order.remove(at: idx)
					if idx < hostState.negativeCount {
						hostState.negativeCount -= 1
					}
					if hostState.active == wsID {
						if let before = hostState.activeBeforeHosting,
							hostState.order.contains(before),
							!stillExisting.contains(before) {
							let oldActive = hostState.active
							hostState.active = before
							hostState.activeBeforeHosting = nil
							emit(.activeChanged(monitor: currentHost, from: oldActive, to: before, cause: .topology))
						} else {
							let fallback = hostState.order.first { !stillExisting.contains($0) && workspaces[$0]?.origin == currentHost }
								?? hostState.order.first { !stillExisting.contains($0) }
							if let fallback {
								let oldActive = hostState.active
								hostState.active = fallback
								emit(.activeChanged(monitor: currentHost, from: oldActive, to: fallback, cause: .topology))
							}
						}
					}
					let hasHosted = hostState.order.contains { workspaces[$0]?.origin != currentHost }
					if !hasHosted {
						hostState.activeBeforeHosting = nil
					}
					if hostState.negativeCount >= hostState.order.count {
						let home = makeWorkspaceID()
						workspaces[home] = Workspace(id: home, host: currentHost, side: .nonNegative)
						hostState.order.append(home)
						if hostState.active == wsID || !hostState.order.contains(hostState.active) {
							hostState.active = home
						}
					}
					monitors[currentHost] = hostState
				}
			}
			ws.host = display.key
			if let memIndex = mem.order.firstIndex(of: wsID), memIndex < mem.negativeCount {
				ws.side = .negative
			} else {
				ws.side = .nonNegative
			}
			workspaces[wsID] = ws
		}

		var restoredNegatives: [WorkspaceID] = []
		var restoredNonNegatives: [WorkspaceID] = []
		for wsID in mem.order where stillExisting.contains(wsID) {
			if let idx = mem.order.firstIndex(of: wsID), idx < mem.negativeCount {
				restoredNegatives.append(wsID)
			} else {
				restoredNonNegatives.append(wsID)
			}
		}
		if restoredNonNegatives.isEmpty {
			let home = makeWorkspaceID()
			workspaces[home] = Workspace(id: home, host: display.key, side: .nonNegative)
			restoredNonNegatives.append(home)
		}
		let newOrder = restoredNegatives + restoredNonNegatives
		let active: WorkspaceID
		if newOrder.contains(mem.active) {
			active = mem.active
		} else {
			active = restoredNonNegatives.first ?? newOrder.first!
		}
		monitors[display.key] = MonitorState(
			key: display.key,
			displayID: display.displayID,
			name: display.name,
			frame: display.frame,
			visibleFrame: display.visibleFrame,
			isPrimary: display.isPrimary,
			order: newOrder,
			negativeCount: restoredNegatives.count,
			active: active
		)
		memory.removeValue(forKey: display.key)
	}
}
