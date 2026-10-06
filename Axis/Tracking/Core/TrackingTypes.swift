//
//  TrackingTypes.swift
//  Axis
//
//  Value types shared by the window-tracking core: identifiers, the facts the system layer
//  gathers, the records, workspaces and sessions the core keeps, and the plans and events it
//  hands back. The core is pure value-type logic that imports only Foundation and CoreGraphics,
//  so it can be built and tested without AppKit or the Accessibility API.
//
//  Geometry is global and top-left based (Accessibility coordinates: origin at the primary
//  display's top-left corner, y growing downward) everywhere in the core.
//

import Foundation
import CoreGraphics

// MARK: - Identifiers and time

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
nonisolated struct WorkspaceID: Hashable, Comparable, Sendable, CustomStringConvertible {
	let raw: Int

	static func < (lhs: WorkspaceID, rhs: WorkspaceID) -> Bool {
		lhs.raw < rhs.raw
	}

	var description: String { "w\(raw)" }
}

/// Identifies one physical display in a way that survives reconnects and display-ID changes.
/// The raw value is the display's UUID string; it falls back to "display-<id>" when the system
/// reports no UUID, and displays that report the same UUID get a "#<n>" suffix in display-ID order.
nonisolated struct MonitorKey: Hashable, Comparable, Sendable, CustomStringConvertible {
	let raw: String

	static func < (lhs: MonitorKey, rhs: MonitorKey) -> Bool {
		lhs.raw < rhs.raw
	}

	var description: String { raw }
}

/// Accessibility role and subrole names the core compares against. They are plain strings so the
/// core does not need the Accessibility framework.
nonisolated enum AXNames {
	static let windowRole = "AXWindow"
	static let standardWindowSubrole = "AXStandardWindow"
	static let dialogSubrole = "AXDialog"
	static let systemDialogSubrole = "AXSystemDialog"
	static let floatingWindowSubrole = "AXFloatingWindow"
}

/// Raw AXError values the core reasons about (same numbers as the Accessibility framework).
nonisolated enum AXErrorCode {
	static let failure: Int32 = -25200
	static let invalidUIElement: Int32 = -25202
	/// The app did not answer in time (busy, hung, or the screen is locked).
	static let cannotComplete: Int32 = -25204
}

// MARK: - Facts gathered by the system layer (built off the main thread)

/// One window as the Accessibility API reported it.
nonisolated struct WindowFacts: Equatable, Sendable {
	var id: WindowID
	var pid: PID
	var role: String?
	var subrole: String?
	var title: String
	var frame: CGRect
	var isMinimized: Bool
	var isFullscreen: Bool
	var hasCloseButton: Bool
	var minSize: CGSize?
	/// When the facts were read. A frame read before Axis's last write to the window is stale.
	var takenAt: Time

	init(
		id: WindowID, pid: PID,
		role: String? = AXNames.windowRole, subrole: String? = AXNames.standardWindowSubrole,
		title: String = "", frame: CGRect = .zero,
		isMinimized: Bool = false, isFullscreen: Bool = false, hasCloseButton: Bool = true,
		minSize: CGSize? = nil, takenAt: Time = 0
	) {
		self.id = id
		self.pid = pid
		self.role = role
		self.subrole = subrole
		self.title = title
		self.frame = frame
		self.isMinimized = isMinimized
		self.isFullscreen = isFullscreen
		self.hasCloseButton = hasCloseButton
		self.minSize = minSize
		self.takenAt = takenAt
	}
}

/// The outcome of reading one app's window list.
nonisolated enum ScanResult: Equatable, Sendable {
	/// The window list and every window in it answered: a window missing from it is really
	/// missing from the app's point of view.
	case complete([WindowFacts])
	/// The window list answered but some window gave a messaging error. The listed windows are
	/// real; absence proves nothing.
	case incomplete([WindowFacts])
	/// The window list itself failed (raw AXError).
	case failed(Int32)
	/// No answer within the per-app budget.
	case timedOut

	var windows: [WindowFacts] {
		switch self {
		case .complete(let windows), .incomplete(let windows): return windows
		case .failed, .timedOut: return []
		}
	}

	var isComplete: Bool {
		if case .complete = self { return true }
		return false
	}
}

/// A running app with the regular activation policy (Axis itself is never reported).
nonisolated struct AppFacts: Equatable, Sendable {
	var pid: PID
	var bundleID: String?
	var name: String
	var isHidden: Bool

	init(pid: PID, bundleID: String? = nil, name: String = "", isHidden: Bool = false) {
		self.pid = pid
		self.bundleID = bundleID
		self.name = name
		self.isHidden = isHidden
	}
}

/// One window as the window server lists it.
nonisolated struct ServerWindow: Equatable, Sendable {
	var id: WindowID
	var pid: PID
	var bounds: CGRect
	var layer: Int
	var alpha: Double
	var isOnScreen: Bool

	init(id: WindowID, pid: PID, bounds: CGRect, layer: Int = 0, alpha: Double = 1, isOnScreen: Bool = true) {
		self.id = id
		self.pid = pid
		self.bounds = bounds
		self.layer = layer
		self.alpha = alpha
		self.isOnScreen = isOnScreen
	}
}

