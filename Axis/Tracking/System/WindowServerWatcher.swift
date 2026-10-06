//
//  WindowServerWatcher.swift
//  Axis
//
//  The window server's view of the screen, used as a backstop for Accessibility notifications
//  that never arrive and to notice Mission Control. A cheap tick reads the on-screen window list
//  and compares it with what the tracker expects; `ServerProbe` answers one-off questions
//  ("do these windows still exist?") for the pass that follows.
//

import Foundation
import AppKit
import CoreGraphics

// MARK: - Window server queries

nonisolated enum ServerProbe {
	/// The windows on screen in the current Space (desktop elements left out).
	static func onScreen(now: Time) -> ServerSnapshot {
		let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
		guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) else {
			return ServerSnapshot(scope: .onScreen, takenAt: now)
		}
		return snapshot(from: list, scope: .onScreen, now: now)
	}

	/// Which of `ids` the window server still has, on or off screen (minimized windows and windows
	/// on other Spaces included). The result's windows hold only the ids that exist; an id of the
	/// request that is missing from it no longer exists.
	///
	/// The array handed to the window server has to hold the raw window numbers themselves, built
	/// with no retain callbacks: an array of NSNumber objects makes the call return nothing.
	static func exists(_ ids: Set<WindowID>, now: Time) -> ServerSnapshot {
		let empty = ServerSnapshot(scope: .ids(ids), takenAt: now)
		let valid = ids.filter { $0 != 0 }
		guard !valid.isEmpty else { return empty }
		var raw: [UnsafeRawPointer?] = valid.map { UnsafeRawPointer(bitPattern: UInt($0)) }
		let array = raw.withUnsafeMutableBufferPointer { buffer in
			CFArrayCreate(kCFAllocatorDefault, buffer.baseAddress, buffer.count, nil)
		}
		guard let array, let descriptions = CGWindowListCreateDescriptionFromArray(array) else { return empty }
		return snapshot(from: descriptions, scope: .ids(ids), now: now)
	}

	private static func snapshot(from list: CFArray, scope: ServerSnapshot.Scope, now: Time) -> ServerSnapshot {
		var windows: [WindowID: ServerWindow] = [:]
		for index in 0..<CFArrayGetCount(list) {
			guard let pointer = CFArrayGetValueAtIndex(list, index) else { continue }
			let dictionary = Unmanaged<CFDictionary>.fromOpaque(pointer).takeUnretainedValue()
			if let window = serverWindow(from: dictionary) {
				windows[window.id] = window
			}
		}
		return ServerSnapshot(windows: windows, scope: scope, takenAt: now)
	}

	private static func serverWindow(from dictionary: CFDictionary) -> ServerWindow? {
		guard let id = WindowListEntry.integer(dictionary, kCGWindowNumber),
		      let pid = WindowListEntry.integer(dictionary, kCGWindowOwnerPID) else { return nil }
		return ServerWindow(
			id: WindowID(truncatingIfNeeded: id),
			pid: PID(truncatingIfNeeded: pid),
			bounds: WindowListEntry.bounds(dictionary) ?? .zero,
			layer: WindowListEntry.integer(dictionary, kCGWindowLayer) ?? 0,
			alpha: WindowListEntry.double(dictionary, kCGWindowAlpha) ?? 1,
			isOnScreen: WindowListEntry.boolean(dictionary, kCGWindowIsOnscreen) ?? false)
	}
}

