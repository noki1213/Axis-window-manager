//
//  FocusFollowsMouseManager.swift
//  Axis
//
//  Automatically focuses and raises the window under the mouse (focus follows mouse).
//  Built into Axis as a replacement for a separate AutoRaise-style tool.
//  The advantage is that it can auto-pause based on Axis's own state (mid Space-switch, mid selection mode, etc.).
//

import AppKit
import Combine

class FocusFollowsMouseManager: ObservableObject {
	static let shared = FocusFollowsMouseManager()

	// MARK: - Settings (persisted to UserDefaults)

	private static let enabledKey = "focusFollowsMouseEnabled"
	private static let delayKey = "focusFollowsMouseDelayMs"

	/// Whether the feature is on or off
	@Published var isEnabled: Bool {
		didSet {
			UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
		}
	}

	/// The delay from the mouse landing on it to focusing (milliseconds)
	@Published var delayMs: Double {
		didSet {
			UserDefaults.standard.set(delayMs, forKey: Self.delayKey)
		}
	}

	// MARK: - Internal state

	private var globalMonitor: Any?
	/// The delayed focus task (recreated every time the mouse moves)
	private var pendingWork: DispatchWorkItem?

	private init() {
		// Default: enabled, 50ms (same as the AutoRaise setting)
		if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
			UserDefaults.standard.set(true, forKey: Self.enabledKey)
		}
		if UserDefaults.standard.object(forKey: Self.delayKey) == nil {
			UserDefaults.standard.set(50.0, forKey: Self.delayKey)
		}
		self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
		self.delayMs = UserDefaults.standard.double(forKey: Self.delayKey)
	}

	// MARK: - Starting monitoring

	/// Start monitoring mouse movement (called once from AppDelegate)
	func start() {
		guard globalMonitor == nil else { return }
		// Global monitor: receives mouse movement over other apps
		// (.mouseMoved only fires for movement without a button held; it doesn't fire during a drag)
		globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
			self?.onMouseMoved()
		}
	}

	// MARK: - Main body

	private func onMouseMoved() {
		guard isEnabled else { return }

		// Every time the mouse moves, cancel the previous delayed focus and schedule a new one
		// (Only fires once the cursor has been still for delayMs = same debounce behavior as AutoRaise)
		pendingWork?.cancel()
		let work = DispatchWorkItem { [weak self] in
			self?.focusWindowUnderMouse()
		}
		pendingWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + delayMs / 1000.0, execute: work)
	}

	private func focusWindowUnderMouse() {
		// --- Guard based on Axis's own state (prevents mis-focus specific to the built-in display) ---

		// Do nothing while a space switch is in progress (the switch logic focuses the correct window)
		guard !WorkspaceManager.shared.isSwitching else { return }

		// Do nothing while in window-selection mode or gap-selection mode
		guard !WindowSelectManager.shared.isActive else { return }
		guard !GapSelectManager.shared.isActive else { return }

		// Do nothing while Mission Control is showing
		guard !BorderManager.shared.isInMissionControl else { return }

		// --- Identify the window directly under the mouse ---

		let mouseLocation = NSEvent.mouseLocation
		guard let window = topmostWindowAt(mouseLocation) else { return }

		// Excludes Axis's own windows (border overlay, palette, settings screen)
		guard window.app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }

		// Windows currently stashed in a hidden corner by the workspace or palette are excluded
		// (Prevents focus from jumping when the mouse touches the 1px sliver of a hidden window)
		guard !WorkspaceManager.shared.isWindowHidden(window.id) else { return }
		guard !WindowPaletteManager.shared.isWindowHidden(window.id) else { return }

		// Do nothing if the window is already focused
		if let focused = AccessibilityManager.shared.getFocusedWindow(), focused.id == window.id {
			return
		}

		// --- Focus + bring to front ---

		// focus() bundles together activating the app, setting AXFocused, and raising the window
		window.focus()

		// If what got focused is a tiled window (not floating),
		// Because raise buries the floating window behind the tiles,
		// Re-raise that screen's floating windows to the front (without stealing focus).
		// Without this, a floating window gets buried just from the mouse passing over a tile, and
		// After this, hovering can no longer reach the floating window
		let isFloatingTarget = WorkspaceManager.shared.isHovering(window.id) || window.shouldFloat()
		if !isFloatingTarget,
		   let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
			TilingEngine.shared.raiseFloatingWindows(on: screen)
		}

		// Update the border only after focus has actually taken effect (same mechanism as JKLI movement)
		BorderManager.shared.updateBorderExpecting(windowID: window.id)
	}

	/// Return the frontmost window at the given coordinates (screen coordinates, bottom-left origin)
	/// Since AccessibilityManager.getWindowAt returns the first hit in app order,
	/// The correct frontmost window can't be picked when a floating window overlaps a tile.
	/// Here, after identifying the window ID via CGWindowList (Z-order: front to back),
	/// Mapping it to WindowInfo ensures it always picks the visible window directly under the mouse.
	private func topmostWindowAt(_ point: CGPoint) -> WindowInfo? {
		// CGWindowList uses a top-left origin, so convert it
		let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
		let cgPoint = CGPoint(x: point.x, y: mainScreenHeight - point.y)

		let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

		// Hit-test normal-layer (layer == 0) windows front to back
		var hitWindowID: CGWindowID? = nil
		for entry in windowList {
			guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
				  let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat],
				  let windowID = entry[kCGWindowNumber as String] as? CGWindowID else { continue }
			let bounds = CGRect(x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
								width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0)
			if bounds.contains(cgPoint) {
				hitWindowID = windowID
				break
			}
		}
		guard let windowID = hitWindowID else { return nil }

		// Map to AX's WindowInfo
		let allWindows = AccessibilityManager.shared.getAllWindows()
		return allWindows.first { $0.id == windowID }
	}
}