/// What the window server said at one moment.
nonisolated struct ServerSnapshot: Equatable, Sendable {
	nonisolated enum Scope: Equatable, Sendable {
		/// Every window on screen in the current Space. A window absent from it may still exist
		/// off screen, minimized or on another Space.
		case onScreen
		/// An existence probe of these ids (on or off screen). An id of the set that is absent no
		/// longer exists.
		case ids(Set<WindowID>)
	}

	var windows: [WindowID: ServerWindow]
	var scope: Scope
	var takenAt: Time

	init(windows: [WindowID: ServerWindow] = [:], scope: Scope = .onScreen, takenAt: Time = 0) {
		self.windows = windows
		self.scope = scope
		self.takenAt = takenAt
	}

	init(_ list: [ServerWindow], scope: Scope = .onScreen, takenAt: Time = 0) {
		self.init(windows: Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
			scope: scope, takenAt: takenAt)
	}
}

/// One connected display. Both frames are global and top-left based.
nonisolated struct DisplayFacts: Equatable, Sendable {
	var key: MonitorKey
	var displayID: UInt32
	var name: String
	var frame: CGRect
	/// The frame minus the menu bar and the Dock.
	var visibleFrame: CGRect
	var isPrimary: Bool

	init(key: MonitorKey, displayID: UInt32, name: String, frame: CGRect, visibleFrame: CGRect, isPrimary: Bool) {
		self.key = key
		self.displayID = displayID
		self.name = name
		self.frame = frame
		self.visibleFrame = visibleFrame
		self.isPrimary = isPrimary
	}
}

/// Which app is frontmost and which of its windows has focus.
nonisolated struct FocusFacts: Equatable, Sendable {
	var frontmostPID: PID?
	var frontmostBundleID: String?
	var focused: WindowID?
	/// Raw AXError when the focused window could not be read; the last known focus then stays.
	var error: Int32?

	init(frontmostPID: PID? = nil, frontmostBundleID: String? = nil, focused: WindowID? = nil, error: Int32? = nil) {
		self.frontmostPID = frontmostPID
		self.frontmostBundleID = frontmostBundleID
		self.focused = focused
		self.error = error
	}
}

// MARK: - Classification and state enums

/// How Axis manages a tracked window. Unmanaged windows (dialogs, small panels) belong to no
/// workspace; floating and tiled windows are members of exactly one.
nonisolated enum Placement: Hashable, Sendable {
	case tiled
	case floating
	case unmanaged
}

/// Why a window is parked at a screen corner.
nonisolated enum ParkReason: Hashable, Sendable {
	case workspaceInactive
}

/// Where a tracked window is meant to be. Resolved from sessions, flags and observations by
/// `normalize(now:)`; nothing else writes it.
nonisolated enum Visibility: Hashable, Sendable {
	case visible
	case parked(ParkReason)
	case zenHidden
	case paletteHidden
	/// Minimized by Axis's hide command.
	case axisMinimized
	/// Minimized by the user or the app.
	case nativeMinimized
	case nativeFullscreen
	/// Exists on the window server but on another Space.
	case otherSpace
	/// Its app is hidden (Cmd+H).
	case appHidden

	/// Whether a tiled window in this state keeps its place in the columns. The others leave the
	/// columns (remembering their neighbours) and come back when they return.
	var keepsSlot: Bool {
		switch self {
		case .visible, .parked, .zenHidden, .paletteHidden, .otherSpace: return true
		case .axisMinimized, .nativeMinimized, .nativeFullscreen, .appHidden: return false
		}
	}

	/// States the planner enforces by keeping the window parked at a corner.
	var isParkedKind: Bool {
		switch self {
		case .parked, .zenHidden, .paletteHidden: return true
		default: return false
		}
	}

	/// Axis keeps the window out of sight: parked at a corner (inactive workspace, Zen mode, the
	/// palette) or minimized by the hide command. The other states besides visible are the user's,
	/// the app's or macOS's doing (minimized from the window, fullscreen, another Space, app hidden).
	var isHiddenByAxis: Bool {
		isParkedKind || self == .axisMinimized
	}

	var logName: String {
		switch self {
		case .visible: return "visible"
		case .parked(let reason):
			switch reason {
			case .workspaceInactive: return "parked(workspaceInactive)"
			}
		case .zenHidden: return "zenHidden"
		case .paletteHidden: return "paletteHidden"
		case .axisMinimized: return "axisMinimized"
		case .nativeMinimized: return "nativeMinimized"
		case .nativeFullscreen: return "nativeFullscreen"
		case .otherSpace: return "otherSpace"
		case .appHidden: return "appHidden"
		}
	}
}