/// Field access on the dictionaries of a window list. Reading the Core Foundation values in place
/// costs a fraction of bridging every dictionary to Swift, which matters at 20 reads a second.
nonisolated private enum WindowListEntry {
	static func value(_ dictionary: CFDictionary, _ key: CFString) -> CFTypeRef? {
		guard let pointer = CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(key).toOpaque()) else { return nil }
		return Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
	}

	static func integer(_ dictionary: CFDictionary, _ key: CFString) -> Int? {
		guard let object = value(dictionary, key), CFGetTypeID(object) == CFNumberGetTypeID() else { return nil }
		var result: Int64 = 0
		guard CFNumberGetValue(unsafeDowncast(object, to: CFNumber.self), .sInt64Type, &result) else { return nil }
		return Int(result)
	}

	static func double(_ dictionary: CFDictionary, _ key: CFString) -> Double? {
		guard let object = value(dictionary, key), CFGetTypeID(object) == CFNumberGetTypeID() else { return nil }
		var result: Double = 0
		guard CFNumberGetValue(unsafeDowncast(object, to: CFNumber.self), .doubleType, &result) else { return nil }
		return result
	}

	static func boolean(_ dictionary: CFDictionary, _ key: CFString) -> Bool? {
		guard let object = value(dictionary, key), CFGetTypeID(object) == CFBooleanGetTypeID() else { return nil }
		return CFBooleanGetValue(unsafeDowncast(object, to: CFBoolean.self))
	}

	static func bounds(_ dictionary: CFDictionary) -> CGRect? {
		guard let object = value(dictionary, kCGWindowBounds), CFGetTypeID(object) == CFDictionaryGetTypeID() else { return nil }
		var rect = CGRect.zero
		guard CGRectMakeWithDictionaryRepresentation(unsafeDowncast(object, to: CFDictionary.self), &rect) else { return nil }
		return rect
	}

	static func isOwned(_ dictionary: CFDictionary, by ownerName: CFString) -> Bool {
		guard let object = value(dictionary, kCGWindowOwnerName), CFGetTypeID(object) == CFStringGetTypeID() else { return false }
		return CFEqual(object, ownerName)
	}
}

// MARK: - Watcher

/// Ticks every 50 ms on the main thread and posts what the on-screen window list says that the
/// tracker does not know yet: Mission Control, windows nobody tracks, tracked windows that are
/// missing, and windows that should be out of sight but are visible. While a barrier pauses
/// tracking it stays silent.
final class WindowServerWatcher {
	/// What the tracker knows and expects, as of the current tick.
	struct Context {
		/// A tracked window that should be on screen.
		struct Expectation {
			var pid: PID
			/// It should be out of sight: parked, or hidden by Zen or the palette.
			var isHidden: Bool

			init(pid: PID, isHidden: Bool) {
				self.pid = pid
				self.isHidden = isHidden
			}
		}

		/// Apps whose windows can be tracked (regular apps, Axis itself left out).
		var regularPIDs: Set<PID> = []
		/// Apps whose last scan was not complete; their retries belong to the scan backoff.
		var unreadablePIDs: Set<PID> = []
		/// Every tracked window.
		var tracked: Set<WindowID> = []
		/// Tracked windows that should be in the on-screen list. Windows the window server does
		/// not list although their app does (ghosts) stay out, or they would be reported forever.
		var onScreen: [WindowID: Expectation] = [:]
		var monitors: [MonitorState] = []
		/// Where the planner last wanted a window; a hidden window sitting there (a sliver the
		/// system nudged back on screen) counts as hidden.
		var expectedFrame: (WindowID) -> CGRect? = { _ in nil }
		/// A barrier (startup, lock, sleep, display change) pauses the watcher: it reads nothing and
		/// posts nothing until the context says otherwise.
		var isPaused = false

		init(isPaused: Bool = false) {
			self.isPaused = isPaused
		}
	}

	/// Called for every signal, on the main thread.
	var sink: (@MainActor (TrackingSignal) -> Void)?
	/// Called once per tick (20 times a second), so it should hand back a context that is cached
	/// between state changes. Without a provider only the Mission Control check can fire.
	var contextProvider: (@MainActor () -> Context)?

	private(set) var isMissionControlActive = false

	static let tickInterval: TimeInterval = 0.05
	/// Per app, how often scans may be requested for untracked or missing windows.
	private static let appSignalInterval: TimeInterval = 1.0
	/// Per window, how often a visible hidden window may be reported again.
	private static let hiddenSignalInterval: TimeInterval = 0.5
	/// A hidden window must fail the test on two consecutive ticks: right after a switch the old
	/// windows are still on screen until the delayed hide phase runs.
	private static let hiddenConfirmDelay: TimeInterval = 0.04
	/// Signals for a window no scan turns into a tracked one before it is set aside.
	private static let maxUntrackedSignals = 2
	/// How long a set-aside window stays ignored before it gets one more look.
	private static let setAsideRetryInterval: TimeInterval = 30
	private static let sweepInterval: TimeInterval = 5
	/// Tolerance when comparing a frame with the planner's expectation (points per edge).
	private static let frameTolerance: CGFloat = 2

	private static let dockOwnerName = "Dock" as CFString

