//
//  Admission.swift
//  Axis
//
//  Turns a newly seen window into a record: pairs it with a just-retired window it replaces,
//  claims it for a launch-aside app, uses a placement reservation, or puts it on the monitor
//  that had focus (created windows) or the one holding it (anything else).
//

import Foundation
import CoreGraphics

/// Admission bookkeeping. Fields added here need default values.
nonisolated struct AdmissionState: Equatable, Sendable {
	/// Recently retired windows a new window may replace, oldest first.
	var retired: [AdmissionRetiredEntry] = []
	/// Windows admitted since the last `pairReplacements(now:)`, oldest first.
	var admitted: [WindowID] = []
	/// Admitted windows whose Zen check waits for `pairReplacements(now:)`: a tracked window they
	/// may replace was still in doubt when they were admitted.
	var zenPending: Set<WindowID> = []
	/// Monitors a replacement took a window away from; their empty workspaces other than the
	/// active one are dropped when the ingest ends.
	var compactKeepingActive: Set<MonitorKey> = []

	init() {}
}

/// A retired window kept for replacement pairing.
nonisolated struct AdmissionRetiredEntry: Equatable, Sendable {
	var window: RetiredWindow
	/// Retired while a barrier was coming down: a window re-created during the barrier pairs with
	/// it however long the barrier lasted.
	var atBarrierExit: Bool
}

nonisolated enum AdmissionTiming {
	/// A window admitted at most this long after a window of the same app and title was retired
	/// takes its place.
	static let replacementWindow: TimeInterval = 2
	/// How long a launch-aside app's first window is awaited: launches can be slow or paused.
	static let launchAsideFirstWindowWait: TimeInterval = 300
	/// How long after the first claimed window the app's further windows still follow it.
	static let launchAsideFollowingWindowWait: TimeInterval = 20
	/// How long after a claim the app is kept from taking focus: launched apps activate themselves
	/// a moment after their first window.
	static let launchAsideFocusHold: TimeInterval = 3
	/// Bounds the bookkeeping kept between ingests.
	static let retainedLimit = 256
}

/// Where an admitted tiled window enters its workspace's columns.
nonisolated private enum AdmissionInsertion {
	case byMidX(CGFloat)
	/// Next to the neighbours a retired window had, else by `fallbackMidX`.
	case slot(SlotMemory, fallbackMidX: CGFloat)
	case reserved(ReservationKind, columnIndex: Int)
}

// MARK: - Admission