/// Why tracking is paused. While any reason is set nothing is retired, no scan is ingested and
/// nothing is enforced.
nonisolated enum BarrierReason: Hashable, Sendable, CaseIterable {
	/// Until the first full scan after launch.
	case starting
	case locked
	case asleep
	/// Display parameters are changing; lifted once the display geometry has been stable.
	case displayChanging
	case missionControl

	var logName: String {
		switch self {
		case .starting: return "starting"
		case .locked: return "locked"
		case .asleep: return "asleep"
		case .displayChanging: return "displayChanging"
		case .missionControl: return "missionControl"
		}
	}
}

/// Why a record was retired.
nonisolated enum RetireReason: Hashable, Sendable {
	case destroyed
	case appTerminated
	/// Missing from two complete scans and from the window server.
	case absent

	var logText: String {
		switch self {
		case .destroyed: return "destroyed"
		case .appTerminated: return "app terminated"
		case .absent: return "absent from 2 complete scans and window server"
		}
	}
}

/// How a window came to be tracked.
nonisolated enum AdmissionSource: Hashable, Sendable {
	/// The first full scan after launch.
	case startup
	/// Its app signalled a window creation since its last scan.
	case created
	/// Anything else: a Space change, an app readable again, the backstop watcher.
	case discovered
	/// Matched a saved snapshot from a previous run.
	case restored
}

/// The side of a monitor's workspace order a workspace was created on. Fixed at creation:
/// "previous" past the left end creates a negative workspace, "next" past the right end a
/// non-negative one.
nonisolated enum Side: Hashable, Sendable {
	case negative
	case nonNegative
}

/// A direction for moving windows and focus, in screen terms.
nonisolated enum MoveDirection: Hashable, Sendable {
	case left
	case right
	case up
	case down
}

/// An end of a workspace's column row.
nonisolated enum ColumnEdge: Hashable, Sendable {
	case left
	case right
}

/// Where the next new window goes after a placement reservation (the key pressed after the
/// reservation shortcut).
nonisolated enum ReservationKind: Hashable, Sendable {
	/// Stacked above the rest of the chosen column.
	case aboveInColumn
	/// Stacked below the rest of the chosen column.
	case belowInColumn
	case newColumnLeft
	case newColumnRight
	case float
}

/// A workspace to switch or move to, relative to a monitor's current one.
nonisolated enum WorkspaceTarget: Hashable, Sendable {
	case id(WorkspaceID)
	/// A workspace number on the monitor (0 = home, negatives to the left).
	case number(Int)
	/// The next workspace, created past the right end when there is none.
	case next
	/// The previous workspace, created past the left end when there is none.
	case prev
}

/// Why a Zen session ended.
nonisolated enum ZenExitReason: Hashable, Sendable {
	case user
	case focusClosed
	case hiddenClosed
	case tiledAdmitted
	case monitorGone
	case workspaceSwitched
	case paletteOpened
	case layoutReset

	var logText: String {
		switch self {
		case .user: return "user"
		case .focusClosed: return "focus window closed"
		case .hiddenClosed: return "hidden window closed"
		case .tiledAdmitted: return "tiled window admitted"
		case .monitorGone: return "monitor gone"
		case .workspaceSwitched: return "workspace switched"
		case .paletteOpened: return "palette opened"
		case .layoutReset: return "layout reset"
		}
	}
}

/// What changed a monitor's active workspace.
nonisolated enum ActiveChangeCause: Hashable, Sendable {
	/// A user command (switch, move to workspace).
	case command
	/// The active workspace was deleted for being empty; its neighbour took over.
	case compaction
	/// Displays were added, removed or replaced.
	case topology
}

/// What a column operation did.
nonisolated enum ColumnMoveResult: Hashable, Sendable {
	case none
	case moved
	case movedToMonitor(MonitorKey)
}

// MARK: - Window records

/// What was last observed about a window, from scans, window facts and window-server snapshots.
nonisolated struct Observed: Equatable, Sendable {
	/// Last known frame (window-server bounds or an Accessibility read).
	var frame: CGRect?
	var frameAt: Time?
	var isMinimized: Bool
	var isFullscreen: Bool
	var minSize: CGSize?
	/// Listed by the last complete scan of its app.
	var listedInLastCompleteScan: Bool
	/// The window server had it in the last snapshot or probe that covered it.
	var serverHas: Bool
	/// It was in the last on-screen snapshot.
	var onScreen: Bool
	/// First snapshot that missed it while the Accessibility API still listed it.
	var serverAbsentSince: Time?
	/// Consecutive snapshots that missed it.
	var serverAbsentCount: Int
	/// Absent from the window server long enough that the layout leaves it out; its column
	/// entry stays so a transient gap does not reshuffle the columns.
	var isServerGhost: Bool

	init(
		frame: CGRect? = nil, frameAt: Time? = nil,
		isMinimized: Bool = false, isFullscreen: Bool = false, minSize: CGSize? = nil,
		listedInLastCompleteScan: Bool = true, serverHas: Bool = true, onScreen: Bool = true,
		serverAbsentSince: Time? = nil, serverAbsentCount: Int = 0, isServerGhost: Bool = false
	) {
		self.frame = frame
		self.frameAt = frameAt
		self.isMinimized = isMinimized
		self.isFullscreen = isFullscreen
		self.minSize = minSize
		self.listedInLastCompleteScan = listedInLastCompleteScan
		self.serverHas = serverHas
		self.onScreen = onScreen
		self.serverAbsentSince = serverAbsentSince
		self.serverAbsentCount = serverAbsentCount
		self.isServerGhost = isServerGhost
	}
}

