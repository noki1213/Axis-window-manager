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

// MARK: - Lenient decoding

/// Collects one short note per part of a saved file that was dropped while decoding. It travels
/// through `decoder.userInfo`, so the nested decoders can report without changing their results.
nonisolated final class PersistenceDecodeNotes: @unchecked Sendable {
	private(set) var notes: [String] = []

	func add(_ note: String) {
		notes.append(note)
	}

	static let userInfoKey = CodingUserInfoKey(rawValue: "com.noki.Axis.persistenceDecodeNotes")!
}

extension Decoder {
	fileprivate nonisolated func noteDropped(_ note: String) {
		(userInfo[PersistenceDecodeNotes.userInfoKey] as? PersistenceDecodeNotes)?.add(note)
	}
}

/// Decodes to nil instead of throwing, so an unkeyed container still advances past a bad element.
private nonisolated struct Lossy<T: Decodable>: Decodable {
	let value: T?

	init(from decoder: Decoder) throws {
		value = try? T(from: decoder)
	}
}

extension KeyedDecodingContainer {
	/// The value under `key`, nil when it is missing or has the wrong type. A wrong type is noted.
	fileprivate nonisolated func lenient<T: Decodable>(
		_ type: T.Type, forKey key: Key, decoder: Decoder, note: @autoclosure () -> String
	) -> T? {
		guard contains(key) else { return nil }
		do {
			return try decodeIfPresent(type, forKey: key)
		} catch {
			decoder.noteDropped(note())
			return nil
		}
	}

	/// The elements under `key` that decode; a missing or wrong-typed array gives []. One note per
	/// element that is skipped, and one for the missing array: every save writes it, so its
	/// absence means the file was cut or edited.
	fileprivate nonisolated func lossyArray<T: Decodable>(
		_ type: T.Type, forKey key: Key, decoder: Decoder, label: String
	) -> [T] {
		guard contains(key) else {
			decoder.noteDropped("\(label) list missing")
			return []
		}
		guard var list = try? nestedUnkeyedContainer(forKey: key) else {
			decoder.noteDropped("\(label) list unreadable")
			return []
		}
		return Self.drain(&list, decoder: decoder, label: label)
	}

	fileprivate nonisolated static func drain<T: Decodable>(
		_ list: inout UnkeyedDecodingContainer, decoder: Decoder, label: String
	) -> [T] {
		var result: [T] = []
		var position = 0
		while !list.isAtEnd {
			position += 1
			guard let element = try? list.decode(Lossy<T>.self) else {
				decoder.noteDropped("\(label) \(position) unreadable")
				break
			}
			if let value = element.value {
				result.append(value)
			} else {
				decoder.noteDropped("\(label) \(position) unreadable")
			}
		}
		return result
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

	/// The columns decide the layout; sizing ratios that cannot be read fall back to equal sizes.
	nonisolated init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decode(WorkspaceID.self, forKey: .id)
		side = try container.decode(Side.self, forKey: .side)
		columns = try container.decode([[WindowID]].self, forKey: .columns)
		widthRatios = container.lenient(
			[CGFloat].self, forKey: .widthRatios, decoder: decoder, note: "width ratios of workspace \(id) unreadable")
		rowRatios = container.lenient(
			[Int: [CGFloat]].self, forKey: .rowRatios, decoder: decoder, note: "row ratios of workspace \(id) unreadable") ?? [:]
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

	/// Only the identity is required; a field that cannot be read takes its default.
	nonisolated init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let id = try container.decode(WindowID.self, forKey: .id)
		self.id = id
		pid = try container.decode(PID.self, forKey: .pid)
		func field<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
			container.lenient(type, forKey: key, decoder: decoder, note: "\(key.stringValue) of window #\(id) unreadable")
		}
		bundleID = field(String.self, .bundleID)
		title = field(String.self, .title) ?? ""
		isFloating = field(Bool.self, .isFloating) ?? false
		workspace = field(WorkspaceID.self, .workspace)
		floatingFrame = field(RelativeFrame.self, .floatingFrame)
		observedFrame = field(CGRect.self, .observedFrame)
	}

	/// The same window in the same place: everything but the title and the observed frame.
	func hasSamePlacement(as other: PersistedWindow) -> Bool {
		id == other.id && pid == other.pid && bundleID == other.bundleID && isFloating == other.isFloating
			&& workspace == other.workspace && floatingFrame == other.floatingFrame
	}
}

