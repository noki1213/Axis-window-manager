//
//  AXEventSource.swift
//  Axis
//
//  Accessibility notifications from the observed apps, delivered to the main thread as
//  TrackingSignal values.
//
//  One dedicated thread with its own run loop hosts an AXObserver per app. Registering with an app
//  that does not answer blocks only that thread, for at most the messaging timeout per call, never
//  the main thread. App-level notifications (window created, focused window changed) are
//  registered on the app element. Window-level ones (destroyed, minimized, restored, moved,
//  resized) are registered per watched window with the window's ID as the callback's reference
//  value, so a destroyed element, which can no longer be asked anything, still names its window.
//  Callbacks make no Accessibility calls: they look up the thread's own bookkeeping and post to
//  the main thread.
//
//  Every registration carries a generation. A signal still in flight when the main thread drops
//  a registration is discarded on arrival, so an observer that was torn down never reports.
//

import AppKit
import ApplicationServices
import Foundation

/// Registration state of one app's observer, as last reported by the observer thread.
nonisolated enum AXObserverStatus: Equatable, Sendable {
	/// The first attempt has not finished yet.
	case pending
	/// The app-level notifications and the watched windows' notifications are in place, except
	/// the ones the app refuses outright.
	case registered
	/// An attempt failed with `error` (a raw AXError); the next one runs at `retryAt`
	/// (ProcessInfo.systemUptime).
	case retrying(retryAt: Time, failures: Int, error: Int32)
	/// The retries ran out. Registering the app again starts over.
	case gaveUp(failures: Int, error: Int32)
}

/// Owns the observer thread and the registrations. Used from the main thread only; the sink is
/// called on the main thread. Registrations need a running source: before `start` they do nothing.
final class AXEventSource {
	typealias Sink = (TrackingSignal) -> Void

	private struct Registration {
		let generation: UInt64
		var status: AXObserverStatus
	}

	private var thread: AXObserverThread?
	private var sink: Sink?
	private var registrations: [PID: Registration] = [:]
	private var lastGeneration: UInt64 = 0
	private let ownPID = ProcessInfo.processInfo.processIdentifier

	init() {}

	var isRunning: Bool { thread != nil }

	/// Starts the observer thread; signals go to `sink` until `stop()`. Calling it while running
	/// only replaces the sink.
	func start(sink: @escaping Sink) {
		self.sink = sink
		guard thread == nil else { return }
		let deliver: @Sendable (AXEventReport) -> Void = { [weak self] report in
			DispatchQueue.main.async { self?.receive(report) }
		}
		let thread = AXObserverThread(worker: AXObserverWorker(deliver: deliver))
		thread.name = "Axis accessibility observers"
		// Notifications feed refreshes that are scheduled within tens of milliseconds.
		thread.qualityOfService = .userInteractive
		thread.start()
		self.thread = thread
	}

	/// Drops every registration and ends the observer thread. Signals still in flight are dropped.
	func stop() {
		sink = nil
		registrations.removeAll()
		thread?.perform { $0.shutDown() }
		thread = nil
	}

	/// Observes window creation and focus changes of `pid`. Does nothing for Axis itself, the login
	/// window, a process that is gone, or an app that is already registered, except that an app
	/// whose retries ran out starts over.
	func register(pid: PID) {
		ensureRegistered(pid, restartingAfterGivingUp: true)
	}

	/// Stops observing `pid` and every window watched for it.
	func unregister(pid: PID) {
		guard registrations.removeValue(forKey: pid) != nil else { return }
		thread?.perform { $0.detach(pid) }
	}

	/// The state last reported for `pid`; nil when it is not registered.
	func observerStatus(of pid: PID) -> AXObserverStatus? {
		registrations[pid]?.status
	}

	/// Watches one window for destroyed, minimized, restored, moved and resized notifications,
	/// registering its app first when needed. Watching it again with an equal element only adds
	/// what is still missing; a different element replaces the old one. A window's watch ends with
	/// its `windowDestroyed` signal: if the window turns out to be alive (the app rebuilt its
	/// element), watch it again with the fresh element.
	func watchWindow(_ id: WindowID, pid: PID, element: AXUIElement) {
		guard id != 0, ensureRegistered(pid, restartingAfterGivingUp: false), let thread else { return }
		let handle = AXElementHandle(element: element)
		thread.perform { $0.watch(id, pid: pid, element: handle.element) }
	}

	/// Stops watching one window.
	func unwatchWindow(_ id: WindowID) {
		thread?.perform { $0.unwatch(id) }
	}