/// Evidence about whether a tracked window still exists.
nonisolated struct LivenessInfo: Equatable, Sendable {
	/// Complete scans of its app that did not list it while the window server lacked it too.
	var misses: Int
	var lastMissAt: Time?
	/// A destroyed notification arrived while the window server still had the id.
	var pendingDestroySince: Time?

	init(misses: Int = 0, lastMissAt: Time? = nil, pendingDestroySince: Time? = nil) {
		self.misses = misses
		self.lastMissAt = lastMissAt
		self.pendingDestroySince = pendingDestroySince
	}
}

/// A frame remembered relative to a monitor's visible area, so it can be put back on that
/// monitor after its geometry changes.
nonisolated struct RelativeFrame: Equatable, Sendable {
	var monitor: MonitorKey
	/// Offset of the frame's origin from the visible area's origin.
	var offset: CGPoint
	var size: CGSize

	init(monitor: MonitorKey, offset: CGPoint, size: CGSize) {
		self.monitor = monitor
		self.offset = offset
		self.size = size
	}

	init(frame: CGRect, monitor: MonitorKey, visibleFrame: CGRect) {
		self.init(monitor: monitor,
			offset: CGPoint(x: frame.minX - visibleFrame.minX, y: frame.minY - visibleFrame.minY),
			size: frame.size)
	}

	/// A frame of `size` centred in `visibleFrame`.
	static func centred(size: CGSize, monitor: MonitorKey, visibleFrame: CGRect) -> RelativeFrame {
		RelativeFrame(monitor: monitor,
			offset: CGPoint(x: (visibleFrame.width - size.width) / 2, y: (visibleFrame.height - size.height) / 2),
			size: size)
	}

	/// The absolute frame on a monitor whose visible area is `visibleFrame`. Moved inside the
	/// visible area along each axis where it fits, so a smaller screen does not strand it.
	func frame(in visibleFrame: CGRect) -> CGRect {
		func place(_ offset: CGFloat, _ length: CGFloat, _ minEdge: CGFloat, _ maxEdge: CGFloat) -> CGFloat {
			let origin = minEdge + offset
			guard length <= maxEdge - minEdge else { return origin }
			return min(max(origin, minEdge), maxEdge - length)
		}
		return CGRect(
			x: place(offset.x, size.width, visibleFrame.minX, visibleFrame.maxX),
			y: place(offset.y, size.height, visibleFrame.minY, visibleFrame.maxY),
			width: size.width, height: size.height)
	}
}

/// Where a tiled window sat when it left the columns (minimized, fullscreen, hidden app, or
/// retired), so it can come back next to the same neighbours.
nonisolated struct SlotMemory: Equatable, Sendable {
	/// The window above it in its column.
	var above: WindowID?
	/// The window below it in its column.
	var below: WindowID?
	/// The first window of the column to its left.
	var leftRep: WindowID?
	/// The first window of the column to its right.
	var rightRep: WindowID?
	/// The workspace whose columns it left.
	var workspace: WorkspaceID

	init(above: WindowID? = nil, below: WindowID? = nil, leftRep: WindowID? = nil, rightRep: WindowID? = nil, workspace: WorkspaceID) {
		self.above = above
		self.below = below
		self.leftRep = leftRep
		self.rightRep = rightRep
		self.workspace = workspace
	}
}

/// Everything the core keeps about one tracked window.
nonisolated struct WindowRecord: Equatable, Sendable {
	let id: WindowID
	let pid: PID
	var bundleID: String?
	var appName: String
	var title: String
	var role: String?
	var subrole: String?
	var hasCloseButton: Bool
	var placement: Placement
	/// Membership. Nil exactly when the placement is unmanaged. Visibility changes never touch it.
	var workspace: WorkspaceID?
	/// Written only by `normalize(now:)` (and given at construction).
	var visibility: Visibility
	var observed: Observed
	/// Where a floating or unmanaged window goes when it is shown again.
	var floatingFrame: RelativeFrame?
	/// The last frame seen while it was visible, for putting it back on screen at quit.
	var lastVisibleFrame: CGRect?
	/// Its place in the columns while it is out of them.
	var slotMemory: SlotMemory?
	/// Move a floating or unmanaged window to its floatingFrame once (after it was hidden, or
	/// after a float toggle centred it).
	var pendingFloatRestore: Bool
	var liveness: LivenessInfo
	var source: AdmissionSource
	var admittedAt: Time

	init(
		id: WindowID, pid: PID,
		bundleID: String? = nil, appName: String = "", title: String = "",
		role: String? = AXNames.windowRole, subrole: String? = AXNames.standardWindowSubrole,
		hasCloseButton: Bool = true,
		placement: Placement, workspace: WorkspaceID?, visibility: Visibility = .visible,
		observed: Observed = Observed(), floatingFrame: RelativeFrame? = nil, lastVisibleFrame: CGRect? = nil,
		slotMemory: SlotMemory? = nil, pendingFloatRestore: Bool = false, liveness: LivenessInfo = LivenessInfo(),
		source: AdmissionSource = .discovered, admittedAt: Time = 0
	) {
		self.id = id
		self.pid = pid
		self.bundleID = bundleID
		self.appName = appName
		self.title = title
		self.role = role
		self.subrole = subrole
		self.hasCloseButton = hasCloseButton
		self.placement = placement
		self.workspace = workspace
		self.visibility = visibility
		self.observed = observed
		self.floatingFrame = floatingFrame
		self.lastVisibleFrame = lastVisibleFrame
		self.slotMemory = slotMemory
		self.pendingFloatRestore = pendingFloatRestore
		self.liveness = liveness
		self.source = source
		self.admittedAt = admittedAt
	}
}