nonisolated extension TrackingState {
	/// Admits a window the core does not track yet. Returns its id, nil when it is not admitted
	/// (ignored class, tombstoned, already tracked, no monitor connected).
	///
	/// The first rule that applies places it: the place of a window of the same app and title
	/// retired shortly before; a launch-aside claim for its app (tiled, or floating for the
	/// unmanaged class); no workspace for the unmanaged class; a placement reservation (created
	/// windows, and discovered ones: a new window of an app that posts no creation notification is
	/// first seen that way; the startup scan's windows existed before the reservation was made); the
	/// active workspace of the monitor of the last focused tracked window (created windows); the
	/// active workspace of the monitor holding the window. A floating or unmanaged window admitted
	/// out of sight is brought back to the centre of its monitor. A tiled window joining the Zen
	/// workspace ends Zen, unless it replaces a window or is launched aside.
	@discardableResult
	mutating func admit(_ facts: WindowFacts, app: AppFacts, source: AdmissionSource, now: Time) -> WindowID? {
		guard records[facts.id] == nil, !tombstones.contains(facts.id), let fallbackMonitor = primaryMonitor else { return nil }
		let windowClass = Classifier.classify(
			facts, bundleID: app.bundleID, ownPID: ownPID, floatingApps: floatingApps, relaunchTiled: relaunchTiled)
		guard windowClass != .ignore else { return nil }
		admissionExpireLaunchAside(now: now)
		admissionPruneRetired(now: now)

		let frame = facts.frame
		var draft = WindowRecord(
			id: facts.id, pid: facts.pid, bundleID: app.bundleID, appName: app.name, title: facts.title,
			role: facts.role, subrole: facts.subrole, hasCloseButton: facts.hasCloseButton,
			placement: windowClass == .tiled ? .tiled : .unmanaged, workspace: nil,
			observed: Observed(frame: frame, frameAt: facts.takenAt, isMinimized: facts.isMinimized,
				isFullscreen: facts.isFullscreen, minSize: facts.minSize),
			source: source, admittedAt: now)

		if let match = admissionReplacement(for: draft, now: now) {
			let retired = admissionState.retired.remove(at: match.index).window
			let record = admissionTakePlace(draft, of: retired, fallback: nil)
			admissionLogAdmit(record, via: "replacement")
			emit(.admitted(record.id))
			admissionLogRekey(from: retired.record.id, to: record.id, sameApp: match.sameApp)
			emit(.rekeyed(from: retired.record.id, to: record.id))
			return record.id
		}

		let via: String
		var insertion = AdmissionInsertion.byMidX(frame.midX)
		var claimedFor: String?
		if let claim = admissionClaimLaunchAside(bundleID: app.bundleID, now: now) {
			draft.placement = windowClass == .tiled ? .tiled : .floating
			draft.workspace = claim.workspace
			if draft.placement == .floating {
				draft.floatingFrame = admissionFloatingFrame(frame, for: claim.monitor)
			}
			claimedFor = app.bundleID
			via = "launch-aside"
		} else if windowClass == .unmanaged {
			draft.floatingFrame = admissionFloatingFrame(frame, for: monitorKey(for: frame) ?? fallbackMonitor)
			via = "unmanaged class"
		} else if source == .created || source == .discovered, let reservation,
			let target = monitors[reservation.monitor]?.active {
			self.reservation = nil
			draft.workspace = target
			if reservation.kind == .float {
				draft.placement = .floating
				if let visibleFrame = monitors[reservation.monitor]?.visibleFrame {
					draft.floatingFrame = .centred(size: frame.size, monitor: reservation.monitor, visibleFrame: visibleFrame)
					draft.pendingFloatRestore = true
				}
			} else {
				insertion = .reserved(reservation.kind, columnIndex: reservation.columnIndex)
			}
			via = "reservation"
		} else if source == .created, let monitor = focus.lastTrackedMonitor, let target = monitors[monitor]?.active {
			draft.workspace = target
			insertion = .byMidX(admissionMidX(frame, on: monitor))
			via = "focus-monitor"
		} else {
			draft.workspace = monitors[monitorKey(for: frame) ?? fallbackMonitor]?.active
			via = "position"
		}

		// A window left out of sight (by a run that ended without restoring it) would otherwise
		// stay there: only tiled windows get a frame from the layout.
		if draft.placement != .tiled, !draft.pendingFloatRestore, admissionLooksHidden(frame) {
			let monitor = draft.workspace.flatMap { workspaces[$0]?.host } ?? monitorKey(for: frame) ?? fallbackMonitor
			if let visibleFrame = monitors[monitor]?.visibleFrame {
				draft.floatingFrame = .centred(size: frame.size, monitor: monitor, visibleFrame: visibleFrame)
				draft.pendingFloatRestore = true
				log("track: rescue \(describe(draft)) (admitted out of sight; centred on \(describeMonitor(monitor)))")
			}
		}

		let record = admissionStore(draft, insertion: insertion)
		admissionLogAdmit(record, via: via)
		emit(.admitted(record.id))
		admissionState.admitted.append(record.id)
		if admissionState.admitted.count > AdmissionTiming.retainedLimit {
			admissionState.admitted.removeFirst(admissionState.admitted.count - AdmissionTiming.retainedLimit)
		}
		if let claimedFor {
			let floating = record.placement == .floating ? " (floating)" : ""
			log("launch-aside: \(describe(record)) -> \(record.workspace.map { describeWorkspace($0) } ?? "?")\(floating)")
			emit(.returnFocus(bundleID: claimedFor))
		} else if zen != nil && (livenessState.liftPending || admissionHasDoubtfulTwin(record)) {
			admissionState.zenPending.insert(record.id)
		} else {
			zenNoteAdmission(record)
		}
		return record.id
	}

	/// Ends an ingest: pairs the windows admitted in it with windows of the same app and title
	/// retired within `replacementWindow` (or while the barrier just lifted), one to one, the same
	/// process first, then the same bundle, the closest frames first among equal titles. The new
	/// window takes the old one's place. Then runs the Zen checks that waited for the pairing and
	/// drops the workspaces the ingest emptied. While a barrier exit is in progress only the
	/// pairing runs; `liftBarrier(now:)` ends that ingest.
	mutating func pairReplacements(now: Time) {
		admissionExpireLaunchAside(now: now)
		admissionPruneRetired(now: now)
		var paired = Set<WindowID>()
		var usedEntries = Set<Int>()
		var matches: [(entry: Int, window: WindowID, sameApp: Bool)] = []
		for sameApp in [true, false] {
			var options: [(distance: CGFloat, entry: Int, window: WindowID)] = []
			for (index, entry) in admissionState.retired.enumerated()
			where !usedEntries.contains(index) && admissionIsEligible(entry, now: now) {
				for id in admissionState.admitted where !paired.contains(id) {
					guard let record = records[id],
						admissionMatches(entry.window.record, record, sameApp: sameApp, atBarrierExit: entry.atBarrierExit)
					else { continue }
					options.append((Self.admissionDistance(entry.window.record, record), index, id))
				}
			}
			options.sort { ($0.distance, $0.entry, $0.window) < ($1.distance, $1.entry, $1.window) }
			for option in options where !usedEntries.contains(option.entry) && !paired.contains(option.window) {
				usedEntries.insert(option.entry)
				paired.insert(option.window)
				matches.append((option.entry, option.window, sameApp))
			}
		}
		for match in matches {
			admissionRekey(match.window, replacing: admissionState.retired[match.entry].window, sameApp: match.sameApp)
		}
		admissionState.retired = admissionState.retired.enumerated()
			.filter { !usedEntries.contains($0.offset) }
			.map(\.element)
		admissionState.admitted.removeAll { paired.contains($0) }
		admissionState.zenPending.subtract(paired)
		guard !livenessState.liftPending else { return }

		let waiting = admissionState.zenPending.sorted()
		admissionState.zenPending = []
		admissionState.admitted = []
		for index in admissionState.retired.indices {
			admissionState.retired[index].atBarrierExit = false
		}
		for id in waiting {
			if let record = records[id] {
				zenNoteAdmission(record)
			}
		}
		let emptied = livenessState.compactPending
		let left = admissionState.compactKeepingActive.subtracting(emptied)
		livenessState.compactPending = []
		admissionState.compactKeepingActive = []
		// Retirements compact the way `retire` does; a monitor that only lost a window to a
		// replacement keeps its active workspace, which was there before the window arrived.
		for monitor in emptied.sorted() where monitors[monitor] != nil {
			compact(monitor, keepingActive: false)
		}
		for monitor in left.sorted() where monitors[monitor] != nil {
			compact(monitor, keepingActive: true)
		}
	}

	/// The app's windows admitted from now on go to a workspace of their own on `monitor`, out of
	/// sight: the first one within `launchAsideFirstWindowWait`, later ones within
	/// `launchAsideFollowingWindowWait` of the first.
	mutating func registerLaunchAside(bundleID: String, monitor: MonitorKey, now: Time) {
		launchAside[bundleID] = LaunchAsideEntry(
			bundleID: bundleID, monitor: monitor, deadline: now + AdmissionTiming.launchAsideFirstWindowWait)
	}

	/// The next tiled window that opens (created or discovered) goes where `reservation` points; nil
	/// cancels it.
	mutating func setReservation(_ reservation: PlacementReservation?) {
		self.reservation = reservation
	}

	/// Called by `retire` after the record left the state.
	mutating func admissionNoteRetire(_ retired: RetiredWindow) {
		let id = retired.record.id
		admissionState.admitted.removeAll { $0 == id }
		admissionState.zenPending.remove(id)
		admissionState.retired.append(AdmissionRetiredEntry(window: retired, atBarrierExit: livenessState.liftPending))
		if admissionState.retired.count > AdmissionTiming.retainedLimit {
			admissionState.retired.removeFirst(admissionState.retired.count - AdmissionTiming.retainedLimit)
		}
	}

	/// Drops launch-aside entries whose time ran out.
	mutating func admissionExpireLaunchAside(now: Time) {
		guard launchAside.values.contains(where: { $0.deadline <= now }) else { return }
		launchAside = launchAside.filter { $0.value.deadline > now }
	}

	/// Whether a window admitted in this ingest could take `old`'s place once it is retired.
	func admissionMayBeReplaced(_ old: WindowRecord) -> Bool {
		let atBarrierExit = livenessState.liftPending
		return admissionState.admitted.contains { id in
			guard let new = records[id] else { return false }
			return admissionMatches(old, new, sameApp: true, atBarrierExit: atBarrierExit)
				|| admissionMatches(old, new, sameApp: false, atBarrierExit: atBarrierExit)
		}
	}
}

