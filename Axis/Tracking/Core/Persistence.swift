//
//  Persistence.swift
//  Axis
//
//  Snapshots workspaces and window placement per monitor to preserve layout across relaunches.
//  On startup, live windows match against the persisted layout by window ID and process ID,
//  falling back to bundle identifier and title if IDs changed.
//

import Foundation
import CoreGraphics

// MARK: - Codable Identifier and Geometry Extensions

extension WorkspaceID: Codable {
	nonisolated public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		self.init(raw: try container.decode(Int.self))
	}

	nonisolated public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(raw)
	}
}

extension MonitorKey: Codable {
	nonisolated public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		self.init(raw: try container.decode(String.self))
	}

	nonisolated public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(raw)
	}
}

extension Side: Codable {
	nonisolated public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		let raw = try container.decode(String.self)
		switch raw {
		case "negative": self = .negative
		case "nonNegative": self = .nonNegative
		default: throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown side: \(raw)")
		}
	}

	nonisolated public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case .negative: try container.encode("negative")
		case .nonNegative: try container.encode("nonNegative")
		}
	}
}

extension Placement: Codable {
	nonisolated public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		let raw = try container.decode(String.self)
		switch raw {
		case "tiled": self = .tiled
		case "floating": self = .floating
		case "unmanaged": self = .unmanaged
		default: throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown placement: \(raw)")
		}
	}

	nonisolated public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case .tiled: try container.encode("tiled")
		case .floating: try container.encode("floating")
		case .unmanaged: try container.encode("unmanaged")
		}
	}
}

extension RelativeFrame: Codable {
	enum CodingKeys: CodingKey {
		case monitor
		case offset
		case size
	}

	nonisolated public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let monitor = try container.decode(MonitorKey.self, forKey: .monitor)
		let offset = try container.decode(CGPoint.self, forKey: .offset)
		let size = try container.decode(CGSize.self, forKey: .size)
		self.init(monitor: monitor, offset: offset, size: size)
	}

	nonisolated public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(monitor, forKey: .monitor)
		try container.encode(offset, forKey: .offset)
		try container.encode(size, forKey: .size)
	}
}

extension HiddenEntry: Codable {
	enum CodingKeys: CodingKey {
		case window
		case minimizeConfirmed
	}

	nonisolated public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let window = try container.decode(WindowID.self, forKey: .window)
		let minimizeConfirmed = try container.decode(Bool.self, forKey: .minimizeConfirmed)
		self.init(window: window, minimizeConfirmed: minimizeConfirmed)
	}

	nonisolated public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(window, forKey: .window)
		try container.encode(minimizeConfirmed, forKey: .minimizeConfirmed)
	}
}

// MARK: - Persisted Data Transfer Types

/// A saved workspace, including column window IDs and sizing ratios.
nonisolated struct PersistedWorkspace: Codable, Equatable, Sendable {
	var id: WorkspaceID
	var side: Side
	var columns: [[WindowID]]
	var widthRatios: [CGFloat]?
	var rowRatios: [Int: [CGFloat]]

	init(
		id: WorkspaceID,
		side: Side,
		columns: [[WindowID]],
		widthRatios: [CGFloat]? = nil,
		rowRatios: [Int: [CGFloat]] = [:]
	) {
		self.id = id
		self.side = side
		self.columns = columns
		self.widthRatios = widthRatios
		self.rowRatios = rowRatios
	}
}

/// A saved monitor and its row of workspaces.
nonisolated struct PersistedMonitor: Codable, Equatable, Sendable {
	var key: MonitorKey
	var name: String
	var order: [WorkspaceID]
	var negativeCount: Int
	var active: WorkspaceID
	var workspaces: [PersistedWorkspace]

	init(
		key: MonitorKey,
		name: String,
		order: [WorkspaceID],
		negativeCount: Int,
		active: WorkspaceID,
		workspaces: [PersistedWorkspace]
	) {
		self.key = key
		self.name = name
		self.order = order
		self.negativeCount = negativeCount
		self.active = active
		self.workspaces = workspaces
	}
}