// MARK: - Workspaces and monitors

/// Gap between windows and padding from the visible area's edges, in points.
nonisolated struct LayoutConfig: Equatable, Sendable {
	var gap: CGFloat
	var padding: CGFloat

	init(gap: CGFloat = 12, padding: CGFloat = 12) {
		self.gap = gap
		self.padding = padding
	}
}

/// One workspace: an ordered row of columns (top to bottom within a column) plus size ratios.
nonisolated struct Workspace: Equatable, Sendable {
	let id: WorkspaceID
	/// The connected monitor that shows it now.
	var host: MonitorKey
	/// The monitor it was created on; differs from `host` while it is hosted on behalf of a
	/// disconnected monitor.
	var origin: MonitorKey
	var side: Side
	/// Tiled members whose visibility keeps a slot, left to right; each column top to bottom.
	var columns: [[WindowID]]
	/// Column width fractions, indexed like `layoutColumns` (the drawable view); nil = even.
	var widthRatios: [CGFloat]?
	/// Row height fractions per drawable column index.
	var rowRatios: [Int: [CGFloat]]

	init(id: WorkspaceID, host: MonitorKey, origin: MonitorKey? = nil, side: Side = .nonNegative,
		columns: [[WindowID]] = [], widthRatios: [CGFloat]? = nil, rowRatios: [Int: [CGFloat]] = [:]) {
		self.id = id
		self.host = host
		self.origin = origin ?? host
		self.side = side
		self.columns = columns
		self.widthRatios = widthRatios
		self.rowRatios = rowRatios
	}
}

/// A connected monitor and its workspace row.
nonisolated struct MonitorState: Equatable, Sendable {
	let key: MonitorKey
	var displayID: UInt32
	var name: String
	var frame: CGRect
	var visibleFrame: CGRect
	var isPrimary: Bool
	/// Workspaces left to right: `negativeCount` negative ones, then at least one non-negative.
	/// A workspace's number is its index minus `negativeCount` (0 = home).
	var order: [WorkspaceID]
	var negativeCount: Int
	var active: WorkspaceID
	/// The active workspace before this monitor started hosting a disconnected monitor's
	/// workspaces, to fall back to when they leave.
	var activeBeforeHosting: WorkspaceID?

	init(key: MonitorKey, displayID: UInt32 = 0, name: String = "", frame: CGRect = .zero, visibleFrame: CGRect = .zero,
		isPrimary: Bool = false, order: [WorkspaceID], negativeCount: Int = 0, active: WorkspaceID,
		activeBeforeHosting: WorkspaceID? = nil) {
		self.key = key
		self.displayID = displayID
		self.name = name
		self.frame = frame
		self.visibleFrame = visibleFrame
		self.isPrimary = isPrimary
		self.order = order
		self.negativeCount = negativeCount
		self.active = active
		self.activeBeforeHosting = activeBeforeHosting
	}
}

/// What a disconnected monitor had, so its workspaces can return to it.
nonisolated struct MonitorMemory: Equatable, Sendable {
	var key: MonitorKey
	var name: String
	var order: [WorkspaceID]
	var negativeCount: Int
	var active: WorkspaceID
	/// The monitor that took over this monitor's whole state when it left (a one-to-one swap).
	var adoptedBy: MonitorKey?
	var at: Time

	init(key: MonitorKey, name: String, order: [WorkspaceID], negativeCount: Int, active: WorkspaceID,
		adoptedBy: MonitorKey? = nil, at: Time) {
		self.key = key
		self.name = name
		self.order = order
		self.negativeCount = negativeCount
		self.active = active
		self.adoptedBy = adoptedBy
		self.at = at
	}
}