	private var timer: DispatchSourceTimer?
	private var lastUntrackedSignal: [PID: Time] = [:]
	private var lastMissingSignal: [PID: Time] = [:]
	private var lastHiddenSignal: [WindowID: Time] = [:]
	private var hiddenFailingSince: [WindowID: Time] = [:]
	private var untrackedSignals: [WindowID: Int] = [:]
	private var announcedSetAside: Set<WindowID> = []
	/// Layer-0 windows of regular apps that scans never turned into tracked windows (helper and
	/// overlay windows the Accessibility API does not expose), by app, with the time they were set aside.
	private var setAside: [PID: [WindowID: Time]] = [:]
	private var lastSweep: Time = 0

	func start() {
		guard timer == nil else { return }
		let timer = DispatchSource.makeTimerSource(queue: .main)
		timer.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval, leeway: .milliseconds(10))
		timer.setEventHandler { [weak self] in
			self?.tick()
		}
		timer.resume()
		self.timer = timer
	}

	func stop() {
		timer?.cancel()
		timer = nil
	}

	// MARK: - Tick

	private func tick() {
		let context = contextProvider?() ?? Context()
		guard !context.isPaused,
		      let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) else { return }
		let now = ProcessInfo.processInfo.systemUptime

		var onScreenIDs = Set<WindowID>()
		var layerZero: [(id: WindowID, pid: PID)] = []
		var dockWindows: [[String: Any]] = []
		var hiddenBounds: [WindowID: CGRect] = [:]
		for index in 0..<CFArrayGetCount(list) {
			guard let pointer = CFArrayGetValueAtIndex(list, index) else { continue }
			let dictionary = Unmanaged<CFDictionary>.fromOpaque(pointer).takeUnretainedValue()
			if WindowListEntry.isOwned(dictionary, by: Self.dockOwnerName),
			   let bridged = (dictionary as NSDictionary) as? [String: Any] {
				dockWindows.append(bridged)
			}
			guard let number = WindowListEntry.integer(dictionary, kCGWindowNumber) else { continue }
			let id = WindowID(truncatingIfNeeded: number)
			onScreenIDs.insert(id)
			if WindowListEntry.integer(dictionary, kCGWindowLayer) == 0,
			   let pid = WindowListEntry.integer(dictionary, kCGWindowOwnerPID) {
				layerZero.append((id, PID(truncatingIfNeeded: pid)))
			}
			if context.onScreen[id]?.isHidden == true, let bounds = WindowListEntry.bounds(dictionary) {
				hiddenBounds[id] = bounds
			}
		}

		let missionControlActive = Self.missionControlShowing(in: dockWindows)
		if missionControlActive != isMissionControlActive {
			isMissionControlActive = missionControlActive
			sink?(.missionControl(active: missionControlActive))
			return
		}
		// Windows come and go behind Mission Control: nothing else is judged while it shows.
		guard !isMissionControlActive else { return }

		signalUntrackedWindows(layerZero, context: context, now: now)
		signalMissingWindows(onScreenIDs, context: context, now: now)
		signalVisibleHiddenWindows(hiddenBounds, context: context, now: now)
		sweep(layerZero: layerZero, now: now)
	}

	/// New layer-0 windows of regular apps that nothing tracks. Windows that scans never turn into
	/// tracked ones are set aside after a few signals, so a helper window of an app does not cost
	/// a scan every second.
	private func signalUntrackedWindows(_ layerZero: [(id: WindowID, pid: PID)], context: Context, now: Time) {
		var candidates: [PID: Set<WindowID>] = [:]
		for (id, pid) in layerZero {
			guard context.regularPIDs.contains(pid), !context.unreadablePIDs.contains(pid), !context.tracked.contains(id) else { continue }
			if let since = setAside[pid]?[id] {
				guard now - since >= Self.setAsideRetryInterval else { continue }
				// An app can take a while to expose a window: look once more.
				setAside[pid]?[id] = nil
				untrackedSignals[id] = Self.maxUntrackedSignals - 1
			}
			candidates[pid, default: []].insert(id)
		}
		for (pid, ids) in candidates {
			guard now - (lastUntrackedSignal[pid] ?? -.infinity) >= Self.appSignalInterval else { continue }
			var fresh = Set<WindowID>()
			for id in ids {
				let signals = untrackedSignals[id] ?? 0
				if signals >= Self.maxUntrackedSignals {
					setAside[pid, default: [:]][id] = now
					untrackedSignals[id] = nil
					if announcedSetAside.insert(id).inserted {
						let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
						PerfLog.event("track: ignore #\(id) of \(name) (on screen at layer 0, not tracked after \(Self.maxUntrackedSignals) scans)")
					}
				} else {
					untrackedSignals[id] = signals + 1
					fresh.insert(id)
				}
			}
			guard !fresh.isEmpty else { continue }
			lastUntrackedSignal[pid] = now
			sink?(.untrackedWindows(pid: pid, ids: fresh))
		}
	}

	/// Tracked windows that should be on screen but are not in the list.
	private func signalMissingWindows(_ onScreenIDs: Set<WindowID>, context: Context, now: Time) {
		var missing: [PID: Set<WindowID>] = [:]
		for (id, expectation) in context.onScreen where !onScreenIDs.contains(id) && !context.unreadablePIDs.contains(expectation.pid) {
			missing[expectation.pid, default: []].insert(id)
		}
		for (pid, ids) in missing where now - (lastMissingSignal[pid] ?? -.infinity) >= Self.appSignalInterval {
			lastMissingSignal[pid] = now
			sink?(.missingWindows(pid: pid, ids: ids))
		}
	}

	/// Windows meant to be out of sight that are on screen. A window counts as out of sight when
	/// it is effectively hidden, or sits where the planner last put it (macOS may nudge a parked
	/// window to keep a sliver on screen; that result is accepted, not fought).
	private func signalVisibleHiddenWindows(_ hiddenBounds: [WindowID: CGRect], context: Context, now: Time) {
		var failing = Set<WindowID>()
		for (id, bounds) in hiddenBounds where !isOutOfSight(id, bounds: bounds, context: context) {
			failing.insert(id)
		}
		hiddenFailingSince = hiddenFailingSince.filter { failing.contains($0.key) }
		var report = Set<WindowID>()
		for id in failing {
			let since = hiddenFailingSince[id] ?? now
			hiddenFailingSince[id] = since
			guard now - since >= Self.hiddenConfirmDelay,
			      now - (lastHiddenSignal[id] ?? -.infinity) >= Self.hiddenSignalInterval else { continue }
			lastHiddenSignal[id] = now
			report.insert(id)
		}
		if !report.isEmpty {
			sink?(.hiddenWindowsVisible(ids: report))
		}
	}

	private func isOutOfSight(_ id: WindowID, bounds: CGRect, context: Context) -> Bool {
		if ParkGeometry.isEffectivelyHidden(bounds, monitors: context.monitors) {
			return true
		}
		guard let expected = context.expectedFrame(id) else { return false }
		return abs(bounds.minX - expected.minX) <= Self.frameTolerance
			&& abs(bounds.minY - expected.minY) <= Self.frameTolerance
			&& abs(bounds.maxX - expected.maxX) <= Self.frameTolerance
			&& abs(bounds.maxY - expected.maxY) <= Self.frameTolerance
	}

	/// Drops bookkeeping for windows and apps that are gone.
	private func sweep(layerZero: [(id: WindowID, pid: PID)], now: Time) {
		guard now - lastSweep >= Self.sweepInterval else { return }
		lastSweep = now
		let present = Set(layerZero.map(\.id))
		untrackedSignals = untrackedSignals.filter { present.contains($0.key) }
		announcedSetAside = announcedSetAside.intersection(present)
		for pid in setAside.keys {
			setAside[pid] = setAside[pid]?.filter { present.contains($0.key) }
			if setAside[pid]?.isEmpty == true {
				setAside[pid] = nil
			}
		}
		let horizon = now - 10
		lastUntrackedSignal = lastUntrackedSignal.filter { $0.value > horizon }
		lastMissingSignal = lastMissingSignal.filter { $0.value > horizon }
		lastHiddenSignal = lastHiddenSignal.filter { $0.value > horizon }
	}

	// MARK: - Mission Control

	/// Whether Mission Control is showing, judged from the Dock's windows.
	nonisolated static func missionControlShowing(in windowList: [[String: Any]]) -> Bool {
		for window in windowList {
			guard let ownerName = window[kCGWindowOwnerName as String] as? String,
				  ownerName == "Dock" else { continue }

			// Mission Control shows up as a Dock window with a telling name
			if let windowName = window[kCGWindowName as String] as? String {
				if windowName.contains("Mission Control") ||
				   windowName.contains("Exposé") ||
				   windowName.contains("Expose") {
					return true
				}
			}

			// Without Mission Control the Dock's only window is at layer -2147483624 (the wallpaper
			// layer), so a Dock window at layer 18 or higher means Mission Control is showing
			if let layer = window[kCGWindowLayer as String] as? Int, layer >= 18 {
				return true
			}
		}
		return false
	}
}
