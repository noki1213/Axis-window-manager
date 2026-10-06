//
//  TrackingState.swift
//  Axis
//
//  The one value that holds everything the tracking core knows: window records, workspaces,
//  monitors, sessions, liveness and enforcement bookkeeping. A single writer on the main thread
//  mutates it through the functions of the core files; features read it only through the
//  queries below, so "is this window hidden?" has exactly one answer.
//
//  Every stored property lives here, because extensions in the other core files cannot add
//  stored properties. Each core module keeps its private bookkeeping in its own `<Module>State`
//  value, declared in its own file, so it can grow without touching this one.
//

import Foundation
import CoreGraphics

nonisolated struct TrackingState: Equatable, Sendable {
	// MARK: Configuration

	var config: LayoutConfig
	/// Axis's own process; its windows are never tracked.
	var ownPID: PID

	// MARK: Windows, workspaces, monitors

	var records: [WindowID: WindowRecord] = [:]
	var workspaces: [WorkspaceID: Workspace] = [:]
	/// Connected monitors.
	var monitors: [MonitorKey: MonitorState] = [:]
	/// Connected monitors in display order.
	var monitorOrder: [MonitorKey] = []
	/// Disconnected monitors, so their workspaces can return to them.
	var memory: [MonitorKey: MonitorMemory] = [:]
	var apps: [PID: AppState] = [:]

	// MARK: Sessions

	var zen: ZenSession?
	var palette: PaletteSession?
	/// Windows minimized by the hide command, oldest first.
	var hiddenStack: [HiddenEntry] = []
	/// Keyed by bundle identifier.
	var launchAside: [String: LaunchAsideEntry] = [:]
	var reservation: PlacementReservation?
	var focus = FocusState()

	// MARK: Liveness

	var barrier: Set<BarrierReason>
	/// When the current barrier went up (the set became non-empty).
	var barrierSince: Time?
	/// Destroyed and terminated signals that arrived during a barrier.
	var pendingDuringBarrier: [PendingSignal] = []
	var tombstones = TombstoneSet()
	/// Windows that were tiled when Axis last quit, so they are tiled again even when a stacked
	/// column left them small enough to look like dialogs.
	var relaunchTiled: Set<WindowID> = []

	// MARK: Enforcement

	var ledger: [WindowID: LastWrite] = [:]

	// MARK: Counters and output buffers

	var nextWorkspaceRaw = 1
	/// Event-log lines, drained by the coordinator after every call.
	var log: [TrackingLog] = []
	/// Feature events, drained by the coordinator after every call.
	var events: [TrackingEvent] = []

	// MARK: Module bookkeeping (types declared in the module files)

	var livenessState = LivenessState()
	var admissionState = AdmissionState()
	var visibilityState = VisibilityState()
	var plannerState = PlannerState()
	var topologyState = TopologyState()
	var persistenceState = PersistenceState()

	/// The coordinator starts with `barrier: [.starting]` until the first full scan.
	init(config: LayoutConfig = LayoutConfig(), ownPID: PID = -1, barrier: Set<BarrierReason> = []) {
		self.config = config
		self.ownPID = ownPID
		self.barrier = barrier
	}
}

// MARK: - Queries

