//
//  ElementCache.swift
//  Axis
//
//  Accessibility element handles for tracked windows and their apps. Scans on the enumeration
//  queue fill it; the main thread (writes, raises) and the observer thread (notification
//  registration) read it. Elements cross threads only through this cache, under its lock;
//  everything else that moves between threads is plain facts.
//

import Foundation
import ApplicationServices
import CoreGraphics

/// The private call that maps a window element to its window-server id. Declared here, without
/// the main-actor isolation the app's default would give it, so the enumeration threads can call it.
@_silgen_name("_AXUIElementGetWindow")
nonisolated private func copyWindowNumber(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

nonisolated final class ElementCache: @unchecked Sendable {
	static let shared = ElementCache()

	/// Messaging timeout every cached element carries. Readers and writers use the same value, so
	/// none of them shortens the timeout of an element another thread is in the middle of using.
	static let messagingTimeout: Float = 0.3

	private struct Entry {
		let pid: PID
		let element: AXUIElement
	}

	private let lock = NSLock()
	private var windows: [WindowID: Entry] = [:]
	private var windowIDsByPID: [PID: Set<WindowID>] = [:]
	private var apps: [PID: AXUIElement] = [:]
	/// The newest scan token stored per pid; results of older scans are dropped.
	private var storedScan: [PID: UInt64] = [:]
	private var scanCounter: UInt64 = 0

	private init() {}

	// MARK: - Reading

	/// The window-server id of a window element. `.success` with a zero number means the element
	/// is not backed by a window; other errors say why the id could not be read.
	static func windowNumber(of element: AXUIElement) -> (number: CGWindowID, error: AXError) {
		var number: CGWindowID = 0
		let error = copyWindowNumber(element, &number)
		return (number, error)
	}

	/// The element of a window an earlier scan (or the focus reader) saw.
	func windowElement(_ id: WindowID) -> AXUIElement? {
		lock.withLock { windows[id]?.element }
	}

	/// The app a cached window belongs to.
	func pid(of id: WindowID) -> PID? {
		lock.withLock { windows[id]?.pid }
	}

	/// The application element of a process, created on first use.
	func appElement(_ pid: PID) -> AXUIElement {
		lock.withLock {
			if let element = apps[pid] {
				return element
			}
			let element = AXUIElementCreateApplication(pid)
			AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
			apps[pid] = element
			return element
		}
	}

	// MARK: - Writing

	/// Takes a place in line for a scan about to start. A scan that finishes after a later one
	/// has stored its elements is dropped, so a slow scan never overwrites newer handles.
	func beginScan() -> UInt64 {
		lock.withLock {
			scanCounter += 1
			return scanCounter
		}
	}

	/// Stores the elements one scan listed. A complete scan lists every window of the app, so
	/// the app's other entries are dropped; an incomplete one only adds and replaces.
	func store(scan token: UInt64, pid: PID, elements: [WindowID: AXUIElement], isComplete: Bool) {
		lock.withLock {
			if let stored = storedScan[pid], stored > token {
				return
			}
			storedScan[pid] = token
			var ids = isComplete ? Set<WindowID>() : (windowIDsByPID[pid] ?? [])
			if isComplete {
				for id in windowIDsByPID[pid] ?? [] where elements[id] == nil {
					windows[id] = nil
				}
			}
			for (id, element) in elements {
				windows[id] = Entry(pid: pid, element: element)
				ids.insert(id)
			}
			windowIDsByPID[pid] = ids.isEmpty ? nil : ids
		}
	}

	/// Remembers a window seen outside a scan (the focused window) unless a scan already listed it.
	func store(window id: WindowID, pid: PID, element: AXUIElement) {
		lock.withLock {
			guard windows[id] == nil else { return }
			windows[id] = Entry(pid: pid, element: element)
			windowIDsByPID[pid, default: []].insert(id)
		}
	}

	/// Forgets a window that left tracking.
	func remove(window id: WindowID) {
		lock.withLock {
			guard let entry = windows.removeValue(forKey: id) else { return }
			windowIDsByPID[entry.pid]?.remove(id)
			if windowIDsByPID[entry.pid]?.isEmpty == true {
				windowIDsByPID[entry.pid] = nil
			}
		}
	}

	/// Forgets an app that quit. Scans that started before this call can no longer store anything.
	func remove(pid: PID) {
		lock.withLock {
			for id in windowIDsByPID.removeValue(forKey: pid) ?? [] {
				windows[id] = nil
			}
			apps[pid] = nil
			storedScan[pid] = scanCounter
			pruneStoredScans()
		}
	}

	/// Drops stored scan tokens for processes that have quit once enough scans have passed.
	private func pruneStoredScans() {
		guard storedScan.count > 64 else { return }
		let activePIDs = Set(windowIDsByPID.keys).union(apps.keys)
		for (pid, token) in storedScan {
			if !activePIDs.contains(pid) && (scanCounter >= token + 32 || scanCounter < token) {
				storedScan.removeValue(forKey: pid)
			}
		}
	}

	/// Clears all cached elements and tokens when tracking stops.
	func clear() {
		lock.withLock {
			windows.removeAll()
			windowIDsByPID.removeAll()
			apps.removeAll()
			storedScan.removeAll()
			scanCounter = 0
		}
	}
}
