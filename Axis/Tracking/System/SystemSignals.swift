//
//  SystemSignals.swift
//  Axis
//
//  Workspace, session and input notifications the window tracking reacts to, delivered on the
//  main thread as TrackingSignal values, plus the system states it checks on demand (screen lock,
//  login window in front, left mouse button). Axis's own process and the login window are never
//  reported as apps: neither has windows to manage.
//

import AppKit
import CoreGraphics
import Foundation

/// Used from the main thread only; the sink is called on the main thread.
final class SystemSignals {
	typealias Sink = (TrackingSignal) -> Void

	/// The process that draws the lock screen and the login window.
	nonisolated static let loginWindowBundleID = "com.apple.loginwindow"

	private var sink: Sink?
	private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
	private var mouseMonitors: [Any] = []

	init() {}

	var isRunning: Bool { sink != nil }

	/// Starts observing; signals go to `sink` until `stop()`. Calling it while running only
	/// replaces the sink.
	func start(sink: @escaping Sink) {
		let wasRunning = isRunning
		self.sink = sink
		guard !wasRunning else { return }

		let workspace = NSWorkspace.shared.notificationCenter
		observeApp(workspace, NSWorkspace.didLaunchApplicationNotification) { .appLaunched(pid: $0) }
		observeApp(workspace, NSWorkspace.didTerminateApplicationNotification) { .appTerminated(pid: $0) }
		observeApp(workspace, NSWorkspace.didActivateApplicationNotification) { .appActivated(pid: $0) }
		observeApp(workspace, NSWorkspace.didHideApplicationNotification) { .appHidden(pid: $0) }
		observeApp(workspace, NSWorkspace.didUnhideApplicationNotification) { .appUnhidden(pid: $0) }
		observe(workspace, NSWorkspace.activeSpaceDidChangeNotification, .activeSpaceChanged)
		observe(workspace, NSWorkspace.willSleepNotification, .willSleep)
		observe(workspace, NSWorkspace.didWakeNotification, .didWake)
		observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification, .screenParametersChanged)

		let distributed = DistributedNotificationCenter.default()
		observe(distributed, Notification.Name("com.apple.screenIsLocked"), .screenLocked)
		observe(distributed, Notification.Name("com.apple.screenIsUnlocked"), .screenUnlocked)

		// The global monitor sees mouse-ups over other apps only; the local one adds Axis's own
		// windows, so a press that started over them is released too.
		if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
			self?.emit(.leftMouseUp)
		}) {
			mouseMonitors.append(monitor)
		}
		if let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] event in
			self?.emit(.leftMouseUp)
			return event
		}) {
			mouseMonitors.append(monitor)
		}
	}

	func stop() {
		for observer in observers {
			observer.center.removeObserver(observer.token)
		}
		observers.removeAll()
		for monitor in mouseMonitors {
			NSEvent.removeMonitor(monitor)
		}
		mouseMonitors.removeAll()
		sink = nil
	}

	// MARK: - States checked on demand

	/// Whether the session's screen is locked. The session dictionary carries the key only while
	/// it is locked. Safe on any thread.
	nonisolated static func isScreenLocked() -> Bool {
		guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
		return session["CGSSessionScreenIsLocked"] as? Bool ?? false
	}

	/// Whether the login window is the frontmost app: the lock screen right after wake can show
	/// before the lock notification arrives.
	static var isLoginWindowFrontmost: Bool {
		NSWorkspace.shared.frontmostApplication?.bundleIdentifier == loginWindowBundleID
	}

	static var isLeftMouseDown: Bool {
		NSEvent.pressedMouseButtons & 1 != 0
	}

	// MARK: - Private

	private func emit(_ signal: TrackingSignal) {
		sink?(signal)
	}

	private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ signal: TrackingSignal) {
		let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated {
				self?.emit(signal)
			}
		}
		observers.append((center, token))
	}

	/// Observes an NSWorkspace app notification; `makeSignal` receives the app's pid.
	private func observeApp(
		_ center: NotificationCenter, _ name: Notification.Name,
		_ makeSignal: @escaping @Sendable (PID) -> TrackingSignal
	) {
		let ownPID = ProcessInfo.processInfo.processIdentifier
		let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
			guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
				return
			}
			let pid = app.processIdentifier
			guard pid > 0, pid != ownPID, app.bundleIdentifier != Self.loginWindowBundleID else { return }
			let signal = makeSignal(pid)
			MainActor.assumeIsolated {
				self?.emit(signal)
			}
		}
		observers.append((center, token))
	}
}