nonisolated extension TrackingState {
	func record(_ id: WindowID) -> WindowRecord? {
		records[id]
	}

	func isTracked(_ id: WindowID) -> Bool {
		records[id] != nil
	}

	/// Nil for windows the core does not track.
	func visibility(_ id: WindowID) -> Visibility? {
		records[id]?.visibility
	}

	/// The one answer to "is this window hidden?": tracked and anywhere but visible. Untracked
	/// windows are never hidden.
	func isHidden(_ id: WindowID) -> Bool {
		guard let visibility = records[id]?.visibility else { return false }
		return visibility != .visible
	}

	func placement(_ id: WindowID) -> Placement? {
		records[id]?.placement
	}

	func isFloating(_ id: WindowID) -> Bool {
		records[id]?.placement == .floating
	}

	/// Whether the window takes a slot when its workspace is laid out: tiled, in a state that keeps
	/// its slot other than another Space, and not a window-server ghost. Column operations and focus
	/// moves work on the drawable windows only, so invisible entries never swallow a key press.
	func isDrawable(_ id: WindowID) -> Bool {
		guard let record = records[id], record.placement == .tiled, !record.observed.isServerGhost else { return false }
		switch record.visibility {
		case .visible, .parked, .zenHidden, .paletteHidden: return true
		case .axisMinimized, .nativeMinimized, .nativeFullscreen, .otherSpace, .appHidden: return false
		}
	}

	/// The monitor, workspace and workspace number of a managed window. The monitor is the
	/// workspace's host, never derived from the window's frame.
	func location(_ id: WindowID) -> WindowLocation? {
		guard let workspace = records[id]?.workspace,
			let host = workspaces[workspace]?.host,
			let number = number(of: workspace)
		else { return nil }
		return WindowLocation(monitor: host, workspace: workspace, number: number)
	}

	func activeWorkspace(_ monitor: MonitorKey) -> WorkspaceID? {
		monitors[monitor]?.active
	}

	func isActive(_ workspace: WorkspaceID) -> Bool {
		guard let host = workspaces[workspace]?.host else { return false }
		return monitors[host]?.active == workspace
	}

	/// A monitor's workspaces, left to right.
	func workspaceOrder(on monitor: MonitorKey) -> [WorkspaceID] {
		monitors[monitor]?.order ?? []
	}

	/// The number shown for a workspace: its index on its host minus the negative count (0 = home).
	func number(of workspace: WorkspaceID) -> Int? {
		guard let host = workspaces[workspace]?.host,
			let monitor = monitors[host],
			let index = monitor.order.firstIndex(of: workspace)
		else { return nil }
		return index - monitor.negativeCount
	}

	func workspace(number: Int, on monitor: MonitorKey) -> WorkspaceID? {
		guard let state = monitors[monitor] else { return nil }
		let index = number + state.negativeCount
		guard state.order.indices.contains(index) else { return nil }
		return state.order[index]
	}

	/// Every member of a workspace (any placement and visibility), by id.
	func members(of workspace: WorkspaceID) -> [WindowID] {
		records.values.filter { $0.workspace == workspace }.map(\.id).sorted()
	}

	func hasMembers(_ workspace: WorkspaceID) -> Bool {
		records.values.contains { $0.workspace == workspace }
	}

	/// Member counts per workspace (workspaces without members are absent).
	func memberCounts() -> [WorkspaceID: Int] {
		var counts: [WorkspaceID: Int] = [:]
		for record in records.values {
			if let workspace = record.workspace {
				counts[workspace, default: 0] += 1
			}
		}
		return counts
	}

	/// A workspace's windows in the order lists show them: the columns left to right, each top to
	/// bottom, then the members outside the columns (floating, minimized, fullscreen...) by id.
	func orderedWindows(_ workspace: WorkspaceID) -> [WindowID] {
		guard let columns = workspaces[workspace]?.columns else { return [] }
		var ordered: [WindowID] = []
		var seen = Set<WindowID>()
		for id in columns.joined() where records[id]?.workspace == workspace && seen.insert(id).inserted {
			ordered.append(id)
		}
		ordered += members(of: workspace).filter { !seen.contains($0) }
		return ordered
	}

	var primaryMonitor: MonitorKey? {
		monitorOrder.first { monitors[$0]?.isPrimary == true } ?? monitorOrder.first
	}

	func monitorKey(containing point: CGPoint) -> MonitorKey? {
		monitorOrder.first { monitors[$0]?.frame.contains(point) == true }
	}

	/// The monitor holding the frame's centre, else the monitor whose centre is nearest to it.
	func monitorKey(for frame: CGRect) -> MonitorKey? {
		let centre = CGPoint(x: frame.midX, y: frame.midY)
		if let key = monitorKey(containing: centre) { return key }
		func distance(_ key: MonitorKey) -> CGFloat {
			guard let frame = monitors[key]?.frame else { return .greatestFiniteMagnitude }
			return hypot(centre.x - frame.midX, centre.y - frame.midY)
		}
		return monitorOrder.min { distance($0) < distance($1) }
	}

	/// The monitor of the focused tracked window, else of the last focused tracked window, else
	/// the primary monitor.
	func focusMonitor() -> MonitorKey? {
		for key in [focus.currentMonitor, focus.lastTrackedMonitor] {
			if let key, monitors[key] != nil { return key }
		}
		return primaryMonitor
	}

	// MARK: Log text

	/// "App/Title#id"; an untracked window is "#id".
	func describe(_ id: WindowID) -> String {
		guard let record = records[id] else { return "#\(id)" }
		return describe(record)
	}

	func describe(_ record: WindowRecord) -> String {
		"\(record.appName.isEmpty ? "?" : record.appName)/\(record.title)#\(record.id)"
	}

	/// "ws<number + 1>[w<raw>]", the number as shown in the menu bar.
	func describeWorkspace(_ workspace: WorkspaceID) -> String {
		guard let number = number(of: workspace) else { return "ws?[\(workspace)]" }
		return "ws\(number + 1)[\(workspace)]"
	}

	func describeMonitor(_ key: MonitorKey) -> String {
		monitors[key]?.name ?? memory[key]?.name ?? key.raw
	}

	/// "x,y wxh" in whole points.
	static func describeFrame(_ frame: CGRect) -> String {
		func whole(_ value: CGFloat) -> String {
			value.isFinite ? String(Int(value.rounded())) : "?"
		}
		return "\(whole(frame.minX)),\(whole(frame.minY)) \(whole(frame.width))x\(whole(frame.height))"
	}
}