/// A saved window placement record.
nonisolated struct PersistedWindow: Codable, Equatable, Sendable {
	var id: WindowID
	var pid: PID
	var bundleID: String?
	var title: String
	var isFloating: Bool
	var workspace: WorkspaceID?
	var floatingFrame: RelativeFrame?
	var observedFrame: CGRect?

	init(
		id: WindowID,
		pid: PID,
		bundleID: String? = nil,
		title: String = "",
		isFloating: Bool = false,
		workspace: WorkspaceID? = nil,
		floatingFrame: RelativeFrame? = nil,
		observedFrame: CGRect? = nil
	) {
		self.id = id
		self.pid = pid
		self.bundleID = bundleID
		self.title = title
		self.isFloating = isFloating
		self.workspace = workspace
		self.floatingFrame = floatingFrame
		self.observedFrame = observedFrame
	}
}

/// Disconnected monitor state remembered so returning displays reclaim their layout.
nonisolated struct PersistedMemory: Codable, Equatable, Sendable {
	var key: MonitorKey
	var name: String
	var order: [WorkspaceID]
	var negativeCount: Int
	var active: WorkspaceID

	init(
		key: MonitorKey,
		name: String,
		order: [WorkspaceID],
		negativeCount: Int,
		active: WorkspaceID
	) {
		self.key = key
		self.name = name
		self.order = order
		self.negativeCount = negativeCount
		self.active = active
	}
}

/// A complete snapshot of tracked workspaces, window placements and hidden windows.
nonisolated struct PersistenceSnapshot: Codable, Equatable, Sendable {
	var monitors: [PersistedMonitor]
	var windows: [PersistedWindow]
	var hiddenStack: [HiddenEntry]
	var memory: [PersistedMemory]

	init(
		monitors: [PersistedMonitor] = [],
		windows: [PersistedWindow] = [],
		hiddenStack: [HiddenEntry] = [],
		memory: [PersistedMemory] = []
	) {
		self.monitors = monitors
		self.windows = windows
		self.hiddenStack = hiddenStack
		self.memory = memory
	}

	/// Serializes the snapshot to JSON data.
	func encode() throws -> Data {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
		return try encoder.encode(self)
	}

	/// Deserializes a snapshot from JSON data.
	static func decode(from data: Data) throws -> PersistenceSnapshot {
		let decoder = JSONDecoder()
		return try decoder.decode(PersistenceSnapshot.self, from: data)
	}
}

/// State kept for persistence bookkeeping.
nonisolated struct PersistenceState: Equatable, Sendable {
	var lastSnapshot: PersistenceSnapshot?

	init(lastSnapshot: PersistenceSnapshot? = nil) {
		self.lastSnapshot = lastSnapshot
	}
}

// MARK: - Snapshot & Restore

