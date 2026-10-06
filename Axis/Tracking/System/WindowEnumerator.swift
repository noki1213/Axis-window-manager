//
//  WindowEnumerator.swift
//  Axis
//
//  Reads window facts through the Accessibility API without ever blocking the main thread: one
//  job per app on a concurrent queue, each with a time budget, gathered by an awaiter that gives
//  up on stragglers. A scan reports whether it saw every window of the app ("complete"), so the
//  core never mistakes an app that could not answer for an app whose windows closed.
//

import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

/// Facts of single windows read by id.
nonisolated struct WindowReadResult: Equatable, Sendable {
	/// Windows that answered.
	var facts: [WindowFacts] = []
	/// Windows that did not: raw AXError (cannotComplete when the app was too slow,
	/// invalidUIElement when the window is gone).
	var failed: [WindowID: Int32] = [:]
	/// Windows no scan has listed yet, so there is no element to read; the caller scans their app.
	var unknown: [WindowID] = []
}

nonisolated enum WindowEnumerator {
	/// Time one app gets to answer before its job gives up on the rest of its windows.
	static let appBudget: TimeInterval = 0.5
	/// How long the awaiter waits before it counts apps that have not answered as timed out.
	static let awaiterDeadline: TimeInterval = 0.6
	/// The longest a single Accessibility call may block.
	static let callTimeout: TimeInterval = 0.3

	/// With less budget left than this a call would only time out, so the job stops instead.
	private static let minimumCallBudget: TimeInterval = 0.02
	/// Scans slower than this are logged.
	private static let slowScan: TimeInterval = 0.05

	private static let queue = DispatchQueue(label: "com.noki.Axis.enumerator", qos: .userInitiated, attributes: .concurrent)

	// MARK: - Public API

	/// Scans the window lists of `pids` concurrently. `completion` runs on the main thread no later
	/// than `awaiterDeadline` after the call, with an entry for every pid; an app that has not
	/// answered by then is reported as `.timedOut` and its late answer is dropped.
	static func scan(pids: [PID], completion: @escaping @MainActor ([PID: ScanResult]) -> Void) {
		let unique = Set(pids)
		guard !unique.isEmpty else {
			DispatchQueue.main.async { MainActor.assumeIsolated { completion([:]) } }
			return
		}
		let batch = GatherBatch<ScanOutcome>(
			pids: unique,
			straggler: { _ in ScanOutcome(result: .timedOut, elapsed: awaiterDeadline) },
			completion: { outcomes in
				logSlowScans(outcomes)
				completion(outcomes.mapValues(\.result))
			})
		for pid in unique {
			queue.async {
				batch.deliver(pid, scanApp(pid: pid))
			}
		}
		batch.expire(after: awaiterDeadline)
	}

	/// Reads the current facts of windows an earlier scan listed. `completion` runs on the main
	/// thread no later than `awaiterDeadline` after the call.
	static func read(windows ids: [WindowID], completion: @escaping @MainActor (WindowReadResult) -> Void) {
		var grouped: [PID: [WindowID]] = [:]
		var unlisted: [WindowID] = []
		for id in Set(ids) {
			if let pid = ElementCache.shared.pid(of: id) {
				grouped[pid, default: []].append(id)
			} else {
				unlisted.append(id)
			}
		}
		let groups = grouped
		let unknown = unlisted
		guard !groups.isEmpty else {
			let result = WindowReadResult(unknown: unknown)
			DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
			return
		}
		let batch = GatherBatch<WindowReadResult>(
			pids: Set(groups.keys),
			straggler: { pid in
				var result = WindowReadResult()
				for id in groups[pid] ?? [] {
					result.failed[id] = AXError.cannotComplete.rawValue
				}
				return result
			},
			completion: { results in
				var merged = WindowReadResult(unknown: unknown)
				for result in results.values {
					merged.facts += result.facts
					merged.failed.merge(result.failed) { first, _ in first }
					merged.unknown += result.unknown
				}
				completion(merged)
			})
		for (pid, group) in groups {
			queue.async {
				batch.deliver(pid, readGroup(ids: group, pid: pid))
			}
		}
		batch.expire(after: awaiterDeadline)
	}

	// MARK: - Scan job

	/// One app's scan: the window list, then one multi-attribute read per window. The elements
	/// are fresh handles that no other thread has seen until they are stored in the cache.
	private static func scanApp(pid: PID) -> ScanOutcome {
		let start = uptime()
		let budgetEnd = start + appBudget
		let token = ElementCache.shared.beginScan()

		func nextTimeout() -> Float? {
			let remaining = budgetEnd - uptime()
			return remaining > minimumCallBudget ? Float(min(callTimeout, remaining)) : nil
		}
		func outcome(_ result: ScanResult) -> ScanOutcome {
			ScanOutcome(result: result, elapsed: uptime() - start)
		}

		guard let listTimeout = nextTimeout() else { return outcome(.timedOut) }
		let app = AXUIElementCreateApplication(pid)
		AXUIElementSetMessagingTimeout(app, listTimeout)
		var listRef: CFTypeRef?
		let listStart = uptime()
		let listError = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &listRef)
		guard listError == .success else {
			// A call that ran into its own timeout is a hung app; the same error that comes back
			// at once is the app refusing to answer.
			let ranIntoTimeout = listError == .cannotComplete && uptime() - listStart >= Double(listTimeout) * 0.8
			return outcome(ranIntoTimeout ? .timedOut : .failed(listError.rawValue))
		}
		guard let list = listRef as? [AXUIElement] else {
			return outcome(.failed(AXErrorCode.failure))
		}

		let attributes = Attribute.allCases.map(\.name) as CFArray
		var facts: [WindowFacts] = []
		var elements: [WindowID: AXUIElement] = [:]
		var isComplete = true
		for element in list {
			guard let timeout = nextTimeout() else {
				isComplete = false
				break
			}
			AXUIElementSetMessagingTimeout(element, timeout)
			switch readWindow(element, appElement: app, pid: pid, attributes: attributes) {
			case .window(let window):
				if elements[window.id] == nil {
					facts.append(window)
					elements[window.id] = element
				}
			case .skipped:
				break
			case .unreadable:
				isComplete = false
			}
		}
		// The handles are shared from here on: give them the timeout every user of the cache expects.
		for element in elements.values {
			AXUIElementSetMessagingTimeout(element, ElementCache.messagingTimeout)
		}
		ElementCache.shared.store(scan: token, pid: pid, elements: elements, isComplete: isComplete)
		return outcome(isComplete ? .complete(facts) : .incomplete(facts))
	}

	/// One app's share of a read by id.
	private static func readGroup(ids: [WindowID], pid: PID) -> WindowReadResult {
		let budgetEnd = uptime() + appBudget
		let attributes = Attribute.allCases.map(\.name) as CFArray
		var result = WindowReadResult()
		for id in ids {
			guard budgetEnd - uptime() > minimumCallBudget else {
				result.failed[id] = AXError.cannotComplete.rawValue
				continue
			}
			guard let element = ElementCache.shared.windowElement(id) else {
				result.unknown.append(id)
				continue
			}
			// The element is shared with the main thread: leave its timeout alone.
			switch readWindow(element, appElement: nil, pid: pid, attributes: attributes) {
			case .window(let facts):
				result.facts.append(facts)
			case .skipped:
				result.failed[id] = AXError.invalidUIElement.rawValue
			case .unreadable:
				result.failed[id] = AXError.cannotComplete.rawValue
			}
		}
		return result
	}

	// MARK: - Window attributes

	private enum Attribute: Int, CaseIterable {
		case role, subrole, title, position, size, minimized, fullScreen, minimumSize, closeButton

		var name: String {
			switch self {
			case .role: return kAXRoleAttribute
			case .subrole: return kAXSubroleAttribute
			case .title: return kAXTitleAttribute
			case .position: return kAXPositionAttribute
			case .size: return kAXSizeAttribute
			case .minimized: return kAXMinimizedAttribute
			case .fullScreen: return "AXFullScreen"
			case .minimumSize: return "AXMinimumSize"
			case .closeButton: return kAXCloseButtonAttribute
			}
		}
	}

	private enum WindowRead {
		case window(WindowFacts)
		/// Not a window (the desktop the file manager lists) or already gone.
		case skipped
		/// The app did not answer, so nothing can be said about this window.
		case unreadable
	}

	/// Messaging errors mean the app could not be asked, as opposed to answering "no such attribute".
	private static func isMessagingError(_ error: AXError) -> Bool {
		error == .cannotComplete || error == .apiDisabled
	}

	/// The window id, then every attribute the core needs in one multi-attribute call. Optional
	/// attributes an app does not have take their defaults; a messaging error on any of them
	/// leaves the window unread rather than half known.
	private static func readWindow(_ element: AXUIElement, appElement: AXUIElement?, pid: PID, attributes: CFArray) -> WindowRead {
		let (windowID, idError) = ElementCache.windowNumber(of: element)
		guard idError == .success else {
			if isMessagingError(idError) {
				return .unreadable
			}
			// While the screen is locked every app lists its own application element in place of
			// its windows; that answer says nothing about the real windows.
			if let appElement, CFEqual(element, appElement) {
				return .unreadable
			}
			switch idError {
			case .illegalArgument, .invalidUIElement, .attributeUnsupported, .noValue, .notImplemented:
				return .skipped
			default:
				return .unreadable
			}
		}
		guard windowID != 0 else { return .skipped }

		// Taken before the call: a write that lands while it runs must make the facts look stale.
		let takenAt = uptime()
		var valuesRef: CFArray?
		let error = AXUIElementCopyMultipleAttributeValues(element, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &valuesRef)
		guard error == .success, let values = valuesRef else {
			return error == .invalidUIElement ? .skipped : .unreadable
		}
		guard CFArrayGetCount(values) == Attribute.allCases.count else { return .unreadable }

		var facts = WindowFacts(id: windowID, pid: pid, role: nil, subrole: nil, hasCloseButton: false, takenAt: takenAt)
		var position: CGPoint?
		var size: CGSize?
		for attribute in Attribute.allCases {
			guard let pointer = CFArrayGetValueAtIndex(values, attribute.rawValue) else { continue }
			let value = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
			if let attributeError = axError(value) {
				if isMessagingError(attributeError) {
					return .unreadable
				}
				continue
			}
			switch attribute {
			case .role: facts.role = value as? String
			case .subrole: facts.subrole = value as? String
			case .title: facts.title = value as? String ?? ""
			case .position: position = axPoint(value)
			case .size: size = axSize(value)
			case .minimized: facts.isMinimized = (value as? NSNumber)?.boolValue ?? false
			case .fullScreen: facts.isFullscreen = (value as? NSNumber)?.boolValue ?? false
			case .minimumSize: facts.minSize = axSize(value)
			case .closeButton: facts.hasCloseButton = CFGetTypeID(value) == AXUIElementGetTypeID()
			}
		}
		if let position, let size {
			facts.frame = CGRect(origin: position, size: size)
		}
		return .window(facts)
	}

	/// An attribute that failed comes back as an AXValue holding the error.
	private static func axError(_ value: AnyObject) -> AXError? {
		guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
		let axValue = unsafeDowncast(value, to: AXValue.self)
		var error = AXError.success
		guard AXValueGetType(axValue) == .axError, AXValueGetValue(axValue, .axError, &error) else { return nil }
		return error
	}

	private static func axPoint(_ value: AnyObject) -> CGPoint? {
		guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
		let axValue = unsafeDowncast(value, to: AXValue.self)
		var point = CGPoint.zero
		guard AXValueGetType(axValue) == .cgPoint, AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
		return point
	}

	private static func axSize(_ value: AnyObject) -> CGSize? {
		guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
		let axValue = unsafeDowncast(value, to: AXValue.self)
		var size = CGSize.zero
		guard AXValueGetType(axValue) == .cgSize, AXValueGetValue(axValue, .cgSize, &size) else { return nil }
		return size
	}

	private static func uptime() -> Time {
		ProcessInfo.processInfo.systemUptime
	}

	// MARK: - Diagnostics

	@MainActor
	private static func logSlowScans(_ outcomes: [PID: ScanOutcome]) {
		for (pid, outcome) in outcomes where outcome.elapsed >= slowScan && outcome.result != .timedOut {
			let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
			PerfLog.logf("AX.scan(%@): %.1fms", name, outcome.elapsed * 1000)
		}
	}
}