// MARK: - Output buffers

nonisolated extension TrackingState {
	mutating func log(_ message: String) {
		log.append(TrackingLog(message))
	}

	mutating func emit(_ event: TrackingEvent) {
		events.append(event)
	}

	mutating func drainLog() -> [TrackingLog] {
		defer { log = [] }
		return log
	}

	mutating func drainEvents() -> [TrackingEvent] {
		defer { events = [] }
		return events
	}

	/// Everything the core wants scheduled, earliest first.
	func followUps(now: Time) -> [FollowUp] {
		(livenessFollowUps(now: now) + plannerFollowUps(now: now)).sorted { $0.at < $1.at }
	}
}

// MARK: - Retire

nonisolated extension TrackingState {
	/// The only way a record leaves the state: out of its columns (remembering its place), the
	/// hidden stack, focus and the write ledger; its id is tombstoned, sessions and modules are
	/// told (Zen ends when its focus or a window it parked goes), and its monitor's empty
	/// workspaces are compacted. Returns what replacement pairing needs.
	/// `compacting: false` leaves the compaction to the caller, for retires that a replacement in
	/// the same pass may take the place of (call `compact(_:keepingActive: false)` afterwards).
	@discardableResult
	mutating func retire(_ id: WindowID, reason: RetireReason, now: Time, compacting: Bool = true) -> RetiredWindow? {
		guard var record = records[id] else { return nil }
		let host = record.workspace.flatMap { workspaces[$0]?.host }
		let workspaceNumber = record.workspace.flatMap { number(of: $0) }
		let hostName = host.map { describeMonitor($0) } ?? "?"
		let place = record.workspace.map { " from \(hostName) \(describeWorkspace($0))" } ?? ""
		log("track: retire \(describe(record)) (\(reason.logText))\(place)")

		if let memory = removeFromColumns(id) {
			record.slotMemory = memory
		}
		let hiddenIndex = hiddenStack.firstIndex { $0.window == id }
		let hiddenEntry = hiddenIndex.map { hiddenStack[$0] }
		hiddenStack.removeAll { $0.window == id }
		records[id] = nil
		ledger[id] = nil
		relaunchTiled.remove(id)
		tombstones.insert(id)
		if focus.current == id {
			focus.current = nil
		}

		let retired = RetiredWindow(record: record, reason: reason, at: now, monitor: host, number: workspaceNumber,
			hiddenEntry: hiddenEntry, hiddenIndex: hiddenIndex, wasZenFocus: zen?.focus == id)
		emit(.retired(id, reason))
		zenNoteRetire(record)
		livenessNoteRetire(retired)
		admissionNoteRetire(retired)
		plannerNoteRetire(id)
		if compacting, let host {
			compact(host, keepingActive: false)
		}
		return retired
	}
}

// MARK: - Invariants

