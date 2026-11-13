//
//  OwnWindows.swift
//  Axis
//
//  Axis's own windows that are laid out, focused and listed like any app's: the titled windows it
//  opens for the user. Popups, the menu bar panel, overlays and HUDs never register, so the window
//  list of Axis's own process shows the tracking nothing else. No accessibility observer is
//  attached to Axis's own process; the registered windows report their changes from AppKit
//  notifications instead, as the signals an observer would send.
//

import AppKit

/// Used from the main thread only; the sink is called on the main thread.
final class OwnWindows {
	typealias Sink = (TrackingSignal) -> Void

	static let shared = OwnWindows()
	nonisolated static let pid = ProcessInfo.processInfo.processIdentifier

	/// The window numbers of the registered windows.
	private(set) var ids: Set<WindowID> = []
	private var observers: [WindowID: [any NSObjectProtocol]] = [:]
	private var sink: Sink?

	private init() {}

	/// Signals go to `sink` until `stop()`.
	func start(sink: @escaping Sink) {
		self.sink = sink
	}

	func stop() {
		sink = nil
	}

	/// Lays out `window` from now on. Call it once the window is on screen, when it has its number.
	func add(_ window: NSWindow) {
		guard window.windowNumber > 0 else { return }
		let id = WindowID(window.windowNumber)
		guard ids.insert(id).inserted else { return }
		let pid = Self.pid
		let signals: [(Notification.Name, TrackingSignal)] = [
			(NSWindow.didMoveNotification, .windowMoved(id: id, pid: pid)),
			(NSWindow.didResizeNotification, .windowResized(id: id, pid: pid)),
			(NSWindow.didMiniaturizeNotification, .windowMiniaturized(id: id, pid: pid)),
			(NSWindow.didDeminiaturizeNotification, .windowDeminiaturized(id: id, pid: pid)),
			(NSWindow.didBecomeKeyNotification, .focusedWindowChanged(pid: pid)),
		]
		observers[id] = signals.map { name, signal in
			NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated {
					self?.sink?(signal)
				}
			}
		}
		sink?(.windowCreated(pid: pid))
		sink?(.focusedWindowChanged(pid: pid))
	}

	/// Takes `window` out of the layout as it closes. The window server has to let go of the window
	/// for the tracking to retire it at once, so the owner releases the window as well.
	func remove(_ window: NSWindow) {
		let id = WindowID(window.windowNumber)
		guard ids.remove(id) != nil else { return }
		for token in observers.removeValue(forKey: id) ?? [] {
			NotificationCenter.default.removeObserver(token)
		}
		// After the owner's release, which it queues before this
		DispatchQueue.main.async { [weak self] in
			self?.sink?(.windowDestroyed(id: id, pid: Self.pid))
		}
	}
}