// MARK: - Replacement

nonisolated extension TrackingState {
	/// Whether `new` may take the place of `old`: equal titles (an empty title identifies nothing
	/// outside a barrier exit) and the same process, or with `sameApp` false another process of the
	/// same bundle. A bundle being launched aside never pairs across processes: its new process's
	/// windows are meant to go aside, not into the old ones' places.
	private func admissionMatches(_ old: WindowRecord, _ new: WindowRecord, sameApp: Bool, atBarrierExit: Bool) -> Bool {
		guard old.id != new.id, old.title == new.title, atBarrierExit || !new.title.isEmpty else { return false }
		if sameApp {
			return old.pid == new.pid
		}
		guard old.pid != new.pid, let bundleID = new.bundleID, old.bundleID == bundleID else { return false }
		return launchAside[bundleID] == nil
	}

	private func admissionIsEligible(_ entry: AdmissionRetiredEntry, now: Time) -> Bool {
		entry.atBarrierExit || now - entry.window.at <= AdmissionTiming.replacementWindow
	}

	/// How far apart the windows' last known frames are, to choose among windows with equal titles.
	private static func admissionDistance(_ old: WindowRecord, _ new: WindowRecord) -> CGFloat {
		guard let from = old.lastVisibleFrame ?? old.observed.frame, let to = new.observed.frame else {
			return .greatestFiniteMagnitude
		}
		return hypot(from.midX - to.midX, from.midY - to.midY)
	}

	/// The retired window a window being admitted replaces, if any.
	private func admissionReplacement(for draft: WindowRecord, now: Time) -> (index: Int, sameApp: Bool)? {
		for sameApp in [true, false] {
			var best: (index: Int, distance: CGFloat)?
			for (index, entry) in admissionState.retired.enumerated()
			where admissionIsEligible(entry, now: now)
				&& admissionMatches(entry.window.record, draft, sameApp: sameApp, atBarrierExit: entry.atBarrierExit) {
				let distance = Self.admissionDistance(entry.window.record, draft)
				if best.map({ distance < $0.distance }) ?? true {
					best = (index, distance)
				}
			}
			if let best {
				return (best.index, sameApp)
			}
		}
		return nil
	}

	/// Whether a tracked window that `record` may replace is in doubt (not listed, missed, or with a
	/// destroyed notification pending), so it may still be retired in this ingest.
	private func admissionHasDoubtfulTwin(_ record: WindowRecord) -> Bool {
		records.values.contains { other in
			let inDoubt = !other.observed.listedInLastCompleteScan || other.liveness.misses > 0
				|| other.liveness.pendingDestroySince != nil
			return inDoubt && (admissionMatches(other, record, sameApp: true, atBarrierExit: false)
				|| admissionMatches(other, record, sameApp: false, atBarrierExit: false))
		}
	}

	/// Moves a window admitted earlier in this ingest into the place of the retired window it
	/// replaces.
	private mutating func admissionRekey(_ id: WindowID, replacing retired: RetiredWindow, sameApp: Bool) {
		guard let current = records[id] else { return }
		let leftHost = current.workspace.flatMap { workspaces[$0]?.host }
		removeFromColumns(id)
		hiddenStack.removeAll { $0.window == id }
		var draft = current
		draft.slotMemory = nil
		let record = admissionTakePlace(draft, of: retired, fallback: current.workspace)
		if let leftHost, record.workspace != current.workspace {
			admissionState.compactKeepingActive.insert(leftHost)
		}
		admissionLogRekey(from: retired.record.id, to: id, sameApp: sameApp)
		emit(.rekeyed(from: retired.record.id, to: id))
	}

	/// Stores `draft` (the new window's identity and observations) in the place of a retired
	/// window: its placement, its workspace (else the active one of its monitor, else `fallback`),
	/// its column slot, floating frame, last visible frame and hidden-stack entry. A tiled place
	/// goes to an app set to float since only as an unmanaged window.
	private mutating func admissionTakePlace(_ draft: WindowRecord, of retired: RetiredWindow, fallback: WorkspaceID?) -> WindowRecord {
		let old = retired.record
		var record = draft
		let floats = draft.bundleID.map { floatingApps.contains($0) } ?? false
		record.placement = old.placement == .tiled && floats ? .unmanaged : old.placement
		record.workspace = nil
		if record.placement != .unmanaged {
			let candidates: [WorkspaceID?] = [
				old.workspace,
				retired.monitor.flatMap { monitors[$0]?.active },
				fallback,
				primaryMonitor.flatMap { monitors[$0]?.active },
			]
			record.workspace = candidates.lazy.compactMap { $0 }.first { workspaces[$0] != nil }
			if record.workspace == nil {
				record.placement = .unmanaged
			}
		}
		record.floatingFrame = old.floatingFrame ?? draft.floatingFrame
		record.pendingFloatRestore = record.placement != .tiled && (old.floatingFrame != nil || old.pendingFloatRestore)
		record.lastVisibleFrame = old.lastVisibleFrame ?? draft.lastVisibleFrame
		record.slotMemory = nil
		if let entry = retired.hiddenEntry, record.workspace != nil, !hiddenStack.contains(where: { $0.window == record.id }) {
			let index = min(retired.hiddenIndex ?? hiddenStack.count, hiddenStack.count)
			hiddenStack.insert(HiddenEntry(window: record.id, minimizeConfirmed: entry.minimizeConfirmed), at: index)
			// The planner unminimizes a window leaving the hide stack only when it minimized it; the
			// new id inherits that, so restoring it brings it back.
			plannerState.minimized.insert(record.id)
		}
		let midX = old.lastVisibleFrame?.midX ?? draft.observed.frame?.midX ?? .greatestFiniteMagnitude
		let insertion: AdmissionInsertion = old.slotMemory.map { .slot($0, fallbackMidX: midX) } ?? .byMidX(midX)
		let stored = admissionStore(record, insertion: insertion)
		if focus.current == stored.id, let monitor = location(stored.id)?.monitor {
			focus.currentMonitor = monitor
			focus.lastTrackedMonitor = monitor
		}
		return stored
	}

	private mutating func admissionPruneRetired(now: Time) {
		admissionState.retired.removeAll {
			!$0.atBarrierExit && now - $0.window.at > AdmissionTiming.replacementWindow
		}
	}
}