nonisolated extension TrackingState {
	/// Broken structural rules, one message each; empty when the state is consistent. Run by every
	/// test and, in debug builds, after every pass. Visibility-dependent rules (I4-I6) hold after
	/// `normalize(now:)`.
	func checkInvariants() -> [String] {
		var problems: [String] = []
		let recordIDs = records.keys.sorted()

		for id in recordIDs {
			guard let record = records[id] else { continue }
			if record.id != id {
				problems.append("records[#\(id)] holds #\(record.id)")
			}
			if (record.placement == .unmanaged) != (record.workspace == nil) {
				problems.append("I8: #\(id) is \(record.placement) with workspace \(record.workspace.map { "\($0)" } ?? "nil")")
			}
			if let workspace = record.workspace, workspaces[workspace] == nil {
				problems.append("I1: #\(id) belongs to missing workspace \(workspace)")
			}
			if tombstones.contains(id) {
				problems.append("I9: #\(id) is tombstoned but tracked")
			}
		}

		var listedBy: [WorkspaceID: [MonitorKey]] = [:]
		if Set(monitorOrder).count != monitorOrder.count {
			problems.append("I2: monitor order lists a monitor twice")
		}
		for key in monitorOrder where monitors[key] == nil {
			problems.append("I2: monitor order lists unknown monitor \(key)")
		}
		for key in monitors.keys.sorted() {
			guard let monitor = monitors[key] else { continue }
			if monitor.key != key {
				problems.append("monitors[\(key)] holds \(monitor.key)")
			}
			if !monitorOrder.contains(key) {
				problems.append("I2: monitor \(key) missing from monitor order")
			}
			if monitor.negativeCount < 0 || monitor.negativeCount >= monitor.order.count {
				problems.append("I3: \(key) has \(monitor.order.count) workspaces and negative count \(monitor.negativeCount)")
			}
			if !monitor.order.contains(monitor.active) {
				problems.append("I3: \(key) active \(monitor.active) not in its order")
			}
			if Set(monitor.order).count != monitor.order.count {
				problems.append("I2: \(key) lists a workspace twice")
			}
			for workspace in monitor.order {
				listedBy[workspace, default: []].append(key)
			}
		}

		for workspaceID in workspaces.keys.sorted() {
			guard let workspace = workspaces[workspaceID] else { continue }
			if workspace.id != workspaceID {
				problems.append("workspaces[\(workspaceID)] holds \(workspace.id)")
			}
			if workspaceID.raw >= nextWorkspaceRaw {
				problems.append("\(workspaceID) is not below the id counter \(nextWorkspaceRaw)")
			}
			let hosts = Set(listedBy[workspaceID] ?? [])
			if hosts.count != 1 {
				problems.append("I2: \(workspaceID) is listed by \(hosts.count) monitors")
			} else if hosts.first != workspace.host {
				problems.append("I2: \(workspaceID) host \(workspace.host) but listed by \(hosts.first!)")
			}
		}
		for workspaceID in listedBy.keys.sorted() where workspaces[workspaceID] == nil {
			problems.append("I2: a monitor order lists missing workspace \(workspaceID)")
		}

		var inColumns = Set<WindowID>()
		for workspaceID in workspaces.keys.sorted() {
			guard let workspace = workspaces[workspaceID] else { continue }
			for (index, column) in workspace.columns.enumerated() {
				if column.isEmpty {
					problems.append("I4: \(workspaceID) column \(index) is empty")
				}
				for id in column {
					if !inColumns.insert(id).inserted {
						problems.append("I4: #\(id) appears in columns more than once")
					}
					guard let record = records[id] else {
						problems.append("I4: untracked #\(id) in \(workspaceID) columns")
						continue
					}
					if record.workspace != workspaceID {
						problems.append("I4: #\(id) in \(workspaceID) columns belongs to \(record.workspace.map { "\($0)" } ?? "nil")")
					}
					if record.placement != .tiled {
						problems.append("I4: #\(id) in \(workspaceID) columns is \(record.placement)")
					}
					if !record.visibility.keepsSlot {
						problems.append("I4: #\(id) in \(workspaceID) columns is \(record.visibility.logName)")
					}
				}
			}
		}
		for id in recordIDs {
			guard let record = records[id], record.placement == .tiled, record.visibility.keepsSlot,
				!inColumns.contains(id) else { continue }
			problems.append("I5: tiled #\(id) (\(record.visibility.logName)) is not in its columns")
		}

		var stacked = Set<WindowID>()
		for entry in hiddenStack {
			if !stacked.insert(entry.window).inserted {
				problems.append("I6: #\(entry.window) is in the hidden stack twice")
			}
			guard let record = records[entry.window] else {
				problems.append("I6: hidden stack holds untracked #\(entry.window)")
				continue
			}
			if record.visibility != .axisMinimized {
				problems.append("I6: hidden #\(entry.window) is \(record.visibility.logName)")
			}
		}

		if let zen {
			if records[zen.focus] == nil {
				problems.append("I7: Zen focus #\(zen.focus) is not tracked")
			}
			if monitors[zen.monitor]?.active != zen.workspace {
				problems.append("I7: Zen workspace \(zen.workspace) is not active on \(zen.monitor)")
			}
		}

		return problems
	}
}
