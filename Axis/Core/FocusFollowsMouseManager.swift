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

	/// Temporary debugging: appends to /tmp/axis-debug.log (remove once the investigation is done)
	static func dbg(_ message: String) {
		let path = "/tmp/axis-debug.log"
		guard let data = (message + "\n").data(using: .utf8) else { return }
		if let handle = FileHandle(forWritingAtPath: path) {
			handle.seekToEndOfFile()
			handle.write(data)
			try? handle.close()
		} else {
			FileManager.default.createFile(atPath: path, contents: data)
		}
	}

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

		// --- Temporary debug log (for investigating border/actual-focus mismatch; remove once done) ---
		let ffmFormatter = DateFormatter()
		ffmFormatter.dateFormat = "HH:mm:ss.SSS"
		let ffmStamp = ffmFormatter.string(from: Date())
		let ffmTargetID = window.id
		let ffmTargetTitle = window.title
		let ffmTargetApp = window.app.localizedName ?? "nil"
		FocusFollowsMouseManager.dbg("[FFM] \(ffmStamp) focus() 実行 target=\(ffmTargetID) '\(ffmTargetTitle)' app=\(ffmTargetApp)")
		// Wait briefly, then verify that AX focus actually moved to that window
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
			let actual = AccessibilityManager.shared.getFocusedWindow()
			let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil"
			if actual?.id == ffmTargetID {
				FocusFollowsMouseManager.dbg("[FFM]   -> 成功: AXフォーカス=\(ffmTargetID) frontApp=\(frontApp)")
			} else {
				FocusFollowsMouseManager.dbg("[FFM]   -> ★失敗: 狙い=\(ffmTargetID) '\(ffmTargetTitle)' だが AXフォーカス=\(actual.map { "\($0.id) '\($0.title)'" } ?? "nil") frontApp=\(frontApp)")
			}
		}
		// --- End of temporary debug log ---

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

	/// The upper bound on window layers subject to hit testing (anything at or above this is ignored)
	/// Windows the user actually focuses fall roughly within 0 to 103
	/// (normal 0 / floating panel 3 / status 25 / popup 103, etc.)
	/// 1000 and above is the layer for screen savers, shields, and desktop widgets, and
	/// In particular, while showing a screenshot preview CleanShot X uses a layer-2147483628
	/// Place an overlay covering the whole screen. Letting this get hit means anywhere on screen
	/// That overlay becomes frontmost, and focus-follows-mouse stops responding entirely
	private static let maxHitTestLayer = 1000

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
		// CGWindowList uses a top-left origin, so convert it
		let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
		let cgPoint = CGPoint(x: point.x, y: mainScreenHeight - point.y)

		let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
		let ownPID = ProcessInfo.processInfo.processIdentifier

		// Hit-test from front to back
		var hitWindowID: CGWindowID? = nil
		for entry in windowList {
			guard let layer = entry[kCGWindowLayer as String] as? Int,
				  layer >= 0, layer < Self.maxHitTestLayer,
				  let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat],
				  let windowID = entry[kCGWindowNumber as String] as? CGWindowID else { continue }

			// Let Axis's own windows (border overlay, palette, settings screen) pass through.
			// The border overlay always sits in front of the focused window, so
			// If we don't reject it here, every hit gets absorbed by the overlay and focus-follows-mouse stops working
			if let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid == ownPID { continue }

			let bounds = CGRect(x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
								width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0)
			if bounds.contains(cgPoint) {
				hitWindowID = windowID
				break
			}
		}
		guard let windowID = hitWindowID else { return nil }

		// Map it to the AX WindowInfo.
		// Unmatched means it's a panel outside AX management (e.g. a CleanShot X preview), so
		// Return nil without searching further back. Silencing focus-follows-mouse while the mouse is over it is correct, and
		// Searching further back here reintroduces the old bug where focus jumps to the tile underneath
		let allWindows = AccessibilityManager.shared.getAllWindows()
		return allWindows.first { $0.id == windowID }
	}
}