/// What the layout math needs from one workspace: the drawable columns and the stored ratios.
nonisolated struct LayoutInput: Equatable, Sendable {
	var columns: [[WindowID]]
	var widthRatios: [CGFloat]?
	var rowRatios: [Int: [CGFloat]]

	init(columns: [[WindowID]], widthRatios: [CGFloat]? = nil, rowRatios: [Int: [CGFloat]] = [:]) {
		self.columns = columns
		self.widthRatios = widthRatios
		self.rowRatios = rowRatios
	}
}

/// Where a managed window lives.
nonisolated struct WindowLocation: Equatable, Sendable {
	var monitor: MonitorKey
	var workspace: WorkspaceID
	var number: Int
}

// MARK: - Sessions

/// A Zen session: one window centred on its monitor, the rest of its workspace parked.
nonisolated struct ZenSession: Equatable, Sendable {
	var monitor: MonitorKey
	var workspace: WorkspaceID
	var focus: WindowID
	/// Width of the centred window as a fraction of the visible width.
	var widthRatio: CGFloat

	init(monitor: MonitorKey, workspace: WorkspaceID, focus: WindowID, widthRatio: CGFloat = 0.75) {
		self.monitor = monitor
		self.workspace = workspace
		self.focus = focus
		self.widthRatio = widthRatio
	}
}

/// The window palette is open: every managed window that would be visible is parked meanwhile.
nonisolated struct PaletteSession: Equatable, Sendable {
	var startedAt: Time
}

/// A window minimized by the hide command. The stack order is the array order (last = newest).
nonisolated struct HiddenEntry: Equatable, Sendable {
	var window: WindowID
	/// The window was seen minimized after the request, so seeing it unminimized again means the
	/// user restored it from the Dock.
	var minimizeConfirmed: Bool

	init(window: WindowID, minimizeConfirmed: Bool = false) {
		self.window = window
		self.minimizeConfirmed = minimizeConfirmed
	}
}

/// An app launched "aside": its windows go to a workspace of their own, out of sight.
nonisolated struct LaunchAsideEntry: Equatable, Sendable {
	var bundleID: String
	var monitor: MonitorKey
	/// Windows of the app admitted before this time are claimed.
	var deadline: Time
	/// Chosen when the first window is claimed, so later windows join it. May name a workspace
	/// that compaction has since deleted; a claim then creates a new one.
	var workspace: WorkspaceID?
	/// Until then the app is kept from taking focus.
	var holdFocusUntil: Time?

	init(bundleID: String, monitor: MonitorKey, deadline: Time, workspace: WorkspaceID? = nil, holdFocusUntil: Time? = nil) {
		self.bundleID = bundleID
		self.monitor = monitor
		self.deadline = deadline
		self.workspace = workspace
		self.holdFocusUntil = holdFocusUntil
	}
}

/// A reserved slot for the next new window.
nonisolated struct PlacementReservation: Equatable, Sendable {
	var kind: ReservationKind
	var monitor: MonitorKey
	/// Index in the drawable view of the monitor's active workspace when it was reserved.
	var columnIndex: Int

	init(kind: ReservationKind, monitor: MonitorKey, columnIndex: Int) {
		self.kind = kind
		self.monitor = monitor
		self.columnIndex = columnIndex
	}
}

/// Focus as the core last saw it.
nonisolated struct FocusState: Equatable, Sendable {
	/// The focused window when it is tracked.
	var current: WindowID?
	/// The monitor hosting `current`.
	var currentMonitor: MonitorKey?
	/// The monitor of the last focused tracked window. Only focus landing on a tracked window
	/// updates it, so a new window taking focus does not move it.
	var lastTrackedMonitor: MonitorKey?
	/// The focused window before `current`. May name a retired window.
	var previous: WindowID?
	var frontmostBundleID: String?

	init() {}
}

/// The outcome of an app's last scan.
nonisolated enum ScanStatus: Hashable, Sendable {
	case never
	case complete
	case incomplete
	case failed(Int32)
	case timedOut
}

/// One running app.
nonisolated struct AppState: Equatable, Sendable {
	let pid: PID
	var bundleID: String?
	var name: String
	var isHidden: Bool
	var lastScan: ScanStatus
	var lastScanAt: Time?
	/// Set while the app does not answer; its windows keep their slots and writes to them are skipped.
	var unresponsiveSince: Time?
	/// A window-created signal arrived since the last scan, so new windows are `created`.
	var createdSignalPending: Bool
	/// Unreadable-retry backoff step and when the next retry is due.
	var retryCount: Int
	var nextRetryAt: Time?
	/// Writes in a row the app did not answer; one it answers starts the count over. The longer the
	/// run, the longer the wait before the rescan that lets its windows be written again, so an app
	/// that reads fine but never takes a write is not retried at a fixed pace.
	var writeFailures: Int

	init(pid: PID, bundleID: String? = nil, name: String = "", isHidden: Bool = false,
		lastScan: ScanStatus = .never, lastScanAt: Time? = nil, unresponsiveSince: Time? = nil,
		createdSignalPending: Bool = false,
		retryCount: Int = 0, nextRetryAt: Time? = nil, writeFailures: Int = 0) {
		self.pid = pid
		self.bundleID = bundleID
		self.name = name
		self.isHidden = isHidden
		self.lastScan = lastScan
		self.lastScanAt = lastScanAt
		self.unresponsiveSince = unresponsiveSince
		self.createdSignalPending = createdSignalPending
		self.retryCount = retryCount
		self.nextRetryAt = nextRetryAt
		self.writeFailures = writeFailures
	}
}