/// Disconnected monitor state remembered so returning displays reclaim their layout.
nonisolated struct PersistedMemory: Codable, Equatable, Sendable {
	var key: MonitorKey
	var name: String
	var order: [WorkspaceID]
	var negativeCount: Int
	var active: WorkspaceID
	/// The monitor that took over the whole state, so the returning monitor does not take it back.
	var adoptedBy: MonitorKey?

	init(
		key: MonitorKey,
		name: String,
		order: [WorkspaceID],
		negativeCount: Int,
		active: WorkspaceID,
		adoptedBy: MonitorKey? = nil
	) {
		self.key = key
		self.name = name
		self.order = order
		self.negativeCount = negativeCount
		self.active = active
		self.adoptedBy = adoptedBy
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

	/// Monitors and windows must be present (a monitor that cannot be read rejects the file);
	/// everything else that cannot be read is left out.
	nonisolated init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		monitors = try container.decode([PersistedMonitor].self, forKey: .monitors)
		var list = try container.nestedUnkeyedContainer(forKey: .windows)
		windows = KeyedDecodingContainer<CodingKeys>.drain(&list, decoder: decoder, label: "window record")
		hiddenStack = container.lossyArray(HiddenEntry.self, forKey: .hiddenStack, decoder: decoder, label: "hidden entry")
		memory = container.lossyArray(PersistedMemory.self, forKey: .memory, decoder: decoder, label: "remembered monitor")
	}

	/// Serializes the snapshot to JSON data.
	func encode() throws -> Data {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
		return try encoder.encode(self)
	}

	/// Deserializes a snapshot from JSON data.
	static func decode(from data: Data) throws -> PersistenceSnapshot {
		try decodeReporting(from: data).snapshot
	}

	/// Deserializes a snapshot and lists what could not be read and was left out.
	static func decodeReporting(from data: Data) throws -> (snapshot: PersistenceSnapshot, dropped: [String]) {
		let notes = PersistenceDecodeNotes()
		let decoder = JSONDecoder()
		decoder.userInfo[PersistenceDecodeNotes.userInfoKey] = notes
		let snapshot = try decoder.decode(PersistenceSnapshot.self, from: data)
		return (snapshot, notes.notes)
	}

	/// Removes what a restore cannot use but that does not make the rest unreliable; returns one
	/// note per removal. Structure (monitors, workspaces, columns) is left to `validationProblem`.
	/// Ratios whose counts no longer fit the columns are not touched: a running state saves them
	/// that way between layouts, and both the restore and the layout skip them.
	mutating func sanitize() -> [String] {
		var notes: [String] = []
		func usable(_ ratios: [CGFloat]) -> Bool {
			ratios.allSatisfy { $0.isFinite && $0 > 0 }
		}
		for m in monitors.indices {
			for w in monitors[m].workspaces.indices {
				let id = monitors[m].workspaces[w].id
				if let ratios = monitors[m].workspaces[w].widthRatios, !usable(ratios) {
					monitors[m].workspaces[w].widthRatios = nil
					notes.append("width ratios of workspace \(id) are not positive numbers")
				}
				for (column, ratios) in monitors[m].workspaces[w].rowRatios.sorted(by: { $0.key < $1.key }) where !usable(ratios) {
					monitors[m].workspaces[w].rowRatios[column] = nil
					notes.append("row ratios of column \(column) of workspace \(id) are not positive numbers")
				}
			}
		}

		var windowIDs = Set<WindowID>()
		windows = windows.filter { window in
			guard windowIDs.insert(window.id).inserted else {
				notes.append("window #\(window.id) is saved twice")
				return false
			}
			return true
		}

		var hidden = Set<WindowID>()
		hiddenStack = hiddenStack.filter { entry in
			guard windowIDs.contains(entry.window) else {
				notes.append("hidden window #\(entry.window) has no record")
				return false
			}
			guard hidden.insert(entry.window).inserted else {
				notes.append("hidden window #\(entry.window) is listed twice")
				return false
			}
			return true
		}

		var remembered = Set<MonitorKey>()
		memory = memory.filter { entry in
			let problem: String?
			if entry.order.isEmpty {
				problem = "has no workspace"
			} else if !entry.order.contains(entry.active) {
				problem = "is active on a workspace it does not list"
			} else if entry.negativeCount < 0 || entry.negativeCount >= entry.order.count {
				problem = "has a negative count that leaves no home workspace"
			} else if (entry.order + [entry.active]).contains(where: { !Self.workspaceRawRange.contains($0.raw) }) {
				problem = "has a workspace id out of range"
			} else if !remembered.insert(entry.key).inserted {
				problem = "is remembered twice"
			} else {
				problem = nil
			}
			if let problem {
				notes.append("remembered monitor \(entry.key) \(problem)")
			}
			return problem == nil
		}
		return notes
	}

	var windowCount: Int {
		windows.count
	}

	var workspaceCount: Int {
		monitors.reduce(0) { $0 + $1.workspaces.count }
	}

	/// Restore adds 1 to the highest saved workspace id, so ids must stay clear of Int overflow.
	private static let workspaceRawRange = 0...Int(Int32.max)

	/// What makes the snapshot unusable, nil when it is consistent. The JSON decoder only checks the
	/// shape: a damaged or hand-edited file can still decode into rows that list a workspace twice
	/// or put a window in two columns, and that must never reach the state.
	func validationProblem() -> String? {
		var monitorKeys = Set<MonitorKey>()
		var workspaceIDs = Set<WorkspaceID>()
		var columnWindows = Set<WindowID>()
		for monitor in monitors {
			let ids = monitor.order + [monitor.active] + monitor.workspaces.map(\.id)
			if let id = ids.first(where: { !Self.workspaceRawRange.contains($0.raw) }) {
				return "workspace \(id) has an id out of range"
			}
			guard monitorKeys.insert(monitor.key).inserted else {
				return "monitor \(monitor.key) is listed twice"
			}
			guard !monitor.order.isEmpty else {
				return "monitor \(monitor.key) has no workspace"
			}
			guard monitor.negativeCount >= 0, monitor.negativeCount < monitor.order.count else {
				return "monitor \(monitor.key) has \(monitor.order.count) workspaces and negative count \(monitor.negativeCount)"
			}
			guard monitor.order.contains(monitor.active) else {
				return "monitor \(monitor.key) is active on a workspace it does not list"
			}
			let saved = monitor.workspaces.map(\.id)
			guard saved.count == monitor.order.count, Set(saved) == Set(monitor.order) else {
				return "monitor \(monitor.key) lists workspaces that do not match the saved ones"
			}
			for workspace in monitor.workspaces {
				guard workspaceIDs.insert(workspace.id).inserted else {
					return "workspace \(workspace.id) is saved twice"
				}
				for column in workspace.columns {
					guard !column.isEmpty else {
						return "workspace \(workspace.id) has an empty column"
					}
					for window in column {
						guard columnWindows.insert(window).inserted else {
							return "window #\(window) is in two columns"
						}
					}
				}
			}
		}
		for entry in memory {
			let ids = entry.order + [entry.active]
			if let id = ids.first(where: { !Self.workspaceRawRange.contains($0.raw) }) {
				return "workspace \(id) has an id out of range"
			}
		}
		var windowIDs = Set<WindowID>()
		for window in windows {
			guard windowIDs.insert(window.id).inserted else {
				return "window #\(window.id) is saved twice"
			}
		}
		return nil
	}

	/// Whether both snapshots hold the same workspaces, columns, floats, hidden stack and remembered
	/// monitors. Titles and observed frames change all the time and only help match windows after a
	/// reboot, so they are left out.
	func hasSameLayout(as other: PersistenceSnapshot) -> Bool {
		guard monitors == other.monitors, hiddenStack == other.hiddenStack, memory == other.memory,
			windows.count == other.windows.count
		else { return false }
		return zip(windows, other.windows).allSatisfy { $0.hasSamePlacement(as: $1) }
	}
}