/// One app's scan and how long it took.
nonisolated private struct ScanOutcome: Sendable {
	var result: ScanResult
	var elapsed: TimeInterval
}

/// Collects the per-app answers of one gather and hands them to the main thread once: when the
/// last app has answered, or when the deadline passes and the stragglers count as timed out.
/// Whichever comes first wins; an answer that arrives afterwards is dropped.
nonisolated private final class GatherBatch<Output: Sendable>: @unchecked Sendable {
	private let lock = NSLock()
	private var outputs: [PID: Output] = [:]
	private var pending: Set<PID>
	private var finished = false
	private let straggler: @Sendable (PID) -> Output
	private let completion: @MainActor @Sendable ([PID: Output]) -> Void

	init(pids: Set<PID>, straggler: @escaping @Sendable (PID) -> Output, completion: @escaping @MainActor @Sendable ([PID: Output]) -> Void) {
		self.pending = pids
		self.straggler = straggler
		self.completion = completion
	}

	/// Called from a worker thread when one app is done.
	func deliver(_ pid: PID, _ output: Output) {
		let done: [PID: Output]? = lock.withLock {
			guard !finished, pending.remove(pid) != nil else { return nil }
			outputs[pid] = output
			guard pending.isEmpty else { return nil }
			finished = true
			return outputs
		}
		guard let done else { return }
		DispatchQueue.main.async {
			MainActor.assumeIsolated { self.completion(done) }
		}
	}

	/// Schedules the deadline on the main thread.
	func expire(after delay: TimeInterval) {
		DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
			let done: [PID: Output]? = self.lock.withLock {
				guard !self.finished else { return nil }
				self.finished = true
				for pid in self.pending {
					self.outputs[pid] = self.straggler(pid)
				}
				self.pending.removeAll()
				return self.outputs
			}
			guard let done else { return }
			MainActor.assumeIsolated { self.completion(done) }
		}
	}
}