// MARK: - Liveness bookkeeping

/// Ids of retired windows. Facts that name one are ignored: the Accessibility API can keep
/// listing a window for a moment after it closed. Bounded; the oldest ids are forgotten first.
nonisolated struct TombstoneSet: Equatable, Sendable {
	static let defaultCapacity = 4096

	let capacity: Int
	private(set) var ids: Set<WindowID> = []
	/// Ring buffer of ids in insertion order; `next` is the slot written next (the oldest once full).
	private var ring: [WindowID] = []
	private var next = 0

	init(capacity: Int = TombstoneSet.defaultCapacity) {
		self.capacity = max(1, capacity)
	}

	var count: Int { ids.count }

	func contains(_ id: WindowID) -> Bool {
		ids.contains(id)
	}

	mutating func insert(_ id: WindowID) {
		guard !ids.contains(id) else { return }
		if ring.count < capacity {
			ring.append(id)
		} else {
			ids.remove(ring[next])
			ring[next] = id
			next = (next + 1) % capacity
		}
		ids.insert(id)
	}
}

/// A signal held while a barrier is up, applied (and verified) after it lifts.
nonisolated enum PendingSignal: Hashable, Sendable {
	case destroyed(WindowID, pid: PID?)
	case terminated(PID)
}

/// A record as it was when it was retired, for pairing it with a replacement window.
nonisolated struct RetiredWindow: Equatable, Sendable {
	/// The record at retirement; `slotMemory` holds its place in the columns if it had one.
	var record: WindowRecord
	var reason: RetireReason
	var at: Time
	/// Its workspace's host and number at retirement (the workspace may since have been dropped).
	var monitor: MonitorKey?
	var number: Int?
	/// Its hidden-stack entry and position, if it was hidden.
	var hiddenEntry: HiddenEntry?
	var hiddenIndex: Int?
	/// It was the Zen session's focus window.
	var wasZenFocus: Bool
}

// MARK: - Plans and write results

/// What kind of write was made.
nonisolated enum WriteKind: Hashable, Sendable {
	case frame
	case park
	case minimize
	case unminimize
}

/// The last write Axis made to a window, so an app's clamped result is accepted instead of fought.
nonisolated struct LastWrite: Equatable, Sendable {
	var target: CGRect
	var kind: WriteKind
	/// The frame read back after the write.
	var result: CGRect?
	var at: Time
	/// Writes of the same target that found the window off target within a second of the last one.
	var fights: Int
	/// Enforcement leaves the window alone until then.
	var gaveUpUntil: Time?

	init(target: CGRect, kind: WriteKind, result: CGRect? = nil, at: Time, fights: Int = 0, gaveUpUntil: Time? = nil) {
		self.target = target
		self.kind = kind
		self.result = result
		self.at = at
		self.fights = fights
		self.gaveUpUntil = gaveUpUntil
	}
}

/// Why a plan action was made; logged with it.
nonisolated enum ActionReason: Equatable, Sendable {
	/// A tiled window's slot.
	case layout
	/// Leaving a parked state.
	case unpark(from: Visibility)
	/// Entering a parked state.
	case park(Visibility)
	/// Found away from where its state says it should be, without any command moving it.
	case enforce(observed: CGRect, expected: Visibility)
	case zenCentre
	/// Putting a floating or unmanaged window back at its floatingFrame.
	case floatRestore
	/// Bringing a window left out of sight back on screen.
	case rescue
	case hide
	case restore

	/// The reason as event-log lines show it, e.g. "workspaceInactive" in a park line.
	var logText: String {
		switch self {
		case .layout: return "layout"
		case .unpark(let from): return "from \(from.logName)"
		case .park(let visibility):
			if case .parked(let reason) = visibility {
				switch reason {
				case .workspaceInactive: return "workspaceInactive"
				}
			}
			return visibility.logName
		case .enforce(_, let expected): return "enforce \(expected.logName)"
		case .zenCentre: return "zen"
		case .floatRestore: return "float restore"
		case .rescue: return "rescue"
		case .hide: return "hide"
		case .restore: return "restore"
		}
	}
}

/// One write to one window.
nonisolated struct PlanAction: Equatable, Sendable {
	nonisolated enum Kind: Equatable, Sendable {
		case setFrame(CGRect)
		/// Move the window's top-left corner to this point, size unchanged.
		case park(CGPoint)
		case minimize
		case unminimize
	}

	var window: WindowID
	var pid: PID
	var kind: Kind
	var reason: ActionReason
	/// The frame seen when the action was planned (for logs).
	var observed: CGRect?
	/// How log lines name the window ("App/Title#id"), so the actuator needs no state.
	var label: String

	init(window: WindowID, pid: PID, kind: Kind, reason: ActionReason, observed: CGRect? = nil, label: String = "") {
		self.window = window
		self.pid = pid
		self.kind = kind
		self.reason = reason
		self.observed = observed
		self.label = label
	}
}