	/// Returns whether `pid` is registered (or now being registered).
	@discardableResult
	private func ensureRegistered(_ pid: PID, restartingAfterGivingUp restart: Bool) -> Bool {
		guard let thread, pid > 0, pid != ownPID else { return false }
		if let registration = registrations[pid] {
			if restart, case .gaveUp = registration.status {
				registrations[pid]?.status = .pending
				let generation = registration.generation
				thread.perform { $0.attach(pid, generation: generation) }
			}
			return true
		}
		// The lock screen's windows are never managed; its notifications would only add noise.
		guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
			app.bundleIdentifier != SystemSignals.loginWindowBundleID else { return false }
		lastGeneration &+= 1
		let generation = lastGeneration
		registrations[pid] = Registration(generation: generation, status: .pending)
		thread.perform { $0.attach(pid, generation: generation) }
		return true
	}

	private func receive(_ report: AXEventReport) {
		guard registrations[report.pid]?.generation == report.generation else { return }
		if let status = report.status {
			registrations[report.pid]?.status = status
		}
		if let signal = report.signal {
			sink?(signal)
		}
	}
}

// MARK: - Observer thread

/// What the observer thread tells the main thread: a signal, a status change, or both (a failed
/// attempt). The status is applied before the signal is delivered.
private nonisolated struct AXEventReport: Sendable {
	let pid: PID
	let generation: UInt64
	var status: AXObserverStatus? = nil
	var signal: TrackingSignal? = nil
}

/// A window element on its way to the observer thread. An AXUIElement is an immutable reference
/// to an element of another process, and the Accessibility API accepts it on any thread.
private nonisolated struct AXElementHandle: @unchecked Sendable {
	let element: AXUIElement
}

private nonisolated enum AXNotificationNames {
	static let app = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification]
	/// Destroyed comes first: a window's lifecycle depends on it most.
	static let window = [
		kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
		kAXWindowMovedNotification, kAXWindowResizedNotification,
	]
}

/// The thread that hosts every observer: a run loop that also runs the jobs other threads hand
/// it. Jobs handed over before the run loop exists wait in a queue.
private nonisolated final class AXObserverThread: Thread, @unchecked Sendable {
	/// Used only on this thread (the jobs and the callbacks run here).
	let worker: AXObserverWorker
	// `lock` guards the three properties below.
	private let lock = NSLock()
	private var runLoop: CFRunLoop?
	private var queued: [@Sendable () -> Void] = []
	private var hasFinished = false

	init(worker: AXObserverWorker) {
		self.worker = worker
		super.init()
	}

	/// Runs `job` on this thread. Safe to call from any thread; jobs run in the order handed over.
	func perform(_ job: @escaping @Sendable (AXObserverWorker) -> Void) {
		let worker = self.worker
		let block: @Sendable () -> Void = {
			autoreleasepool { job(worker) }
		}
		lock.withLock {
			guard !hasFinished else { return }
			if let runLoop {
				CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
				CFRunLoopWakeUp(runLoop)
			} else {
				queued.append(block)
			}
		}
	}

	override func main() {
		let runLoop: CFRunLoop = CFRunLoopGetCurrent()
		// A source that never fires keeps the run loop running while no app is observed.
		var context = CFRunLoopSourceContext()
		context.perform = { _ in }
		let keepAlive = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
		CFRunLoopAddSource(runLoop, keepAlive, .defaultMode)
		lock.withLock {
			self.runLoop = runLoop
			for block in queued {
				CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
			}
			queued.removeAll()
		}
		while !worker.isShutDown {
			CFRunLoopRun()
		}
		lock.withLock {
			hasFinished = true
			self.runLoop = nil
		}
		CFRunLoopRemoveSource(runLoop, keepAlive, .defaultMode)
	}
}

/// Called on the observer thread for every registered notification.
private nonisolated func axEventSourceCallback(
	_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
	_ info: CFDictionary, _ refcon: UnsafeMutableRawPointer?
) {
	guard let thread = Thread.current as? AXObserverThread else { return }
	autoreleasepool {
		thread.worker.handle(observer, notification: notification, refcon: refcon)
	}
}

/// One observed app, owned by the observer thread.
private nonisolated final class AXObservedApp {
	let pid: PID
	var generation: UInt64
	/// The app element, created on the observer thread with the short messaging timeout.
	let element: AXUIElement
	var observer: AXObserver?
	/// App-level notifications in place.
	var registered: Set<String> = []
	var windows: [WindowID: AXWindowWatch] = [:]
	/// Consecutive failed attempts; 0 once an attempt succeeds.
	var failures = 0
	var retryTimer: CFRunLoopTimer?
	var reportedStatus: AXObserverStatus?

	init(pid: PID, generation: UInt64, element: AXUIElement) {
		self.pid = pid
		self.generation = generation
		self.element = element
	}
}

private nonisolated struct AXWindowWatch {
	let element: AXUIElement
	/// Notifications in place.
	var registered: Set<String> = []
	/// Notifications the app refused for this window; never asked for again.
	var refused: Set<String> = []
}

