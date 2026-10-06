//
//	WindowActuator.swift
//	Axis
//
//	Applies planned window operations to the system via the Accessibility API.
//	Executes operations in two phases: showing windows first, then hiding windows.
//	Suppresses window animations per application, handles retry logic with read-backs,
//	and guards against unresponsive applications.
//

import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

enum WindowActuator {
	private static let frameTolerance: CGFloat = 2.0
	private static let frameMaxAttempts = 3
	private static let relayoutWaitMicroseconds: useconds_t = 15_000
	private static let messagingTimeout: Float = 0.3

	// MARK: - Plan Execution

	/// Executes the actions of a plan on the main thread, running the show phase before the hide phase.
	@discardableResult
	static func execute(_ plan: Plan) -> [WriteResult] {
		var unresponsivePIDs: Set<PID> = []
		var results: [WriteResult] = []

		for group in plan.show {
			if unresponsivePIDs.contains(group.pid) {
				continue
			}
			executeGroup(group, unresponsivePIDs: &unresponsivePIDs, results: &results)
		}

		for group in plan.hide {
			if unresponsivePIDs.contains(group.pid) {
				continue
			}
			executeGroup(group, unresponsivePIDs: &unresponsivePIDs, results: &results)
		}

		return results
	}

	/// Overload supporting labeled plan argument.
	@discardableResult
	static func execute(plan: Plan) -> [WriteResult] {
		execute(plan)
	}

	// MARK: - Application Group Execution

	/// Executes all actions for a single application group while temporarily disabling animations.
	private static func executeGroup(
		_ group: PlanGroup,
		unresponsivePIDs: inout Set<PID>,
		results: inout [WriteResult]
	) {
		let pid = group.pid
		let appElement = ElementCache.shared.appElement(pid)
		let timeoutErr = AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
		if timeoutErr == .cannotComplete {
			markUnresponsive(pid: pid, group: group, unresponsivePIDs: &unresponsivePIDs, results: &results)
			return
		}

		var wasEnabled: CFTypeRef?
		let copyErr = AXUIElementCopyAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, &wasEnabled)
		if copyErr == .cannotComplete {
			markUnresponsive(pid: pid, group: group, unresponsivePIDs: &unresponsivePIDs, results: &results)
			return
		}

		let wasEnabledBool = (wasEnabled as? Bool) ?? false
		if wasEnabledBool {
			let setErr = AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
			if setErr == .cannotComplete {
				markUnresponsive(pid: pid, group: group, unresponsivePIDs: &unresponsivePIDs, results: &results)
				return
			}
		}

		defer {
			if wasEnabledBool && !unresponsivePIDs.contains(pid) {
				AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
			}
		}

