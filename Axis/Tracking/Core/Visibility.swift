//
//  Visibility.swift
//  Axis
//
//  Where each tracked window is meant to be (visible, parked, minimized, ...), resolved from
//  sessions, flags and observations, plus the sessions that change it: Zen, the window palette
//  and the hide stack. `normalize(now:)` is the only writer of `WindowRecord.visibility`.
//

import Foundation
import CoreGraphics

/// Visibility and session bookkeeping. Fields added here need default values.
nonisolated struct VisibilityState: Equatable, Sendable {
	init() {}
}

nonisolated extension TrackingState {
	/// The state a record should be in now, highest precedence first.
	func resolveVisibility(_ record: WindowRecord) -> Visibility {
		let observed = record.observed
		let inHiddenStack = hiddenStack.contains { $0.window == record.id }
		if observed.isFullscreen { return .nativeFullscreen }
		if observed.isMinimized { return inHiddenStack ? .axisMinimized : .nativeMinimized }
		if inHiddenStack { return .axisMinimized }
		if apps[record.pid]?.isHidden == true { return .appHidden }
		if !observed.listedInLastCompleteScan && observed.serverHas && !observed.onScreen { return .otherSpace }
		if let workspace = record.workspace, !isActive(workspace) { return .parked(.workspaceInactive) }
		if palette != nil { return .paletteHidden }
		if let zen, zen.workspace == record.workspace, record.id != zen.focus { return .zenHidden }
		return .visible
	}

	/// Recomputes every record's visibility. A tiled window leaving the states that keep a slot
	/// leaves the columns (remembering its neighbours); one returning goes back next to them, else
	/// by its centre.
	mutating func normalize(now: Time) {
		// A hidden-stack window restored from the Dock is seen unminimized after its minimize was confirmed.
		var dockRestores: [WindowID] = []
		for i in hiddenStack.indices {
			let id = hiddenStack[i].window
			if records[id]?.observed.isMinimized == true {
				hiddenStack[i].minimizeConfirmed = true
			} else if hiddenStack[i].minimizeConfirmed {
				dockRestores.append(id)
			}
		}
		for id in dockRestores {
			restoreHidden(id, userInitiated: true)
		}

		for id in records.keys.sorted() {
			guard let record = records[id] else { continue }
			let resolved = resolveVisibility(record)
			guard resolved != record.visibility else { continue }
			records[id]?.visibility = resolved
			log("visibility: \(describe(record)) \(record.visibility.logName) -> \(resolved.logName)")

			// Floating or unmanaged windows returning to visible restore their floating frame.
			if record.placement != .tiled && resolved == .visible {
				records[id]?.pendingFloatRestore = true
			}

			// Column transitions apply only to tiled windows with a workspace.
			guard record.placement == .tiled, let workspace = record.workspace,
				record.visibility.keepsSlot != resolved.keepsSlot else { continue }

			if record.visibility.keepsSlot {
				let memory = removeFromColumns(id)
				records[id]?.slotMemory = memory
			} else {
				var reinserted = false
				if let memory = record.slotMemory, memory.workspace == workspace {
					reinserted = insertBySlotMemory(id, memory: memory, into: workspace)
				}
				if !reinserted {
					insertByMidX(id, midX: record.observed.frame?.midX ?? .greatestFiniteMagnitude, into: workspace)
				}
				records[id]?.slotMemory = nil
			}
		}
	}

	/// Called after a window is admitted: a tiled window joining the Zen workspace ends Zen.
	mutating func zenNoteAdmission(_ record: WindowRecord) {
		guard let zen, record.placement == .tiled, record.workspace == zen.workspace else { return }
		zenExit(reason: .tiledAdmitted)
	}

	/// Called by `retire`: losing the Zen focus or a window Zen parked ends Zen.
	mutating func zenNoteRetire(_ record: WindowRecord) {
		guard let zen else { return }
		if record.id == zen.focus {
			zenExit(reason: .focusClosed)
		} else if record.visibility == .zenHidden {
			zenExit(reason: .hiddenClosed)
		}
	}

	/// Starts Zen on a visible window. Returns false when it cannot start.
	@discardableResult
	mutating func zenEnter(_ id: WindowID, now: Time) -> Bool {
		guard zen == nil, let record = records[id], record.visibility == .visible else { return false }
		let monitor = record.workspace.flatMap { workspaces[$0]?.host }
			?? record.observed.frame.flatMap { monitorKey(for: $0) }
			?? record.floatingFrame?.monitor
			?? primaryMonitor
		guard let monitor, let active = monitors[monitor]?.active else { return false }
		zen = ZenSession(monitor: monitor, workspace: active, focus: id)
		log("zen: enter \(describe(record)) on \(describeMonitor(monitor))")
		return true
	}

	/// Ends Zen. The other windows come back with the layout; a floating or unmanaged centred
	/// window goes back to where it floated before.
	mutating func zenExit(reason: ZenExitReason) {
		guard let session = zen else { return }
		zen = nil
		if let record = records[session.focus], record.placement != .tiled {
			records[session.focus]?.pendingFloatRestore = true
		}
		log("zen: exit (\(reason.logText))")
		emit(.zenEnded(reason))
	}

	mutating func zenAdjustWidth(increase: Bool) {
		guard var session = zen else { return }
		let step: CGFloat = 0.05
		session.widthRatio = max(0.1, min(1.0, session.widthRatio + (increase ? step : -step)))
		zen = session
	}

	mutating func paletteBegin(now: Time) {
		zenExit(reason: .paletteOpened)
		palette = PaletteSession(startedAt: now)
	}

	mutating func paletteEnd() {
		palette = nil
	}

	/// Pushes a managed window onto the hide stack (it is minimized by the next plan).
	mutating func hide(_ id: WindowID) {
		guard records[id]?.workspace != nil, !hiddenStack.contains(where: { $0.window == id }) else { return }
		hiddenStack.append(HiddenEntry(window: id))
	}

	/// Restores the most recently hidden window. Returns it.
	@discardableResult
	mutating func unhideLast() -> WindowID? {
		guard let last = hiddenStack.last?.window else { return nil }
		restoreHidden(last, userInitiated: false)
		return last
	}

	/// Takes a window off the hide stack; it returns to its own workspace next to its neighbours.
	/// `userInitiated` = the user already restored it (from the Dock).
	mutating func restoreHidden(_ id: WindowID, userInitiated: Bool) {
		hiddenStack.removeAll { $0.window == id }
		if !userInitiated {
			records[id]?.observed.isMinimized = false
		}
	}
}
