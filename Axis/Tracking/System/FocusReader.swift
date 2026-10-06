//
//  FocusReader.swift
//  Axis
//
//  Which app is frontmost and which of its windows has focus. The frontmost app is a cheap
//  property read on the main thread; the focused window needs an Accessibility call, which runs
//  off the main thread with a short timeout so a hung frontmost app cannot stall the UI.
//

import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

nonisolated enum FocusReader {
	/// The longest the focused-window call may block.
	static let callTimeout: Float = 0.3

	private static let queue = DispatchQueue(label: "com.noki.Axis.focus-reader", qos: .userInitiated, attributes: .concurrent)

	/// Reads the focus state; `completion` runs on the main thread.
	@MainActor
	static func read(completion: @escaping @MainActor (FocusFacts) -> Void) {
		let frontmost = NSWorkspace.shared.frontmostApplication
		let pid = frontmost?.processIdentifier
		let bundleID = frontmost?.bundleIdentifier
		queue.async {
			let facts = readFocusedWindow(frontmostPID: pid, bundleID: bundleID)
			DispatchQueue.main.async {
				MainActor.assumeIsolated { completion(facts) }
			}
		}
	}

	private static func readFocusedWindow(frontmostPID: PID?, bundleID: String?) -> FocusFacts {
		var facts = FocusFacts(frontmostPID: frontmostPID, frontmostBundleID: bundleID)
		guard let pid = frontmostPID else { return facts }

		let app = AXUIElementCreateApplication(pid)
		AXUIElementSetMessagingTimeout(app, callTimeout)
		var focusedRef: CFTypeRef?
		let error = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedRef)
		switch error {
		case .success:
			break
		case .noValue, .attributeUnsupported:
			// The app answered: it has no focused window.
			return facts
		default:
			facts.error = error.rawValue
			return facts
		}
		guard let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return facts }

		let element = unsafeDowncast(focusedRef, to: AXUIElement.self)
		// Before any call on it: a fresh element would wait the system default for a hung app.
		AXUIElementSetMessagingTimeout(element, ElementCache.messagingTimeout)
		let (windowID, idError) = ElementCache.windowNumber(of: element)
		guard idError == .success else {
			// A messaging error means the answer is unknown; anything else means the focused
			// element is not a window (the desktop, an application element).
			if idError == .cannotComplete || idError == .apiDisabled {
				facts.error = idError.rawValue
			}
			return facts
		}
		guard windowID != 0 else { return facts }

		facts.focused = windowID
		ElementCache.shared.store(window: windowID, pid: pid, element: element)
		return facts
	}
}