nonisolated extension TrackingState {
	/// Captures a snapshot of current connected monitors, workspaces, windows and memory.
	func snapshot() -> PersistenceSnapshot {
		var persistedMonitors: [PersistedMonitor] = []
		for key in monitorOrder {
			guard let monitor = monitors[key] else { continue }
			var persistedWorkspaces: [PersistedWorkspace] = []
			for wsID in monitor.order {
				guard let ws = workspaces[wsID] else { continue }
				persistedWorkspaces.append(PersistedWorkspace(
					id: ws.id,
					side: ws.side,
					columns: ws.columns,
					widthRatios: ws.widthRatios,
					rowRatios: ws.rowRatios
				))
			}
			persistedMonitors.append(PersistedMonitor(
				key: monitor.key,
				name: monitor.name,
				order: monitor.order,
				negativeCount: monitor.negativeCount,
				active: monitor.active,
				workspaces: persistedWorkspaces
			))
		}

		var persistedWindows: [PersistedWindow] = []
		for id in records.keys.sorted() {
			guard let record = records[id] else { continue }
			// Unmanaged windows are heuristics-based and do not belong to managed workspaces.
			guard record.placement != .unmanaged else { continue }
			persistedWindows.append(PersistedWindow(
				id: record.id,
				pid: record.pid,
				bundleID: record.bundleID ?? apps[record.pid]?.bundleID,
				title: record.title,
				isFloating: record.placement == .floating,
				workspace: record.workspace,
				floatingFrame: record.floatingFrame,
				observedFrame: record.observed.frame
			))
		}

		let persistedHidden = hiddenStack.map {
			HiddenEntry(window: $0.window, minimizeConfirmed: $0.minimizeConfirmed)
		}

		var persistedMemory: [PersistedMemory] = []
		for key in memory.keys.sorted() {
			guard let mem = memory[key] else { continue }
			persistedMemory.append(PersistedMemory(
				key: mem.key,
				name: mem.name,
				order: mem.order,
				negativeCount: mem.negativeCount,
				active: mem.active
			))
		}

		return PersistenceSnapshot(
			monitors: persistedMonitors,
			windows: persistedWindows,
			hiddenStack: persistedHidden,
			memory: persistedMemory
		)
	}

	/// Encodes the current tracking state into serialized JSON data.
	func encodePersistence() throws -> Data {
		try snapshot().encode()
	}

	/// Decodes a persistence snapshot from JSON data.
	static func decodePersistence(from data: Data) throws -> PersistenceSnapshot {
		try PersistenceSnapshot.decode(from: data)
	}

	/// Restores persisted layout before the first window admission.
	/// Live candidate windows are matched against the snapshot by (window ID, PID) first,
	/// then by (bundle ID, title). Stale entries are dropped, and unmatched candidate windows
	/// remain unmanaged so they fall back to normal admission.
	mutating func applyPersistence(
		_ snapshot: PersistenceSnapshot,
		windows: [WindowFacts] = [],
		apps: [AppFacts] = [],
		now: Time = 0
	) {
		// Populate known application facts for bundle matching.
		for app in apps where self.apps[app.pid] == nil {
			self.apps[app.pid] = AppState(pid: app.pid, bundleID: app.bundleID, name: app.name, isHidden: app.isHidden)
		}

		struct MatchedPair {
			let persisted: PersistedWindow
			let candidate: WindowFacts
			let bundleID: String?
			let appName: String
			let sameApp: Bool
		}

		var matchedCandidateIDs = Set<WindowID>()
		var matchedPersistedIDs = Set<WindowID>()
		var pairs: [MatchedPair] = []
		var rekeyed = [WindowID: WindowID]()

		// Primary matching: exact window ID and PID from the same boot.
		for candidate in windows {
			guard !matchedCandidateIDs.contains(candidate.id) else { continue }
			if let persisted = snapshot.windows.first(where: {
				!matchedPersistedIDs.contains($0.id) && $0.id == candidate.id && $0.pid == candidate.pid
			}) {
				matchedCandidateIDs.insert(candidate.id)
				matchedPersistedIDs.insert(persisted.id)
				let bundle = apps.first(where: { $0.pid == candidate.pid })?.bundleID ?? self.apps[candidate.pid]?.bundleID ?? persisted.bundleID
				let appName = apps.first(where: { $0.pid == candidate.pid })?.name ?? self.apps[candidate.pid]?.name ?? ""
				pairs.append(MatchedPair(
					persisted: persisted, candidate: candidate, bundleID: bundle, appName: appName, sameApp: true
				))
			}
		}

		// Fallback matching: bundle identifier and title for windows whose ID changed across relaunches.
		for candidate in windows where !matchedCandidateIDs.contains(candidate.id) {
			let candidateBundle = apps.first(where: { $0.pid == candidate.pid })?.bundleID ?? self.apps[candidate.pid]?.bundleID
			guard let bundle = candidateBundle, !bundle.isEmpty else { continue }
			let eligible = snapshot.windows.filter {
				!matchedPersistedIDs.contains($0.id) && $0.bundleID == bundle && $0.title == candidate.title
			}
			guard !eligible.isEmpty else { continue }
			let best = eligible.min { a, b in
				let distA = hypot(candidate.frame.midX - (a.observedFrame?.midX ?? candidate.frame.midX),
				                  candidate.frame.midY - (a.observedFrame?.midY ?? candidate.frame.midY))
				let distB = hypot(candidate.frame.midX - (b.observedFrame?.midX ?? candidate.frame.midX),
				                  candidate.frame.midY - (b.observedFrame?.midY ?? candidate.frame.midY))
				return distA < distB
			}!
			matchedCandidateIDs.insert(candidate.id)
			matchedPersistedIDs.insert(best.id)
			rekeyed[best.id] = candidate.id
			let appName = apps.first(where: { $0.pid == candidate.pid })?.name ?? self.apps[candidate.pid]?.name ?? ""
			pairs.append(MatchedPair(
				persisted: best, candidate: candidate, bundleID: bundle, appName: appName, sameApp: false
			))
		}

		// Update workspace ID counter so restored IDs are strictly below the counter.
		var maxRaw = nextWorkspaceRaw
		for m in snapshot.monitors {
			for ws in m.workspaces {
				if ws.id.raw >= maxRaw { maxRaw = ws.id.raw + 1 }
			}
			if m.active.raw >= maxRaw { maxRaw = m.active.raw + 1 }
		}
		for m in snapshot.memory {
			for wsID in m.order {
				if wsID.raw >= maxRaw { maxRaw = wsID.raw + 1 }
			}
			if m.active.raw >= maxRaw { maxRaw = m.active.raw + 1 }
		}
		nextWorkspaceRaw = maxRaw

		// Disconnected monitors from previous sessions remain in memory.
		for mem in snapshot.memory where monitors[mem.key] == nil && memory[mem.key] == nil {
			memory[mem.key] = MonitorMemory(
				key: mem.key,
				name: mem.name,
				order: mem.order,
				negativeCount: mem.negativeCount,
				active: mem.active,
				adoptedBy: nil,
				at: now
			)
		}

		// Monitors present in snapshot but missing at relaunch move directly into remembered memory.
		for m in snapshot.monitors where monitors[m.key] == nil {
			memory[m.key] = MonitorMemory(
				key: m.key,
				name: m.name,
				order: m.order,
				negativeCount: m.negativeCount,
				active: m.active,
				adoptedBy: nil,
				at: now
			)
		}

		let hiddenIDs = Set(snapshot.hiddenStack.map { rekeyed[$0.window] ?? $0.window })

		// Restore connected monitors and workspaces.
		for m in snapshot.monitors where monitors[m.key] != nil {
			// Drop temporary placeholder workspaces created during monitor discovery.
			if let current = monitors[m.key] {
				for wsID in current.order where !m.order.contains(wsID) {
					workspaces.removeValue(forKey: wsID)
				}
			}

			for persistedWS in m.workspaces {
				var restoredColumns: [[WindowID]] = []
				var survivingColumnIndices: [Int] = []

				for (colIdx, col) in persistedWS.columns.enumerated() {
					var newCol: [WindowID] = []
					for oldID in col {
						guard matchedPersistedIDs.contains(oldID) else { continue }
						guard let pers = snapshot.windows.first(where: { $0.id == oldID }), !pers.isFloating else { continue }
						let newID = rekeyed[oldID] ?? oldID
						// Hidden stack entries leave columns with slot memory.
						guard !hiddenIDs.contains(newID) else { continue }
						newCol.append(newID)
					}
					if !newCol.isEmpty {
						restoredColumns.append(newCol)
						survivingColumnIndices.append(colIdx)
					}
				}

				var restoredRowRatios = [Int: [CGFloat]]()
				for (newIdx, oldIdx) in survivingColumnIndices.enumerated() {
					if let ratios = persistedWS.rowRatios[oldIdx], ratios.count == restoredColumns[newIdx].count {
						restoredRowRatios[newIdx] = ratios
					}
				}

				let restoredWidthRatios: [CGFloat]? = (restoredColumns.count > 1 && restoredColumns.count == persistedWS.columns.count)
					? persistedWS.widthRatios
					: nil

				let ws = Workspace(
					id: persistedWS.id,
					host: m.key,
					origin: m.key,
					side: persistedWS.side,
					columns: restoredColumns,
					widthRatios: restoredWidthRatios,
					rowRatios: restoredRowRatios
				)
				workspaces[persistedWS.id] = ws
			}

			monitors[m.key]?.order = m.order
			monitors[m.key]?.negativeCount = m.negativeCount
			monitors[m.key]?.active = m.order.contains(m.active) ? m.active : (m.order.first ?? m.active)
		}

		// Restore window records for matched windows belonging to connected workspaces.
		for pair in pairs {
			let facts = pair.candidate
			let persisted = pair.persisted
			let newID = facts.id

			guard let targetWS = persisted.workspace, workspaces[targetWS] != nil else { continue }

			var draft = WindowRecord(
				id: newID,
				pid: facts.pid,
				bundleID: pair.bundleID,
				appName: pair.appName,
				title: facts.title,
				role: facts.role,
				subrole: facts.subrole,
				hasCloseButton: facts.hasCloseButton,
				placement: persisted.isFloating ? .floating : .tiled,
				workspace: targetWS,
				observed: Observed(
					frame: facts.frame,
					frameAt: facts.takenAt,
					isMinimized: facts.isMinimized,
					isFullscreen: facts.isFullscreen,
					minSize: facts.minSize
				),
				floatingFrame: persisted.floatingFrame,
				pendingFloatRestore: persisted.isFloating,
				source: .restored,
				admittedAt: now
			)

			if hiddenIDs.contains(newID) {
				draft.slotMemory = SlotMemory(workspace: targetWS)
			}
			draft.visibility = resolveVisibility(draft)
			records[newID] = draft

			if !persisted.isFloating {
				relaunchTiled.insert(newID)
			}

			if let oldID = rekeyed.first(where: { $0.value == newID })?.key {
				log("track: rekey #\(oldID) -> #\(newID) (\(pair.sameApp ? "same app and title" : "same bundle and title"))")
				emit(.rekeyed(from: oldID, to: newID))
			}
			let hostKey = workspaces[targetWS]!.host
			log("track: admit \(describe(draft)) -> \(describeMonitor(hostKey)) \(describeWorkspace(targetWS)) \(draft.placement == .floating ? "floating" : "tiled") (restored)")
			emit(.admitted(newID))
		}

		// Restore hidden stack entries.
		for entry in snapshot.hiddenStack {
			let targetID = rekeyed[entry.window] ?? entry.window
			if records[targetID] != nil {
				hiddenStack.append(HiddenEntry(window: targetID, minimizeConfirmed: entry.minimizeConfirmed))
				records[targetID]?.visibility = .axisMinimized
			}
		}

		persistenceState.lastSnapshot = snapshot
		normalize(now: now)
	}

	/// Overload accepting an app lookup table.
	mutating func applyPersistence(
		_ snapshot: PersistenceSnapshot,
		windows: [WindowFacts],
		apps: [PID: AppFacts],
		now: Time = 0
	) {
		applyPersistence(snapshot, windows: windows, apps: Array(apps.values), now: now)
	}

	/// Convenience alias for applying persistence.
	mutating func apply(
		_ snapshot: PersistenceSnapshot,
		windows: [WindowFacts] = [],
		apps: [AppFacts] = [],
		now: Time = 0
	) {
		applyPersistence(snapshot, windows: windows, apps: apps, now: now)
	}
}