		for action in group.actions {
			if unresponsivePIDs.contains(pid) {
				break
			}
			let result = executeAction(action, appElement: appElement)
			results.append(result)
			if result.error == AXErrorCode.cannotComplete {
				unresponsivePIDs.insert(pid)
				break
			}
		}
	}

	/// Marks an application unresponsive and records a failed result for its first action.
	private static func markUnresponsive(
		pid: PID,
		group: PlanGroup,
		unresponsivePIDs: inout Set<PID>,
		results: inout [WriteResult]
	) {
		unresponsivePIDs.insert(pid)
		if let first = group.actions.first {
			let target = targetRect(for: first.kind, observed: first.observed)
			results.append(WriteResult(
				window: first.window,
				pid: pid,
				kind: writeKind(for: first.kind),
				target: target,
				result: nil,
				error: AXErrorCode.cannotComplete
			))
		}
	}

	// MARK: - Action Execution

	/// Executes a single plan action.
	private static func executeAction(_ action: PlanAction, appElement: AXUIElement) -> WriteResult {
		guard let element = ElementCache.shared.windowElement(action.window) else {
			let target = targetRect(for: action.kind, observed: action.observed)
			return WriteResult(
				window: action.window,
				pid: action.pid,
				kind: writeKind(for: action.kind),
				target: target,
				result: nil,
				error: AXErrorCode.invalidUIElement
			)
		}

		let timeoutErr = AXUIElementSetMessagingTimeout(element, messagingTimeout)
		if timeoutErr == .cannotComplete {
			let target = targetRect(for: action.kind, observed: action.observed)
			return WriteResult(
				window: action.window,
				pid: action.pid,
				kind: writeKind(for: action.kind),
				target: target,
				result: nil,
				error: AXErrorCode.cannotComplete
			)
		}

		switch action.kind {
		case .setFrame(let newFrame):
			return setFrame(newFrame, on: element, action: action)
		case .park(let origin):
			return park(origin, on: element, action: action)
		case .minimize:
			return minimize(on: element, action: action)
		case .unminimize:
			return unminimize(on: element, action: action)
		}
	}

	// MARK: - Window Operations

	/// Sets a window's position and size with read-back verification and retries.
	static func setFrame(_ newFrame: CGRect, on element: AXUIElement, action: PlanAction) -> WriteResult {
		let (initialFrame, readInitialErr) = getFrame(from: element)
		if readInitialErr == .cannotComplete {
			return WriteResult(window: action.window, pid: action.pid, kind: .frame, target: newFrame, result: nil, error: AXErrorCode.cannotComplete)
		}

		logAction(action, target: newFrame, currentFrame: initialFrame)
		AccessibilityManager.shared.invalidateWindowCache()

		let currentFrame = initialFrame ?? action.observed ?? .zero
		let isGrowing = newFrame.width > currentFrame.width + frameTolerance
			|| newFrame.height > currentFrame.height + frameTolerance

		let minSize = getMinSize(from: element) ?? CGSize(width: 200, height: 200)
		var previousFrame: CGRect?
		var lastReadBack: CGRect?

		for attempt in 0..<frameMaxAttempts {
			let writeErr: AXError
			if isGrowing {
				let e1 = applyPosition(newFrame.origin, to: element)
				let e2 = setSize(newFrame.size, to: element)
				let e3 = applyPosition(newFrame.origin, to: element)
				writeErr = prioritizeError([e1, e2, e3])
			} else {
				let e1 = setSize(newFrame.size, to: element)
				let e2 = applyPosition(newFrame.origin, to: element)
				let e3 = setSize(newFrame.size, to: element)
				writeErr = prioritizeError([e1, e2, e3])
			}

			if writeErr == .cannotComplete {
				return WriteResult(window: action.window, pid: action.pid, kind: .frame, target: newFrame, result: lastReadBack, error: AXErrorCode.cannotComplete)
			}
			if writeErr == .invalidUIElement {
				return WriteResult(window: action.window, pid: action.pid, kind: .frame, target: newFrame, result: lastReadBack, error: AXErrorCode.invalidUIElement)
			}

			let (actual, readErr) = getFrame(from: element)
			if readErr == .cannotComplete {
				return WriteResult(window: action.window, pid: action.pid, kind: .frame, target: newFrame, result: lastReadBack, error: AXErrorCode.cannotComplete)
			}
			guard let actual else {
				let errCode = readErr != .success ? readErr.rawValue : (writeErr != .success ? writeErr.rawValue : nil)
				return WriteResult(window: action.window, pid: action.pid, kind: .frame, target: newFrame, result: lastReadBack, error: errCode)
			}
			lastReadBack = actual

			if isCloseEnough(actual, newFrame) {
				return WriteResult(window: action.window, pid: action.pid, kind: .frame, target: newFrame, result: actual, error: nil)
			}

			if newFrame.width < minSize.width - frameTolerance || newFrame.height < minSize.height - frameTolerance {
				return WriteResult(window: action.window, pid: action.pid, kind: .frame, target: newFrame, result: actual, error: nil)
			}

			if let previous = previousFrame, isCloseEnough(actual, previous) {
				return WriteResult(window: action.window, pid: action.pid, kind: .frame, target: newFrame, result: actual, error: nil)
			}
			previousFrame = actual

			if attempt < frameMaxAttempts - 1 {
				usleep(relayoutWaitMicroseconds)
			}
		}

		return WriteResult(window: action.window, pid: action.pid, kind: .frame, target: newFrame, result: lastReadBack, error: nil)
	}

	/// Parks a window at a given screen coordinate by updating its position.
	static func park(_ origin: CGPoint, on element: AXUIElement, action: PlanAction) -> WriteResult {
		let (currentSize, _) = getSize(from: element)
		let size = currentSize ?? action.observed?.size ?? .zero
		let target = CGRect(origin: origin, size: size)

		logAction(action, target: target, currentFrame: action.observed)
		AccessibilityManager.shared.invalidateWindowCache()

		let err = applyPosition(origin, to: element)
		if err == .cannotComplete {
			return WriteResult(window: action.window, pid: action.pid, kind: .park, target: target, result: nil, error: AXErrorCode.cannotComplete)
		}

		let (actualFrame, readErr) = getFrame(from: element)
		if readErr == .cannotComplete {
			return WriteResult(window: action.window, pid: action.pid, kind: .park, target: target, result: nil, error: AXErrorCode.cannotComplete)
		}

		let finalError: Int32? = (err != .success) ? err.rawValue : (readErr != .success ? readErr.rawValue : nil)
		return WriteResult(window: action.window, pid: action.pid, kind: .park, target: target, result: actualFrame, error: finalError)
	}

	/// Minimizes a window.
	static func minimize(on element: AXUIElement, action: PlanAction) -> WriteResult {
		AccessibilityManager.shared.invalidateWindowCache()
		let target = action.observed ?? .zero

		let err = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
		if err == .cannotComplete {
			return WriteResult(window: action.window, pid: action.pid, kind: .minimize, target: target, result: nil, error: AXErrorCode.cannotComplete)
		}

		let (actualFrame, readErr) = getFrame(from: element)
		if readErr == .cannotComplete {
			return WriteResult(window: action.window, pid: action.pid, kind: .minimize, target: target, result: nil, error: AXErrorCode.cannotComplete)
		}

		let finalError: Int32? = (err != .success) ? err.rawValue : (readErr != .success ? readErr.rawValue : nil)
		return WriteResult(window: action.window, pid: action.pid, kind: .minimize, target: target, result: actualFrame, error: finalError)
	}

	/// Unminimizes a window.
	static func unminimize(on element: AXUIElement, action: PlanAction) -> WriteResult {
		AccessibilityManager.shared.invalidateWindowCache()
		let target = action.observed ?? .zero

		let err = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
		if err == .cannotComplete {
			return WriteResult(window: action.window, pid: action.pid, kind: .unminimize, target: target, result: nil, error: AXErrorCode.cannotComplete)
		}

		let (actualFrame, readErr) = getFrame(from: element)
		if readErr == .cannotComplete {
			return WriteResult(window: action.window, pid: action.pid, kind: .unminimize, target: target, result: nil, error: AXErrorCode.cannotComplete)
		}

		let finalError: Int32? = (err != .success) ? err.rawValue : (readErr != .success ? readErr.rawValue : nil)
		return WriteResult(window: action.window, pid: action.pid, kind: .unminimize, target: target, result: actualFrame, error: finalError)
	}

	// MARK: - Quit and Rescue

	/// Restores windows and rescues any windows left off-screen before application termination.
	@discardableResult
	static func prepareForQuit(plan: Plan = Plan(), windows: [WindowInfo]? = nil) -> [WriteResult] {
		let results = execute(plan)
		rescueOffScreenWindows(windows: windows)
		return results
	}

	/// Rescues windows that ended up off-screen by moving them back into visible screen bounds.
	static func rescueOffScreenWindows(windows: [WindowInfo]? = nil) {
		let allWindows = windows ?? AccessibilityManager.shared.getAllWindows()
		guard let mainScreenHeight = NSScreen.screens.first?.frame.height else { return }

		for window in allWindows {
			guard !window.isMinimized && !window.isFullscreen else { continue }
			guard window.frame.width > 0 && window.frame.height > 0 else { continue }

			let centerX = window.frame.midX
			let centerY = mainScreenHeight - window.frame.midY
			let centerInNS = CGPoint(x: centerX, y: centerY)

			let isOnScreen = NSScreen.screens.contains { $0.frame.contains(centerInNS) }
			if !isOnScreen {
				guard let targetScreen = closestScreen(to: centerInNS) else { continue }
				let visibleFrame = targetScreen.visibleFrame

				let screenTopInAX = mainScreenHeight - (visibleFrame.minY + visibleFrame.height)
				let screenBottomInAX = mainScreenHeight - visibleFrame.minY

				var newX = window.frame.origin.x
				var newY = window.frame.origin.y

				if newX + window.frame.width <= visibleFrame.minX {
					newX = visibleFrame.minX
				} else if newX >= visibleFrame.maxX {
					newX = visibleFrame.maxX - window.frame.width
				}

				if newY + window.frame.height <= screenTopInAX {
					newY = screenTopInAX
				} else if newY >= screenBottomInAX {
					newY = screenBottomInAX - window.frame.height
				}

				window.setPosition(CGPoint(x: newX, y: newY))
			}
		}
	}

	/// Finds the screen whose center is closest to a given point in screen coordinates.
	private static func closestScreen(to point: CGPoint) -> NSScreen? {
		NSScreen.screens.min(by: { screen1, screen2 in
			let center1 = CGPoint(x: screen1.frame.midX, y: screen1.frame.midY)
			let center2 = CGPoint(x: screen2.frame.midX, y: screen2.frame.midY)
			let dist1 = hypot(point.x - center1.x, point.y - center1.y)
			let dist2 = hypot(point.x - center2.x, point.y - center2.y)
			return dist1 < dist2
		})
	}

	// MARK: - Logging

	/// Logs an action using PerfLog in the standard format.
	private static func logAction(_ action: PlanAction, target: CGRect, currentFrame: CGRect? = nil) {
		let label = action.label.isEmpty ? "#\(action.window)" : action.label
		let fromFrame = action.observed ?? currentFrame
		let fromStr = fromFrame.map { BorderManager.describe($0) } ?? "?"

		switch action.kind {
		case .setFrame:
			if case .unpark = action.reason {
				PerfLog.event("unpark: \(label) -> \(BorderManager.describe(target))")
			} else {
				PerfLog.event("frame: \(label) \(fromStr) -> \(BorderManager.describe(target))")
			}
		case .park(let origin):
			let originStr = String(format: "%.0f,%.0f", origin.x, origin.y)
			PerfLog.event("park: \(label) \(fromStr) -> \(originStr) (\(action.reason.logText))")
		case .minimize, .unminimize:
			break
		}
	}

	// MARK: - Low-level AX Helpers

	private static func applyPosition(_ position: CGPoint, to element: AXUIElement) -> AXError {
		guard position.x.isFinite && position.y.isFinite else { return .failure }
		var pos = position
		guard let value = AXValueCreate(.cgPoint, &pos) else { return .failure }
		return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
	}

	private static func setSize(_ size: CGSize, to element: AXUIElement) -> AXError {
		guard size.width.isFinite && size.height.isFinite else { return .failure }
		var sz = size
		guard let value = AXValueCreate(.cgSize, &sz) else { return .failure }
		return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
	}

	private static func getFrame(from element: AXUIElement) -> (frame: CGRect?, error: AXError) {
		let (pos, posErr) = getPosition(from: element)
		if posErr != .success {
			return (nil, posErr)
		}
		let (sz, sizeErr) = getSize(from: element)
		if sizeErr != .success {
			return (nil, sizeErr)
		}
		guard let pos, let sz else {
			return (nil, .noValue)
		}
		return (CGRect(origin: pos, size: sz), .success)
	}

	private static func getPosition(from element: AXUIElement) -> (point: CGPoint?, error: AXError) {
		var ref: CFTypeRef?
		let err = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &ref)
		guard err == .success, let value = ref else {
			return (nil, err)
		}
		guard CFGetTypeID(value) == AXValueGetTypeID() else {
			return (nil, .failure)
		}
		var pt = CGPoint.zero
		if AXValueGetValue(value as! AXValue, .cgPoint, &pt) {
			return (pt, .success)
		}
		return (nil, .failure)
	}

	private static func getSize(from element: AXUIElement) -> (size: CGSize?, error: AXError) {
		var ref: CFTypeRef?
		let err = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &ref)
		guard err == .success, let value = ref else {
			return (nil, err)
		}
		guard CFGetTypeID(value) == AXValueGetTypeID() else {
			return (nil, .failure)
		}
		var sz = CGSize.zero
		if AXValueGetValue(value as! AXValue, .cgSize, &sz) {
			return (sz, .success)
		}
		return (nil, .failure)
	}

	private static func getMinSize(from element: AXUIElement) -> CGSize? {
		var ref: CFTypeRef?
		let err = AXUIElementCopyAttributeValue(element, "AXMinimumSize" as CFString, &ref)
		guard err == .success, let value = ref else {
			return nil
		}
		guard CFGetTypeID(value) == AXValueGetTypeID() else {
			return nil
		}
		var sz = CGSize.zero
		if AXValueGetValue(value as! AXValue, .cgSize, &sz) {
			return sz
		}
		return nil
	}

	private static func isCloseEnough(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
		abs(lhs.origin.x - rhs.origin.x) <= frameTolerance
			&& abs(lhs.origin.y - rhs.origin.y) <= frameTolerance
			&& abs(lhs.width - rhs.width) <= frameTolerance
			&& abs(lhs.height - rhs.height) <= frameTolerance
	}

	private static func prioritizeError(_ errors: [AXError]) -> AXError {
		for err in errors {
			if err == .cannotComplete {
				return .cannotComplete
			}
			if err != .success {
				return err
			}
		}
		return .success
	}

	private static func writeKind(for kind: PlanAction.Kind) -> WriteKind {
		switch kind {
		case .setFrame: return .frame
		case .park: return .park
		case .minimize: return .minimize
		case .unminimize: return .unminimize
		}
	}

	private static func targetRect(for kind: PlanAction.Kind, observed: CGRect?) -> CGRect {
		switch kind {
		case .setFrame(let frame): return frame
		case .park(let origin): return CGRect(origin: origin, size: observed?.size ?? .zero)
		case .minimize, .unminimize: return observed ?? .zero
		}
	}
}