/// Everything the observer thread owns. Confined to that thread: other threads reach it only
/// through `AXObserverThread.perform`, which is why it may be handed over as Sendable.
private nonisolated final class AXObserverWorker: @unchecked Sendable {
	/// The longest any call made here waits for an app.
	static let messagingTimeout: Float = 0.3
	/// Delays before the next attempt after consecutive failures. After the last one the worker
	/// gives up until the app is registered again.
	static let retryDelays: [TimeInterval] = [0.5, 1, 2, 4, 8, 16, 30]

	private let deliver: @Sendable (AXEventReport) -> Void
	private var apps: [PID: AXObservedApp] = [:]
	private var appsByObserver: [ObjectIdentifier: AXObservedApp] = [:]
	private var windowOwners: [WindowID: PID] = [:]
	private(set) var isShutDown = false

	init(deliver: @escaping @Sendable (AXEventReport) -> Void) {
		self.deliver = deliver
	}

	// MARK: Jobs from the main thread

	/// Starts observing `pid`, or restarts the attempts for an app already known here (keeping
	/// what is registered and the windows to watch).
	func attach(_ pid: PID, generation: UInt64) {
		guard !isShutDown else { return }
		let app: AXObservedApp
		if let existing = apps[pid] {
			app = existing
			app.generation = generation
		} else {
			let element = AXUIElementCreateApplication(pid)
			AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
			app = AXObservedApp(pid: pid, generation: generation, element: element)
			apps[pid] = app
		}
		cancelRetry(app)
		app.failures = 0
		app.reportedStatus = nil
		attempt(app)
	}

	/// Forgets `pid`. Nothing is removed one by one, because the app may be gone or hung:
	/// releasing the observer ends its callbacks.
	func detach(_ pid: PID) {
		guard let app = apps.removeValue(forKey: pid) else { return }
		cancelRetry(app)
		for id in app.windows.keys where windowOwners[id] == pid {
			windowOwners[id] = nil
		}
		if let observer = app.observer {
			appsByObserver[ObjectIdentifier(observer)] = nil
			CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
		}
	}

	func watch(_ id: WindowID, pid: PID, element: AXUIElement) {
		guard !isShutDown, let app = apps[pid] else { return }
		if let owner = windowOwners[id], owner != pid {
			unwatch(id)
		}
		if let existing = app.windows[id], !CFEqual(existing.element, element) {
			removeRegistrations(of: existing, in: app)
			app.windows[id] = nil
		}
		if app.windows[id] == nil {
			AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
			app.windows[id] = AXWindowWatch(element: element)
		}
		windowOwners[id] = pid
		// While a retry is pending the app is not answering; that retry installs the watch.
		guard app.retryTimer == nil, let observer = app.observer else { return }
		if let error = install(id, in: app, observer: observer) {
			fail(app, error)
		}
	}

	func unwatch(_ id: WindowID) {
		guard let pid = windowOwners.removeValue(forKey: id), let app = apps[pid],
			let watch = app.windows.removeValue(forKey: id) else { return }
		removeRegistrations(of: watch, in: app)
	}

	func shutDown() {
		guard !isShutDown else { return }
		for pid in Array(apps.keys) {
			detach(pid)
		}
		isShutDown = true
		CFRunLoopStop(CFRunLoopGetCurrent())
	}

	// MARK: Callbacks

	func handle(_ observer: AXObserver, notification: CFString, refcon: UnsafeMutableRawPointer?) {
		guard let app = appsByObserver[ObjectIdentifier(observer)] else { return }
		let pid = app.pid
		let name = notification as String
		let signal: TrackingSignal
		switch name {
		case kAXWindowCreatedNotification:
			signal = .windowCreated(pid: pid)
		case kAXFocusedWindowChangedNotification:
			signal = .focusedWindowChanged(pid: pid)
		default:
			// A window that is no longer watched (the unwatch overtook the notification) is not
			// reported.
			guard let id = Self.windowID(from: refcon), app.windows[id] != nil else { return }
			switch name {
			case kAXUIElementDestroyedNotification:
				// A destroyed element never notifies again, so its watch ends here.
				app.windows[id] = nil
				windowOwners[id] = nil
				signal = .windowDestroyed(id: id, pid: pid)
			case kAXWindowMiniaturizedNotification:
				signal = .windowMiniaturized(id: id, pid: pid)
			case kAXWindowDeminiaturizedNotification:
				signal = .windowDeminiaturized(id: id, pid: pid)
			case kAXWindowMovedNotification:
				signal = .windowMoved(id: id, pid: pid)
			case kAXWindowResizedNotification:
				signal = .windowResized(id: id, pid: pid)
			default:
				return
			}
		}
		deliver(AXEventReport(pid: pid, generation: app.generation, signal: signal))
	}

	// MARK: Registration

	/// Registers whatever `app` still lacks. A failure schedules the next attempt.
	private func attempt(_ app: AXObservedApp) {
		guard let observer = makeObserverIfNeeded(app) else { return }
		for name in AXNotificationNames.app where !app.registered.contains(name) {
			let error = AXObserverAddNotification(observer, app.element, name as CFString, nil)
			guard error == .success || error == .notificationAlreadyRegistered else {
				fail(app, error)
				return
			}
			app.registered.insert(name)
		}
		for id in Array(app.windows.keys) {
			if let error = install(id, in: app, observer: observer) {
				fail(app, error)
				return
			}
		}
		app.failures = 0
		publish(.registered, for: app)
	}

	private func makeObserverIfNeeded(_ app: AXObservedApp) -> AXObserver? {
		if let observer = app.observer {
			return observer
		}
		var created: AXObserver?
		let error = AXObserverCreateWithInfoCallback(app.pid, axEventSourceCallback, &created)
		guard error == .success, let observer = created else {
			fail(app, error == .success ? .failure : error)
			return nil
		}
		app.observer = observer
		appsByObserver[ObjectIdentifier(observer)] = app
		CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
		return observer
	}

	/// Registers the notifications window `id` still lacks. Returns the error when the app did not
	/// answer, which makes the whole app retry; any other refusal is final for that notification.
	private func install(_ id: WindowID, in app: AXObservedApp, observer: AXObserver) -> AXError? {
		guard var watch = app.windows[id], let refcon = Self.refcon(for: id) else { return nil }
		for name in AXNotificationNames.window where !watch.registered.contains(name) && !watch.refused.contains(name) {
			let error = AXObserverAddNotification(observer, watch.element, name as CFString, refcon)
			switch error {
			case .success, .notificationAlreadyRegistered:
				watch.registered.insert(name)
			case .invalidUIElement:
				// The window is already gone; the scans and the window-server checks retire it.
				app.windows[id] = nil
				windowOwners[id] = nil
				return nil
			case .cannotComplete, .failure, .apiDisabled:
				app.windows[id] = watch
				return error
			default:
				watch.refused.insert(name)
			}
		}
		app.windows[id] = watch
		return nil
	}

	/// Best effort, and skipped while the app is failing so a hung app cannot stall this thread.
	/// A registration left behind only produces notifications that `handle` drops.
	private func removeRegistrations(of watch: AXWindowWatch, in app: AXObservedApp) {
		guard let observer = app.observer, app.failures == 0 else { return }
		for name in AXNotificationNames.window where watch.registered.contains(name) {
			if AXObserverRemoveNotification(observer, watch.element, name as CFString) == .cannotComplete {
				return
			}
		}
	}

	private func fail(_ app: AXObservedApp, _ error: AXError) {
		app.failures += 1
		let status: AXObserverStatus
		if app.failures <= Self.retryDelays.count {
			let delay = Self.retryDelays[app.failures - 1]
			scheduleRetry(app, after: delay)
			status = .retrying(
				retryAt: ProcessInfo.processInfo.systemUptime + delay, failures: app.failures, error: error.rawValue)
		} else {
			status = .gaveUp(failures: app.failures, error: error.rawValue)
		}
		publish(status, for: app, signal: .observerFailed(pid: app.pid))
	}

	private func scheduleRetry(_ app: AXObservedApp, after delay: TimeInterval) {
		cancelRetry(app)
		let pid = app.pid
		let generation = app.generation
		let timer = CFRunLoopTimerCreateWithHandler(
			kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + delay, 0, 0, 0
		) { [weak self] _ in
			autoreleasepool {
				guard let self, let app = self.apps[pid], app.generation == generation else { return }
				app.retryTimer = nil
				self.attempt(app)
			}
		}
		app.retryTimer = timer
		CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .defaultMode)
	}

	private func cancelRetry(_ app: AXObservedApp) {
		guard let timer = app.retryTimer else { return }
		CFRunLoopTimerInvalidate(timer)
		app.retryTimer = nil
	}

	/// Reports a status change; a status equal to the last one is reported only with a signal.
	private func publish(_ status: AXObserverStatus, for app: AXObservedApp, signal: TrackingSignal? = nil) {
		guard signal != nil || status != app.reportedStatus else { return }
		app.reportedStatus = status
		deliver(AXEventReport(pid: app.pid, generation: app.generation, status: status, signal: signal))
	}

	/// The callback's reference value for a window is the window ID itself, not a pointer.
	private static func refcon(for id: WindowID) -> UnsafeMutableRawPointer? {
		UnsafeMutableRawPointer(bitPattern: UInt(id))
	}

	private static func windowID(from refcon: UnsafeMutableRawPointer?) -> WindowID? {
		guard let refcon else { return nil }
		return WindowID(exactly: UInt(bitPattern: refcon))
	}
}