// MARK: - Placement helpers

nonisolated extension TrackingState {
	/// Stores a new record with the visibility its state resolves to and puts a tiled window that
	/// keeps a slot into its workspace's columns; one that does not keep a slot remembers the slot
	/// it is inheriting.
	@discardableResult
	private mutating func admissionStore(_ draft: WindowRecord, insertion: AdmissionInsertion) -> WindowRecord {
		let id = draft.id
		let record = Self.admissionRecord(draft, visibility: resolveVisibility(draft))
		records[id] = record
		guard record.placement == .tiled, let workspace = record.workspace else { return record }
		if record.visibility.keepsSlot {
			switch insertion {
			case .reserved(let kind, let columnIndex):
				insertReserved(id, kind: kind, columnIndex: columnIndex, into: workspace)
			case .slot(let memory, let midX):
				if memory.workspace != workspace || !insertBySlotMemory(id, memory: memory, into: workspace) {
					insertByMidX(id, midX: midX, into: workspace)
				}
			case .byMidX(let midX):
				insertByMidX(id, midX: midX, into: workspace)
			}
		} else if case .slot(let memory, _) = insertion, memory.workspace == workspace {
			records[id]?.slotMemory = memory
		}
		return records[id] ?? record
	}

	/// `draft` with its initial visibility.
	private static func admissionRecord(_ draft: WindowRecord, visibility: Visibility) -> WindowRecord {
		WindowRecord(
			id: draft.id, pid: draft.pid, bundleID: draft.bundleID, appName: draft.appName, title: draft.title,
			role: draft.role, subrole: draft.subrole, hasCloseButton: draft.hasCloseButton,
			placement: draft.placement, workspace: draft.workspace, visibility: visibility,
			observed: draft.observed, floatingFrame: draft.floatingFrame, lastVisibleFrame: draft.lastVisibleFrame,
			slotMemory: draft.slotMemory, pendingFloatRestore: draft.pendingFloatRestore,
			liveness: draft.liveness, source: draft.source, admittedAt: draft.admittedAt)
	}

	/// Claims a window for its app's launch-aside entry: the entry's workspace, created at the end
	/// of the monitor's row at the first claim (and again if it was dropped meanwhile). The first
	/// claim leaves `launchAsideFollowingWindowWait` for further windows; every claim keeps the app
	/// from taking focus for `launchAsideFocusHold`.
	private mutating func admissionClaimLaunchAside(bundleID: String?, now: Time) -> (workspace: WorkspaceID, monitor: MonitorKey)? {
		guard let bundleID, var entry = launchAside[bundleID], entry.deadline > now else { return nil }
		guard let monitor = monitors[entry.monitor] != nil ? entry.monitor : focusMonitor() else { return nil }
		let firstClaim = entry.workspace == nil
		let existing = entry.workspace.flatMap { workspaces[$0] != nil ? $0 : nil }
		guard let workspace = existing ?? createWorkspaceAtEnd(on: monitor) else { return nil }
		if firstClaim {
			entry.deadline = now + AdmissionTiming.launchAsideFollowingWindowWait
		}
		entry.monitor = monitor
		entry.workspace = workspace
		entry.holdFocusUntil = now + AdmissionTiming.launchAsideFocusHold
		launchAside[bundleID] = entry
		return (workspace, workspaces[workspace]?.host ?? monitor)
	}

	/// `frame` as an offset inside the visible area of the monitor showing it, kept for `monitor`.
	private func admissionFloatingFrame(_ frame: CGRect, for monitor: MonitorKey) -> RelativeFrame? {
		guard let visibleFrame = monitors[monitorKey(for: frame) ?? monitor]?.visibleFrame else { return nil }
		return RelativeFrame(frame: frame, monitor: monitor, visibleFrame: visibleFrame)
	}

	/// The horizontal centre that orders a new column on `monitor`: the window's own, or for a
	/// window shown on another monitor its relative position carried over.
	private func admissionMidX(_ frame: CGRect, on monitor: MonitorKey) -> CGFloat {
		guard let target = monitors[monitor]?.visibleFrame, let source = monitorKey(for: frame), source != monitor,
			let sourceFrame = monitors[source]?.visibleFrame, sourceFrame.width > 0
		else { return frame.midX }
		return target.minX + (frame.midX - sourceFrame.minX) / sourceFrame.width * target.width
	}

	/// Whether a window is out of sight: its centre on no monitor, or only a sliver of it showing.
	private func admissionLooksHidden(_ frame: CGRect) -> Bool {
		guard frame.width > 0, frame.height > 0 else { return false }
		let screens = monitorOrder.compactMap { monitors[$0] }
		let centre = CGPoint(x: frame.midX, y: frame.midY)
		return !screens.contains { $0.frame.contains(centre) } || ParkGeometry.isEffectivelyHidden(frame, monitors: screens)
	}

	private mutating func admissionLogAdmit(_ record: WindowRecord, via: String) {
		let place: String
		if let workspace = record.workspace, let host = workspaces[workspace]?.host {
			place = "-> \(describeMonitor(host)) \(describeWorkspace(workspace)) \(record.placement == .tiled ? "tiled" : "floating")"
		} else {
			place = "unmanaged" + (record.observed.frame.flatMap { monitorKey(for: $0) }.map { " on \(describeMonitor($0))" } ?? "")
		}
		let state = record.visibility == .visible ? "" : "; \(record.visibility.logName)"
		log("track: admit \(describe(record)) \(place) (\(Self.admissionSourceName(record.source)) via \(via)\(state))")
	}

	private mutating func admissionLogRekey(from old: WindowID, to new: WindowID, sameApp: Bool) {
		log("track: rekey #\(old) -> #\(new) (\(sameApp ? "same app and title" : "same bundle and title"))")
	}

	private static func admissionSourceName(_ source: AdmissionSource) -> String {
		switch source {
		case .startup: return "startup"
		case .created: return "created"
		case .discovered: return "discovered"
		case .restored: return "restored"
		}
	}
}