/// The actions for one app, so per-app setup (animation suppression) happens once per phase.
nonisolated struct PlanGroup: Equatable, Sendable {
	var pid: PID
	var actions: [PlanAction]

	init(pid: PID, actions: [PlanAction]) {
		self.pid = pid
		self.actions = actions
	}
}

/// Writes for the actuator, in two phases: windows coming on screen first, then windows leaving
/// it, so a switch never shows an empty screen.
nonisolated struct Plan: Equatable, Sendable {
	var show: [PlanGroup]
	var hide: [PlanGroup]
	/// A barrier held this command's writes back; plan again once it lifts.
	var withheldByBarrier: Bool
	/// Enforcement writes waited for the mouse button to be released.
	var deferredByMouse: Bool

	init(show: [PlanGroup] = [], hide: [PlanGroup] = [], withheldByBarrier: Bool = false, deferredByMouse: Bool = false) {
		self.show = show
		self.hide = hide
		self.withheldByBarrier = withheldByBarrier
		self.deferredByMouse = deferredByMouse
	}

	var isEmpty: Bool { show.isEmpty && hide.isEmpty }

	var actions: [PlanAction] { (show + hide).flatMap { $0.actions } }
}

/// What one write did.
nonisolated struct WriteResult: Equatable, Sendable {
	var window: WindowID
	var pid: PID
	var kind: WriteKind
	/// The requested frame (for a park: the park origin with the window's size).
	var target: CGRect
	/// The frame read back afterwards, nil when it could not be read.
	var result: CGRect?
	/// Raw AXError of a failed write; `AXErrorCode.cannotComplete` marks the app unresponsive.
	var error: Int32?

	init(window: WindowID, pid: PID, kind: WriteKind, target: CGRect, result: CGRect? = nil, error: Int32? = nil) {
		self.window = window
		self.pid = pid
		self.kind = kind
		self.target = target
		self.result = result
		self.error = error
	}
}

// MARK: - Pipeline

/// Something the system layer noticed. Sources post these to the coordinator on the main thread.
nonisolated enum TrackingSignal: Hashable, Sendable {
	// Accessibility observer
	case windowCreated(pid: PID)
	case windowDestroyed(id: WindowID, pid: PID)
	case windowMiniaturized(id: WindowID, pid: PID)
	case windowDeminiaturized(id: WindowID, pid: PID)
	case windowMoved(id: WindowID, pid: PID)
	case windowResized(id: WindowID, pid: PID)
	case focusedWindowChanged(pid: PID)
	case observerFailed(pid: PID)
	// Workspace and system notifications
	case appLaunched(pid: PID)
	case appTerminated(pid: PID)
	case appActivated(pid: PID)
	case appHidden(pid: PID)
	case appUnhidden(pid: PID)
	case activeSpaceChanged
	case screenParametersChanged
	case willSleep
	case didWake
	case screenLocked
	case screenUnlocked
	case leftMouseUp
	// Window-server watcher
	case missionControl(active: Bool)
	/// Layer-0 windows of a regular app that nothing tracks yet.
	case untrackedWindows(pid: PID, ids: Set<WindowID>)
	/// Tracked windows expected on screen that the on-screen list lacks.
	case missingWindows(pid: PID, ids: Set<WindowID>)
	/// Windows meant to be out of sight that are visible.
	case hiddenWindowsVisible(ids: Set<WindowID>)
}

/// Work the core asks the coordinator to schedule.
nonisolated struct FollowUp: Hashable, Sendable {
	nonisolated enum Kind: Hashable, Sendable {
		/// Rescan one app (confirm scan, unreadable retry, launch retry).
		case scan(PID)
		/// Run a pass that only re-plans from a fresh snapshot (delayed hide phase, fight retry).
		case frames
	}

	var at: Time
	var kind: Kind
	var reason: String

	init(at: Time, kind: Kind, reason: String) {
		self.at = at
		self.kind = kind
		self.reason = reason
	}
}

/// Something features react to. Appended to `TrackingState.events` and drained by the
/// coordinator after every call.
nonisolated enum TrackingEvent: Equatable, Sendable {
	case admitted(WindowID)
	case retired(WindowID, RetireReason)
	case rekeyed(from: WindowID, to: WindowID)
	case activeChanged(monitor: MonitorKey, from: WorkspaceID?, to: WorkspaceID, cause: ActiveChangeCause)
	case zenEnded(ZenExitReason)
	case focusChanged(from: WindowID?, to: WindowID?)
	/// Give focus back to the app that had it before a launch-aside app took it.
	case returnFocus(bundleID: String)
}

/// One event-log line, drained by the coordinator into the app log.
nonisolated struct TrackingLog: Equatable, Sendable {
	let message: String

	init(_ message: String) {
		self.message = message
	}
}