/// State kept for persistence bookkeeping.
nonisolated struct PersistenceState: Equatable, Sendable {
	var lastSnapshot: PersistenceSnapshot?
	/// The problem of the last snapshot that was refused, so each distinct problem is logged once.
	var refusedProblem: String?

	init(lastSnapshot: PersistenceSnapshot? = nil, refusedProblem: String? = nil) {
		self.lastSnapshot = lastSnapshot
		self.refusedProblem = refusedProblem
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
				active: mem.active,
				adoptedBy: mem.adoptedBy
			))
		}

		return PersistenceSnapshot(
			monitors: persistedMonitors,
			windows: persistedWindows,
			hiddenStack: persistedHidden,
			memory: persistedMemory
		)
	}

	/// The snapshot to write now, nil when its layout is the one last written or loaded.
	mutating func persistenceTakeSnapshot() -> PersistenceSnapshot? {
		guard let current = persistenceCheckedSnapshot() else { return nil }
		if let last = persistenceState.lastSnapshot, last.hasSameLayout(as: current) {
			return nil
		}
		persistenceState.lastSnapshot = current
		return current
	}

	/// The snapshot of the state now for a save at quit, whether or not it changed; nil when it
	/// fails validation.
	mutating func persistenceSnapshotForQuit() -> PersistenceSnapshot? {
		persistenceCheckedSnapshot()
	}

	/// The snapshot of the state, nil when it fails validation: a file that restores must never
	/// be replaced by one that does not. The problem is logged once until it changes.
	private mutating func persistenceCheckedSnapshot() -> PersistenceSnapshot? {
		let current = snapshot()
		guard let problem = current.validationProblem() else {
			persistenceState.refusedProblem = nil
			return current
		}
		if persistenceState.refusedProblem != problem {
			persistenceState.refusedProblem = problem
			log("persist: not saved (\(problem))")
		}
		return nil
	}

	/// The write of the snapshot last taken failed: the next take offers the layout again.
	mutating func persistenceNoteWriteFailed() {
		persistenceState.lastSnapshot = nil
	}

	/// Restores the saved layout before the first window is admitted. Live windows are matched to
	/// the snapshot by (window ID, PID) first, then by (bundle ID, title) for windows whose ID
	/// changed. A matched window takes its saved workspace, column and placement; entries without a
	/// live window are dropped, and so are the workspaces they leave empty. Every other window is
	/// left to normal admission. Monitors that are not connected now are remembered for when they
	/// return.
	mutating func applyPersistence(
		_ snapshot: PersistenceSnapshot,
		windows: [WindowFacts] = [],
		apps: [AppFacts] = [],
		now: Time = 0
	) {
		guard records.isEmpty else {
			log("persist: ignored (windows are already tracked)")
			return
		}

		// Populate known application facts for bundle matching.
		for app in apps where self.apps[app.pid] == nil {
			self.apps[app.pid] = AppState(pid: app.pid, bundleID: app.bundleID, name: app.name, isHidden: app.isHidden)
		}
		var appBundles: [PID: String] = [:]
		var appNames: [PID: String] = [:]
		for (pid, app) in self.apps {
			appBundles[pid] = app.bundleID
			appNames[pid] = app.name
		}
		for app in apps {
			if let bundleID = app.bundleID {
				appBundles[app.pid] = bundleID
			}
			appNames[app.pid] = app.name
		}

		// Helper windows are never tracked, and dialogs and settings panes are matched by their id
		// only, never by their title. A window's size does not count: a stacked column leaves tiled
		// windows small.
		var candidates: [WindowFacts] = []
		var tiledClass = Set<WindowID>()
		var seen = Set<WindowID>()
		for facts in windows where !tombstones.contains(facts.id) && seen.insert(facts.id).inserted {
			let windowClass = Classifier.classify(
				facts, bundleID: appBundles[facts.pid], floatingApps: floatingApps, relaunchTiled: [facts.id])
			guard windowClass != .ignore else { continue }
			candidates.append(facts)
			if windowClass == .tiled {
				tiledClass.insert(facts.id)
			}
		}

		struct MatchedPair {
			let persisted: PersistedWindow
			let candidate: WindowFacts
			let bundleID: String?
			let appName: String
			let sameApp: Bool
		}

		let persistedByID = Dictionary(snapshot.windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
		var matchedCandidateIDs = Set<WindowID>()
		var matchedPersistedIDs = Set<WindowID>()
		var pairs: [MatchedPair] = []
		var rekeyed = [WindowID: WindowID]()

		// Primary matching: exact window ID and PID, which a relaunch of Axis leaves as they were. A
		// window of an app set to float comes back only as a floating window, never into the columns.
		for candidate in candidates {
			guard let persisted = persistedByID[candidate.id], persisted.pid == candidate.pid,
				persisted.isFloating || !((appBundles[candidate.pid] ?? persisted.bundleID).map { floatingApps.contains($0) } ?? false)
			else { continue }
			matchedCandidateIDs.insert(candidate.id)
			matchedPersistedIDs.insert(persisted.id)
			pairs.append(MatchedPair(
				persisted: persisted, candidate: candidate, bundleID: appBundles[candidate.pid] ?? persisted.bundleID,
				appName: appNames[candidate.pid] ?? "", sameApp: true
			))
		}

		// Fallback matching: bundle identifier and title for windows whose ID changed. The saved
		// frame closest to the window's own breaks ties between equal titles.
		for candidate in candidates where !matchedCandidateIDs.contains(candidate.id) && tiledClass.contains(candidate.id) {
			guard let bundle = appBundles[candidate.pid], !bundle.isEmpty, !candidate.title.isEmpty else { continue }
			func distance(_ saved: PersistedWindow) -> CGFloat {
				guard let frame = saved.observedFrame else { return 0 }
				return hypot(candidate.frame.midX - frame.midX, candidate.frame.midY - frame.midY)
			}
			let eligible = snapshot.windows.filter {
				!matchedPersistedIDs.contains($0.id) && $0.bundleID == bundle && $0.title == candidate.title
			}
			guard let best = eligible.min(by: { distance($0) < distance($1) }) else { continue }
			matchedCandidateIDs.insert(candidate.id)
			matchedPersistedIDs.insert(best.id)
			rekeyed[best.id] = candidate.id
			pairs.append(MatchedPair(
				persisted: best, candidate: candidate, bundleID: bundle,
				appName: appNames[candidate.pid] ?? "", sameApp: false
			))
		}

		// New workspace ids start above every saved one, so an id is never used twice.
		var nextRaw = nextWorkspaceRaw
		for monitor in snapshot.monitors {
			for id in monitor.order + monitor.workspaces.map(\.id) + [monitor.active] {
				nextRaw = max(nextRaw, id.raw + 1)
			}
		}
		for mem in snapshot.memory {
			for id in mem.order + [mem.active] {
				nextRaw = max(nextRaw, id.raw + 1)
			}
		}
		nextWorkspaceRaw = nextRaw

		let connected = Set(snapshot.monitors.map(\.key).filter { monitors[$0] != nil })
		persistenceReplacePlaceholders(restoring: connected)

		// Disconnected monitors from previous sessions remain in memory.
		for mem in snapshot.memory where monitors[mem.key] == nil && memory[mem.key] == nil {
			memory[mem.key] = MonitorMemory(
				key: mem.key,
				name: mem.name,
				order: mem.order,
				negativeCount: mem.negativeCount,
				active: mem.active,
				adoptedBy: mem.adoptedBy,
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

		// Only entries whose saved window matched a live one count: an unmatched saved id may equal
		// the id of a live window that belongs to another saved window.
		let hiddenIDs = Set(
			snapshot.hiddenStack.filter { matchedPersistedIDs.contains($0.window) }.map { rekeyed[$0.window] ?? $0.window })

		// Restore connected monitors and workspaces.
		for m in snapshot.monitors where connected.contains(m.key) {
			for persistedWS in m.workspaces {
				var restoredColumns: [[WindowID]] = []
				var survivingColumnIndices: [Int] = []

				for (colIdx, col) in persistedWS.columns.enumerated() {
					var newCol: [WindowID] = []
					for oldID in col {
						guard matchedPersistedIDs.contains(oldID), let saved = persistedByID[oldID],
							!saved.isFloating, saved.workspace == persistedWS.id
						else { continue }
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

				workspaces[persistedWS.id] = Workspace(
					id: persistedWS.id,
					host: m.key,
					origin: m.key,
					side: persistedWS.side,
					columns: restoredColumns,
					widthRatios: restoredWidthRatios,
					rowRatios: restoredRowRatios
				)
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

			if let oldID = rekeyed.first(where: { $0.value == newID })?.key {
				log("track: rekey #\(oldID) -> #\(newID) (\(pair.sameApp ? "same app and title" : "same bundle and title"))")
				emit(.rekeyed(from: oldID, to: newID))
			}
			let hostKey = workspaces[targetWS]!.host
			log("track: admit \(describe(draft)) -> \(describeMonitor(hostKey)) \(describeWorkspace(targetWS)) \(draft.placement == .floating ? "floating" : "tiled") (restored)")
			emit(.admitted(newID))
		}

		// Restore hidden stack entries.
		for entry in snapshot.hiddenStack where matchedPersistedIDs.contains(entry.window) {
			let targetID = rekeyed[entry.window] ?? entry.window
			if records[targetID] != nil {
				hiddenStack.append(HiddenEntry(window: targetID, minimizeConfirmed: entry.minimizeConfirmed))
				records[targetID]?.visibility = .axisMinimized
				// The planner unminimizes a window leaving the hide stack only when it minimized it,
				// which the run before this one did
				plannerState.minimized.insert(targetID)
			}
		}

		// A window that was minimized or hidden with its app when the snapshot was taken may be back
		// by now, and the other way round: it joins or leaves the columns the way such a change
		// during a run would.
		for id in records.keys.sorted() {
			guard let record = records[id], record.placement == .tiled, let workspace = record.workspace else { continue }
			let inColumns = workspaces[workspace]?.columns.contains { $0.contains(id) } ?? false
			if record.visibility.keepsSlot && !inColumns {
				insertByMidX(id, midX: record.observed.frame?.midX ?? .greatestFiniteMagnitude, into: workspace)
			} else if !record.visibility.keepsSlot && inColumns {
				let memory = removeFromColumns(id)
				records[id]?.slotMemory = memory
			}
		}

		// Tiled windows no scan listed (their app was busy) are tiled when they show up, however
		// small a stacked column left them, and go back to their saved place.
		let runningPIDs = Set(apps.map(\.pid))
		let candidatePID = Dictionary(candidates.map { ($0.id, $0.pid) }, uniquingKeysWith: { first, _ in first })
		var savedColumns: [WorkspaceID: [[WindowID]]] = [:]
		for monitor in snapshot.monitors where connected.contains(monitor.key) {
			for workspace in monitor.workspaces {
				savedColumns[workspace.id] = workspace.columns.map { $0.map { rekeyed[$0] ?? $0 } }
			}
		}
		for saved in snapshot.windows where !saved.isFloating {
			guard let savedWorkspace = saved.workspace else { continue }
			if matchedPersistedIDs.contains(saved.id) {
				let key = rekeyed[saved.id] ?? saved.id
				if let pid = candidatePID[key] {
					relaunchTiled[key] = RelaunchSlot(pid: pid, memory: nil)
				}
			} else if runningPIDs.contains(saved.pid) {
				let memory = savedColumns[savedWorkspace].flatMap {
					ColumnView.slotMemory(of: saved.id, in: $0, workspace: savedWorkspace)
				}
				relaunchTiled[saved.id] = RelaunchSlot(pid: saved.pid, memory: memory)
			}
		}

		// Workspaces whose windows are all gone go too, like at the end of a run.
		for m in snapshot.monitors where connected.contains(m.key) {
			compact(m.key, keepingActive: true)
		}

		let restored = records.values.filter { $0.source == .restored }
		let restoredWorkspaces = Set(restored.compactMap(\.workspace))
		log("persist: restored \(restored.count) windows, \(restoredWorkspaces.count) workspaces")

		persistenceState.lastSnapshot = snapshot
		normalize(now: now)
	}

	/// Restores the saved layout from the windows that the first scan of every app listed.
	mutating func applyPersistence(
		_ snapshot: PersistenceSnapshot,
		scans: [PID: ScanResult],
		apps: [AppFacts],
		now: Time = 0
	) {
		var windows: [WindowFacts] = []
		for pid in scans.keys.sorted() {
			windows += (scans[pid]?.windows ?? []).filter { $0.pid == pid }
		}
		applyPersistence(snapshot, windows: windows, apps: apps, now: now)
	}

	/// Clears the way for the saved workspace ids. Monitors found at launch got an empty workspace
	/// numbered from this run's counter, which can equal an id the snapshot saved for another
	/// monitor: a monitor that is restored drops its empty workspaces (its saved row replaces
	/// them), and any other connected monitor gets an empty workspace under a new id.
	private mutating func persistenceReplacePlaceholders(restoring restored: Set<MonitorKey>) {
		for key in monitorOrder {
			guard var monitor = monitors[key] else { continue }
			if restored.contains(key) {
				for id in monitor.order {
					workspaces[id] = nil
				}
				continue
			}
			var renamed: [WorkspaceID: WorkspaceID] = [:]
			for id in monitor.order {
				guard let old = workspaces[id] else { continue }
				let fresh = makeWorkspaceID()
				workspaces[id] = nil
				workspaces[fresh] = Workspace(
					id: fresh, host: old.host, origin: old.origin, side: old.side,
					columns: old.columns, widthRatios: old.widthRatios, rowRatios: old.rowRatios
				)
				renamed[id] = fresh
			}
			monitor.order = monitor.order.map { renamed[$0] ?? $0 }
			monitor.active = renamed[monitor.active] ?? monitor.active
			monitor.activeBeforeHosting = monitor.activeBeforeHosting.map { renamed[$0] ?? $0 }
			monitors[key] = monitor
		}
	}
}
