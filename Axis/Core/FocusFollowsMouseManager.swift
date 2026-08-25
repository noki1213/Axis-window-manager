//
//  FocusFollowsMouseManager.swift
//  Axis
//
//  Automatically focuses and raises the window under the mouse (focus follows mouse).
//  Handled in-process so it can auto-pause based on Axis's own state (mid Space-switch, mid selection mode, etc.).
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

	/// For measurement: the reason for the most recent early return (logging is suppressed while the reason stays the same)
	private var lastSkipReason: String?

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

		// For measurement: record the scheduled time and the configured delay, and check the drift against the actual measured delay until it fires
		let perfScheduledAt = CFAbsoluteTimeGetCurrent()
		let perfExpectedDelay = delayMs / 1000.0

		let work = DispatchWorkItem { [weak self] in
			if PerfLog.enabled {
				let actualDelay = CFAbsoluteTimeGetCurrent() - perfScheduledAt
				let drift = actualDelay - perfExpectedDelay
				// A congested main thread should show up as a bigger drift, so just watch the drift
				if drift >= 0.005 {
					PerfLog.logf("FFM onMouseMoved delay: expected %.1fms actual %.1fms (drift +%.1fms)",
						  perfExpectedDelay * 1000, actualDelay * 1000, drift * 1000)
				}
			}
			self?.focusWindowUnderMouse()
		}
		pendingWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + perfExpectedDelay, execute: work)
	}

	/// For measurement: suppress logging while the early-return reason stays the same, and print one line only when the reason changes
	private func logSkipReason(_ reason: String) {
		guard PerfLog.enabled else { return }
		guard lastSkipReason != reason else { return }
		lastSkipReason = reason
		PerfLog.logf("FFM skip: %@", reason)
	}

	private func focusWindowUnderMouse() {
		let perfOverallStart = CFAbsoluteTimeGetCurrent()
		defer {
			if PerfLog.enabled {
				let elapsed = CFAbsoluteTimeGetCurrent() - perfOverallStart
				if elapsed >= 0.005 {
					PerfLog.logf("FFM.focusWindowUnderMouse total: %.1fms", elapsed * 1000)
				}
			}
		}

		// --- Guard based on Axis's own state (prevents mis-focus specific to the built-in display) ---

		// Do nothing while a space switch is in progress (the switch logic focuses the correct window)
		guard !WorkspaceManager.shared.isSwitching else {
			logSkipReason("isSwitching")
			return
		}

		// Do nothing while in gap selection mode
		guard !GapSelectManager.shared.isActive else {
			logSkipReason("gapSelectMode")
			return
		}

		// Do nothing while Mission Control is showing
		guard !BorderManager.shared.isInMissionControl else {
			logSkipReason("missionControl")
			return
		}

		// --- Identify the window directly under the mouse ---

		let mouseLocation = NSEvent.mouseLocation
		guard let window = topmostWindowAt(mouseLocation) else {
			logSkipReason("no hit")
			return
		}

		// Excludes Axis's own windows (border overlay, palette, settings screen)
		guard window.app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
			logSkipReason("Axis itself")
			return
		}

		// Windows currently stashed in a hidden corner by the workspace or palette are excluded
		// (Prevents focus from jumping when the mouse touches the 1px sliver of a hidden window)
		guard !WorkspaceManager.shared.isWindowHidden(window.id) else {
			logSkipReason("hidden window (workspace)")
			return
		}
		guard !WindowPaletteManager.shared.isWindowHidden(window.id) else {
			logSkipReason("hidden window (palette)")
			return
		}

		// Do nothing if the window is already focused
		let focused = PerfLog.measure("FFM.getFocusedWindow", threshold: 0.005) {
			AccessibilityManager.shared.getFocusedWindow()
		}
		if let focused, focused.id == window.id {
			logSkipReason("already focused")
			return
		}

		// Since it proceeds to actual focus handling, it's fine to log a line again on the next early return
		lastSkipReason = nil

		// --- Focus + bring to front ---

		// focus() bundles together activating the app, setting AXFocused, and raising the window
		window.focus()

		// If what got focused is a tiled window (not floating),
		// Because raise buries the floating window behind the tiles,
		// Re-raise that screen's floating windows to the front (without stealing focus).
		// Without this, a floating window gets buried just from the mouse passing over a tile, and
		// After this, hovering can no longer reach the floating window
		let isFloatingTarget = WorkspaceManager.shared.isFloating(window.id) || window.shouldFloat()
		if !isFloatingTarget,
		   let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
			PerfLog.measure("FFM.raiseFloatingWindows", threshold: 0.005) {
				TilingEngine.shared.raiseFloatingWindows(on: screen)
			}
		}

		// Update the border only after focus has actually taken effect (same mechanism as JKLI movement)
		BorderManager.shared.updateBorderExpecting(windowID: window.id)
	}

	/// The upper bound on window layers subject to hit testing (anything at or above this is ignored)
	/// Windows the user actually focuses fall roughly within 0 to 103
	/// (normal 0 / floating panel 3 / status 25 / popup 103, etc.)
	/// 1000 and above is the layer for screen savers, shields, and desktop widgets, and
	/// In particular, while showing a screenshot preview CleanShot X uses a layer-2147483628
	/// Place an overlay covering the whole screen. Letting this get hit means anywhere on screen
	/// That overlay becomes frontmost, and focus-follows-mouse stops responding entirely
	private static let maxHitTestLayer = 1000

	/// A cache from pid to bundle id. Since focus-follows-mouse runs on every mouse move,
	/// Avoid querying NSRunningApplication every single time.
	/// Since the system UI process stays resident and its pid never changes, there's no risk of mixing it up
	private var bundleIdCache: [pid_t: String] = [:]

	private func bundleIdentifier(forPID pid: pid_t) -> String? {
		if let cached = bundleIdCache[pid] { return cached }
		guard let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return nil }
		bundleIdCache[pid] = bundleId
		return bundleId
	}

	/// Return the frontmost window at the given coordinates (screen coordinates, bottom-left origin)
	/// Since AccessibilityManager.getWindowAt returns the first hit in app order,
	/// The correct frontmost window can't be picked when a floating window overlaps a tile.
	/// Here, after identifying the window ID via CGWindowList (Z-order: front to back),
	/// Mapping it to WindowInfo ensures it always picks the visible window directly under the mouse.
	///
	/// A "genuine floating window" like a CleanShot X screenshot preview
	/// It appears as a floating-level NSPanel rather than the normal layer (layer == 0).
	/// If only the normal layer is considered, hits pass straight through that panel and land on the tile behind it, and
	/// Focus jumps to the tile underneath even while touching the panel. So a negative layer
	/// Everything except things like the desktop is subject to hit testing.
	private func topmostWindowAt(_ point: CGPoint) -> WindowInfo? {
		return PerfLog.measure("FFM.topmostWindowAt", threshold: 0.005) {
			// CGWindowList uses a top-left origin, so convert it
			let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
			let cgPoint = CGPoint(x: point.x, y: mainScreenHeight - point.y)

			let windowList = PerfLog.measure("FFM.topmostWindowAt/CGWindowListCopyWindowInfo", threshold: 0.005) {
				CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
			}
			let ownPID = ProcessInfo.processInfo.processIdentifier

			// Hit-test from front to back
			var hitWindowID: CGWindowID? = nil
			var hitPID: pid_t? = nil
			for entry in windowList {
				guard let layer = entry[kCGWindowLayer as String] as? Int,
					  layer >= 0, layer < Self.maxHitTestLayer,
					  let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat],
					  let windowID = entry[kCGWindowNumber as String] as? CGWindowID else { continue }

				// A fully transparent window is "invisible", so let it pass through.
				// This is the case for full-screen catch-all windows created by things like notification banners
				if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }

				// Let Axis's own windows (border overlay, palette, settings screen) pass through.
				// The border overlay always sits in front of the focused window, so
				// If we don't reject it here, every hit gets absorbed by the overlay and focus-follows-mouse stops working
				if let pid = entry[kCGWindowOwnerPID as String] as? pid_t {
					if pid == ownPID { continue }

					// Let system overlays like notification banners and Control Center pass through too.
					// These have a catch-all window covering the entire screen, so letting them get hit
					// focus and the border end up moving to the full-screen-sized window.
					// Only resolve bundle IDs for hit candidates, so we don't add scanning overhead
					let bounds = CGRect(x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
										width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0)
					guard bounds.contains(cgPoint) else { continue }

					if let bundleId = bundleIdentifier(forPID: pid),
					   AccessibilityManager.transientOverlayBundleIds.contains(bundleId) { continue }

					hitWindowID = windowID
					hitPID = pid
					break
				}
			}
			guard let windowID = hitWindowID, let pid = hitPID else { return nil }

			// Map it to the AX WindowInfo.
			// Unmatched means it's a panel outside AX management (e.g. a CleanShot X preview), so
			// Return nil without searching further back. Silencing focus-follows-mouse while the mouse is over it is correct, and
			// Searching further back here reintroduces the old bug where focus jumps to the tile underneath
			let appWindows = PerfLog.measure("FFM.topmostWindowAt/getWindowsForPID", threshold: 0.005) {
				AccessibilityManager.shared.getWindows(forPID: pid)
			}
			return appWindows.first { $0.id == windowID }
		}
	}
}
