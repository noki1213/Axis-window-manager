//
//  WorkspaceManager.swift
//  Axis
//
//  Created on 2026/01/30.
//

import AppKit
import Combine

// MARK: - ScreenIdentifier

/// A struct that uniquely identifies a physical monitor
/// Uses NSScreen's displayID (CGDirectDisplayID)
struct ScreenIdentifier: Hashable {
	let displayID: CGDirectDisplayID

	init(from screen: NSScreen) {
		self.displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
	}

	/// Initialize directly from a displayID (used when restoring state)
	init(displayID: CGDirectDisplayID) {
		self.displayID = displayID
	}
}

// MARK: - PerScreenSnapshot

/// A struct that saves each workspace's tiling state
struct PerScreenSnapshot {
	/// Column structure (window IDs only)
	var columns: [[CGWindowID]]
	/// Column width ratios
	var columnWidthRatios: [CGFloat]?
	/// Row height ratios (column index -> each row's ratio)
	var rowHeightRatios: [Int: [CGFloat]]?
}

// MARK: - ClosedWindowsSnapshot (AeroSpace-style)

/// A snapshot of the entire workspace taken when a window is detected as "closed"
/// When the Accessibility API becomes unusable during the lock screen or sleep,
/// Since every window appears "closed," save the state at that moment
/// When the window is redetected, restore its original placement from this snapshot
struct ClosedWindowsSnapshot {
	let workspaceWindows: [ScreenIdentifier: [Int: Set<CGWindowID>]]
	let savedFrames: [CGWindowID: CGRect]
	let tilingSnapshots: [ScreenIdentifier: [Int: PerScreenSnapshot]]
	let activeWorkspace: [ScreenIdentifier: Int]
	let floatWindowIDs: Set<CGWindowID>
	let cachedWindowIDs: Set<CGWindowID>
	let windowIdentityCache: [CGWindowID: (bundleID: String, title: String)]
}

// MARK: - DisconnectedScreenData (for restoring on monitor reconnect)

/// A struct for temporarily storing a disconnected monitor's data
/// Used to restore the original state on reconnect
private struct DisconnectedScreenData {
	let workspaces: [Int: Set<CGWindowID>]
	let tilingSnapshots: [Int: PerScreenSnapshot]
	let activeWorkspace: Int
	let migratedToScreenID: ScreenIdentifier
	let migratedWorkspaceNumbers: [Int]  // Workspace numbers newly created on the MacBook side
}

// MARK: - WorkspaceManager

/// The central class for the workspace feature
/// Each monitor manages its workspace independently
class WorkspaceManager: ObservableObject {
	static let shared = WorkspaceManager()

	// MARK: - State

	/// The currently active workspace number for each monitor (initial value: 0)
	@Published var activeWorkspace: [ScreenIdentifier: Int] = [:]

	/// Whether a workspace switch is in progress (used to prevent checkForWindowChanges from misfiring)
	var isSwitching: Bool = false

	/// The window IDs belonging to each monitor x workspace pair
	/// [monitor identifier: [workspace number: set of window IDs]]
	private var workspaceWindows: [ScreenIdentifier: [Int: Set<CGWindowID>]] = [:]

	/// The original position of a window moved off screen
	private var savedFrames: [CGWindowID: CGRect] = [:]

	/// Whether the initial workspace setup (initializeWithCurrentWindows) has completed
	/// Once it becomes true, calling it again (e.g. from a Space switch) does nothing.
	/// Reason: initializeWithCurrentWindows() only handles "windows currently visible on screen"
	/// Re-register to workspace 0, and forcibly reset activeWorkspace to 0 as well.
	/// Running this every time fullscreen is entered or exited (which fires a Space-switch notification) would
	/// The workspace assignments the user made would be lost.
	private(set) var isInitialized: Bool = false

	/// A cache of window identity info (used when it's off screen and getAllWindows can't retrieve it)
	private var windowIdentityCache: [CGWindowID: (bundleID: String, title: String)] = [:]

	/// The IDs of windows pulled out of tiling and left floating
	private(set) var floatWindowIDs: Set<CGWindowID> = []

	/// Storage of the column structure and ratios for each monitor x workspace pair
	private var tilingSnapshots: [ScreenIdentifier: [Int: PerScreenSnapshot]] = [:]

	/// The AeroSpace approach: a full snapshot taken when a window is detected as "closed"
	/// In case windows appear to vanish during the lock screen or sleep
	private var closedWindowsCache: ClosedWindowsSnapshot?

	/// Temporarily save the disconnected monitor's data (for restoring on reconnect)
	private var disconnectedScreenData: [ScreenIdentifier: DisconnectedScreenData] = [:]

	private let accessibilityManager = AccessibilityManager.shared
	private let tilingEngine = TilingEngine.shared

	private init() {}

	// MARK: - Float (floating)

	/// Toggle the window's Float state
	/// A window that's Float is excluded from tiling and floats in place
	func toggleFloat(windowID: CGWindowID) {
		if floatWindowIDs.contains(windowID) {
			floatWindowIDs.remove(windowID)
		} else {
			floatWindowIDs.insert(windowID)
		}
	}

	/// Returns whether the window is currently Float
	func isFloating(_ windowID: CGWindowID) -> Bool {
		return floatWindowIDs.contains(windowID)
	}

	// MARK: - Public Methods

	/// Get a ScreenIdentifier from an NSScreen
	func screenIdentifier(for screen: NSScreen) -> ScreenIdentifier {
		return ScreenIdentifier(from: screen)
	}

	/// Get the current NSScreen from a ScreenIdentifier
	func screen(for identifier: ScreenIdentifier) -> NSScreen? {
		return NSScreen.screens.first { screen in
			let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
			return id == identifier.displayID
		}
	}

	/// Get the given monitor's current workspace number
	func currentWorkspace(on screen: NSScreen) -> Int {
		let id = screenIdentifier(for: screen)
		return activeWorkspace[id] ?? 0
	}

	/// Return the window IDs of the given monitor's current workspace
	func windowIDsForCurrentWorkspace(on screen: NSScreen) -> Set<CGWindowID> {
		let id = screenIdentifier(for: screen)
		let workspace = activeWorkspace[id] ?? 0
		return workspaceWindows[id]?[workspace] ?? []
	}

	/// Return the monitor the given window is registered to
	func screenForWindow(_ windowID: CGWindowID) -> NSScreen? {
		for (screenID, workspaces) in workspaceWindows {
			for (_, windowSet) in workspaces {
				if windowSet.contains(windowID) {
					return screen(for: screenID)
				}
			}
		}
		return nil
	}

	/// Return the monitor and workspace number the given window belongs to
	func workspaceLocation(for windowID: CGWindowID) -> (screen: NSScreen, workspace: Int)? {
		for (screenID, workspaces) in workspaceWindows {
			for (workspace, windowSet) in workspaces {
				if windowSet.contains(windowID), let screen = screen(for: screenID) {
					return (screen, workspace)
				}
			}
		}
		return nil
	}

	/// Move the window to another monitor (for cross-monitor movement)
	/// Remove it from the original monitor's workspace and register it to the destination monitor's current workspace
	func moveWindowBetweenScreens(_ windowID: CGWindowID, from sourceScreen: NSScreen, to targetScreen: NSScreen) {
		let sourceID = screenIdentifier(for: sourceScreen)
		let targetID = screenIdentifier(for: targetScreen)
		let sourceWS = activeWorkspace[sourceID] ?? 0
		let targetWS = activeWorkspace[targetID] ?? 0

		// Remove it from the original monitor's workspace
		workspaceWindows[sourceID]?[sourceWS]?.remove(windowID)

		// Add it to the destination monitor's workspace
		if workspaceWindows[targetID] == nil {
			workspaceWindows[targetID] = [:]
		}
		if workspaceWindows[targetID]?[targetWS] == nil {
			workspaceWindows[targetID]?[targetWS] = []
		}
		workspaceWindows[targetID]?[targetWS]?.insert(windowID)

	}

	/// Register a new window to the current workspace
	func registerWindow(_ windowID: CGWindowID, on screen: NSScreen) {
		let id = screenIdentifier(for: screen)
		let workspace = activeWorkspace[id] ?? 0

		if workspaceWindows[id] == nil {
			workspaceWindows[id] = [:]
		}
		if workspaceWindows[id]?[workspace] == nil {
			workspaceWindows[id]?[workspace] = []
		}
		workspaceWindows[id]?[workspace]?.insert(windowID)
		PerfLog.event("workspace: registered #\(windowID) -> \(PerfLog.describe(screen)) ws\(workspace + 1)")
	}

	/// The first workspace nothing is on yet, just past the last one in use on
	/// `screen`. Workspaces in use are kept contiguous from 0, so this is the
	/// only empty one to the right.
	func firstUnusedWorkspace(on screen: NSScreen) -> Int {
		let id = screenIdentifier(for: screen)
		let active = activeWorkspace[id] ?? 0
		let inUse = (workspaceWindows[id] ?? [:])
			.filter { $0.key >= 0 && (!$0.value.isEmpty || $0.key == active) }
			.keys
		return (inUse.max() ?? -1) + 1
	}

	/// Register a window on `workspace` of `screen` and move it out of sight,
	/// leaving the workspace on screen and its tiling as they are.
	func registerWindowOutOfSight(_ windowID: CGWindowID, on screen: NSScreen, workspace: Int) {
		let id = screenIdentifier(for: screen)
		if workspaceWindows[id] == nil {
			workspaceWindows[id] = [:]
		}
		workspaceWindows[id]?[workspace, default: []].insert(windowID)
		hideWindow(windowID)
	}

	/// Check whether even a single window is registered across all spaces
	/// - Returns: true if any space has a window
	func hasAnyRegisteredWindows() -> Bool {
		return workspaceWindows.values.contains { workspaces in
			workspaces.values.contains { !$0.isEmpty }
		}
	}

	/// Check whether the window is already registered to any workspace
	/// - Parameter windowID: the window ID being checked
	/// - Returns: true if it's already registered
	func isWindowInAnyWorkspace(_ windowID: CGWindowID) -> Bool {
		for screenID in workspaceWindows.keys {
			guard let workspaces = workspaceWindows[screenID] else { continue }
			for (_, windowSet) in workspaces {
				if windowSet.contains(windowID) {
					return true
				}
			}
		}
		return false
	}

	    /// Remove a closed window from every workspace

	    func unregisterWindow(_ windowID: CGWindowID) {

	        for screenID in workspaceWindows.keys {

	            guard let workspaces = workspaceWindows[screenID]?.keys else { continue }

	            var needsCleanup = false

	            

	            for workspace in workspaces {

	                if workspaceWindows[screenID]?[workspace]?.contains(windowID) == true {

	                    workspaceWindows[screenID]?[workspace]?.remove(windowID)
	                    PerfLog.event("workspace: unregistered #\(windowID) from display\(screenID.displayID) ws\(workspace + 1)")

	                    needsCleanup = true

	                }

	            }

	            

	            savedFrames.removeValue(forKey: windowID)

	            // Also remove it from the Float state
	            floatWindowIDs.remove(windowID)

	            // Also remove it from the tiling snapshot

	            guard let workspacesSnapshot = tilingSnapshots[screenID]?.keys else { continue }

	            for workspace in workspacesSnapshot {

	                if var snapshot = tilingSnapshots[screenID]?[workspace] {

	                    snapshot.columns = snapshot.columns.map { column in

	                        column.filter { $0 != windowID }

	                    }.filter { !$0.isEmpty }

	                    tilingSnapshots[screenID]?[workspace] = snapshot

	                }

	            }

	            

	            // Run cleanup for the monitors that changed

	            if needsCleanup, let screen = screen(for: screenID) {

	                cleanupEmptyWorkspaces(on: screen)

	            }

	        }

	    }

	

	    /// Returns window IDs across every monitor and workspace (used by the window palette)

	    /// Returns whether the given window is currently stashed off screen (used to control border display)
	    /// An entry existing in savedFrames means WorkspaceManager has hidden it in another workspace
	    func isWindowHidden(_ windowID: CGWindowID) -> Bool {
	    	return savedFrames[windowID] != nil
	    }

	    /// Returns window IDs across every monitor and workspace in tiling order (used by the window palette)
	    /// Columns go left-to-right, and within each column, top-to-bottom
	    func windowIDsInTilingOrder() -> [ScreenIdentifier: [Int: [CGWindowID]]] {
	    	var result: [ScreenIdentifier: [Int: [CGWindowID]]] = [:]

	    	for (screenID, workspaces) in workspaceWindows {
	    		result[screenID] = [:]
	    		for (workspace, windowIDs) in workspaces {
	    			if let snapshot = tilingSnapshots[screenID]?[workspace] {
	    				// Lay out windows in the snapshot's column order (left-to-right, top-to-bottom)
	    				let orderedByTiling = snapshot.columns.flatMap { $0 }
	    				var ordered: [CGWindowID] = []
	    				var remaining = windowIDs
	    				for id in orderedByTiling {
	    					if remaining.contains(id) {
	    						ordered.append(id)
	    						remaining.remove(id)
	    					}
	    				}
	    				// Windows not included in the snapshot (e.g. Float) are appended at the end
	    				ordered.append(contentsOf: remaining)
	    				result[screenID]?[workspace] = ordered
	    			} else {
	    				result[screenID]?[workspace] = Array(windowIDs)
	    			}
	    		}
	    	}

	    	return result
	    }

	    /// Returns the window IDs for the given monitor and workspace number in tiling order (used by the peek feature)
	    /// Columns go left-to-right, and within each column, top-to-bottom. Returns an empty array if the workspace doesn't exist or is empty
	    func windowIDsInTilingOrder(workspace: Int, on screen: NSScreen) -> [CGWindowID] {
	    	let id = screenIdentifier(for: screen)
	    	guard let windowIDs = workspaceWindows[id]?[workspace], !windowIDs.isEmpty else {
	    		return []
	    	}

	    	guard let snapshot = tilingSnapshots[id]?[workspace] else {
	    		return Array(windowIDs)
	    	}

	    	let orderedByTiling = snapshot.columns.flatMap { $0 }
	    	var ordered: [CGWindowID] = []
	    	var remaining = windowIDs
	    	for wid in orderedByTiling {
	    		if remaining.contains(wid) {
	    			ordered.append(wid)
	    			remaining.remove(wid)
	    		}
	    	}
	    	// Windows not included in the snapshot (e.g. Float) are appended at the end
	    	ordered.append(contentsOf: remaining)
	    	return ordered
	    }



	    // MARK: - Workspace Cleanup

	    

	    /// Delete empty workspaces and compact the numbering

	    private func cleanupEmptyWorkspaces(on screen: NSScreen) {
		let id = screenIdentifier(for: screen)
		guard let workspaces = workspaceWindows[id] else { return }

		// Separate negative spaces from non-negative ones
		// Negative spaces (-1, -2, ...) aren't reordered; keep them as they are
		let negativeIDs = workspaces.keys.filter { $0 < 0 }.sorted()
		let nonNegativeIDs = workspaces.keys.filter { $0 >= 0 }.sorted()

		// Build the mapping to the new ID
		// Rule:
		// 1. Leave negative spaces as-is without renumbering (delete if empty)
		// 2. Compact non-negative spaces (0 and above) down to 0, 1, 2, ...
		// 3. Always keep workspace 0 (the default)
		// 4. Keep workspaces that still have windows

		var mapping: [Int: Int] = [:]
		var hasChanges = false

		// Handle negative spaces (numbers stay unchanged)
		for oldID in negativeIDs {
			let windowCount = workspaces[oldID]?.count ?? 0
			if windowCount > 0 {
				// Keep it if it has windows (don't renumber)
				mapping[oldID] = oldID
			} else {
				// Delete it if empty
				hasChanges = true
			}
		}

		// Handle non-negative spaces (compact down to 0, 1, 2, ...)
		var nextID = 0
		// Check whether even a single non-negative space has a window (used to keep space 0 around when everything is empty)
		let hasAnyWindowsInNonNegative = nonNegativeIDs.contains { (workspaces[$0]?.count ?? 0) > 0 }

		for oldID in nonNegativeIDs {
			let windowCount = workspaces[oldID]?.count ?? 0

			// Conditions to keep it:
			// - It has windows in it
			// - OR: it's space 0, and there isn't a single window across all non-negative spaces (at least one space is required)
			if windowCount > 0 || (oldID == 0 && !hasAnyWindowsInNonNegative) {
				if oldID != nextID {
					hasChanges = true
				}
				mapping[oldID] = nextID
				nextID += 1
			} else {
				// Marked for deletion (empty space)
				hasChanges = true
			}
		}

		guard hasChanges else { return }


		// Rebuild the data with the new ID
		var newWorkspaceWindows: [Int: Set<CGWindowID>] = [:]
		var newTilingSnapshots: [Int: PerScreenSnapshot] = [:]

		for (oldID, newID) in mapping {
			// Migrate the window info
			if let windows = workspaces[oldID] {
				newWorkspaceWindows[newID] = windows
			}

			// Migrate the tiling info
			if let snapshot = tilingSnapshots[id]?[oldID] {
				newTilingSnapshots[newID] = snapshot
			}
		}

		workspaceWindows[id] = newWorkspaceWindows
		tilingSnapshots[id] = newTilingSnapshots

		// Adjust the active workspace
		if let currentActive = activeWorkspace[id] {
			let previousActive = currentActive
			var activeWasDeleted = false

			if let newActive = mapping[currentActive] {
				// When the spot this window was at has moved (or stayed the same)
				activeWorkspace[id] = newActive
			} else {
				// When the spot this window was at has been deleted
				// If it was in a negative space and got deleted, reset it to 0
				// If it was in a positive space and got deleted, clamp it to the max value
				activeWasDeleted = true
				if currentActive < 0 {
					activeWorkspace[id] = 0
				} else {
					let maxID = max(0, nextID - 1)
					let newActive = min(currentActive, maxID)
					activeWorkspace[id] = newActive
				}
			}

			// If the active workspace changed, or if the original space was deleted,
			// Show the destination window
			// (If we don't remove it from savedFrames, isWindowHidden stays true and the border never shows)
			// Note: even if the number stays the same, the content can be swapped out by a delete-then-renumber
			//       e.g. if space 1 is empty and gets deleted, and space 2 shifts down to 1,
			//           the number stays 1 but the content changes to Xcode, so show/focus is needed
			let resolvedActive = activeWorkspace[id]!
			if previousActive != resolvedActive || activeWasDeleted {
				showWindowsForWorkspace(resolvedActive, on: id)
				focusFirstWindow(in: resolvedActive, on: id)
			}
		}

		// Notification
		NotificationCenter.default.post(name: .workspaceChanged, object: nil)

		// Also call the border update so things like the menu bar get refreshed
		DispatchQueue.main.async {
			BorderManager.shared.updateBorder()
		}
	    }

	

	// MARK: - ClosedWindowsCache (the AeroSpace-style restore mechanism)

	/// Called when a window is detected as "closed"
	/// Save a snapshot of the entire current workspace into the cache
	func cacheCurrentStateOnWindowClose() {
		let allCachedIDs = Set(workspaceWindows.values.flatMap { $0.values.flatMap { $0 } })

		// Don't cache it if there's no managed window
		guard !allCachedIDs.isEmpty else { return }

		closedWindowsCache = ClosedWindowsSnapshot(
			workspaceWindows: workspaceWindows,
			savedFrames: savedFrames,
			tilingSnapshots: tilingSnapshots,
			activeWorkspace: activeWorkspace,
			floatWindowIDs: floatWindowIDs,
			cachedWindowIDs: allCachedIDs,
			windowIdentityCache: windowIdentityCache
		)
	}

	/// Check whether a newly detected window is in the cache, and restore it
	/// - Parameter detectedWindowID: the ID of the re-detected window
	/// - Returns: true if it was restored
	func restoreFromCacheIfNeeded(detectedWindowID: CGWindowID) -> Bool {
		guard let cache = closedWindowsCache else { return false }

		// No timeout (the AeroSpace approach)
		// The cache is only reset by user actions (workspace switches, etc.)
		// So it can still be restored after a long sleep or lock

		// Whether the detected window is present in the cache
		guard cache.cachedWindowIDs.contains(detectedWindowID) else { return false }

		// Restore everything from the cache
		PerfLog.event("workspace: restored from close-cache (trigger #\(detectedWindowID), \(cache.cachedWindowIDs.count) windows)")

		workspaceWindows = cache.workspaceWindows
		savedFrames = cache.savedFrames
		tilingSnapshots = cache.tilingSnapshots
		activeWorkspace = cache.activeWorkspace
		floatWindowIDs = cache.floatWindowIDs
		windowIdentityCache = cache.windowIdentityCache

		// Clear the cache
		closedWindowsCache = nil

		return true
	}

	/// Reset the cache when the user deliberately changes the layout
	/// Called after a user action, such as a workspace switch or window move
	func resetClosedWindowsCache() {
		if closedWindowsCache != nil {
			closedWindowsCache = nil
		}
	}

	    /// Register every window to workspace 0 at launch

	
	func initializeWithCurrentWindows() {
		// Skip once the initial setup is complete
		// (So being called on every Space switch doesn't corrupt the workspace assignments)
		if isInitialized {
			return
		}


		let allWindows = accessibilityManager.getAllWindows()
		let onScreenIDs = accessibilityManager.getOnScreenWindowIDs()

		for screen in NSScreen.screens {
			let id = screenIdentifier(for: screen)
			activeWorkspace[id] = 0

			if workspaceWindows[id] == nil {
				workspaceWindows[id] = [:]
			}
			workspaceWindows[id]?[0] = []

			for window in allWindows {

				let managed = window.shouldBeManaged()
				let floating = window.shouldFloat()
				let onScreen = onScreenIDs.contains(window.id)

				if !managed || floating || !onScreen {
					continue
				}

				if screen.frame.contains(window.centerInScreenCoordinates) {
					workspaceWindows[id]?[0]?.insert(window.id)
				}
			}

		}

		// Fallback for off-screen windows:
		// Managed windows that weren't assigned to any screen
		// Register it to workspace 0 of the nearest screen
		// (Handles the case where rescueOffScreenWindows()'s AX update lands at the wrong time)
		let assignedWindowIDs = NSScreen.screens.reduce(into: Set<CGWindowID>()) { result, scr in
			let scid = screenIdentifier(for: scr)
			if let ws0 = workspaceWindows[scid]?[0] {
				result.formUnion(ws0)
			}
		}
		for window in allWindows {
			guard window.shouldBeManaged() && !window.shouldFloat() else { continue }
			guard onScreenIDs.contains(window.id) else { continue }
			guard !assignedWindowIDs.contains(window.id) else { continue }

			let center = window.centerInScreenCoordinates
			if let nearest = NSScreen.screens.min(by: { s1, s2 in
				hypot(center.x - s1.frame.midX, center.y - s1.frame.midY) <
				hypot(center.x - s2.frame.midX, center.y - s2.frame.midY)
			}) {
				let nearestID = screenIdentifier(for: nearest)
				workspaceWindows[nearestID]?[0]?.insert(window.id)
			}
		}

		// Initial setup complete. From here on, this function does nothing thanks to the guard at the top
		isInitialized = true
	}

	/// Force re-initialization if the state is broken (for the watchdog)
	/// Re-register every window to workspace 0
	func forceReinitialize() {
		PerfLog.event("workspace: force reinitialize (all registrations dropped)")

		// Clear the state
		isInitialized = false
		workspaceWindows.removeAll()
		savedFrames.removeAll()
		tilingSnapshots.removeAll()
		activeWorkspace.removeAll()
		floatWindowIDs.removeAll()
		closedWindowsCache = nil
		disconnectedScreenData.removeAll()

		// Re-register every window to workspace 0
		initializeWithCurrentWindows()
	}

	// MARK: - Workspace Switching

	/// Switch workspaces
	/// - Parameters:
	///   - workspace: the workspace number being switched to
	///   - screen: the target monitor
	///   - focusWindowID: the window ID to focus after switching (defaults to the first window if omitted)
	func switchWorkspace(to workspace: Int, on screen: NSScreen, focusWindowID: CGWindowID? = nil) {
		let id = screenIdentifier(for: screen)
		let currentWS = activeWorkspace[id] ?? 0

		// Do nothing if it's the same workspace
		guard workspace != currentWS else {
			return
		}


		// Set the switching-in-progress flag (prevents checkForWindowChanges from misfiring)
		isSwitching = true
		PerfLog.event("workspace: switch \(PerfLog.describe(screen)) ws\(currentWS + 1) -> ws\(workspace + 1)"
			+ (focusWindowID.map { " (focus #\($0))" } ?? ""))

		// Reset the cache since this is a user action
		resetClosedWindowsCache()

		// Clear it if Zen Mode is active and this is a space switch on the same monitor
		// (Not cleared by a space switch on a different monitor)
		if ZenModeManager.shared.isActive,
		   ZenModeManager.shared.activeScreen == screen {
			ZenModeManager.shared.toggle()
		}

		// 1. Save the current workspace's TilingEngine state
		saveTilingState(for: id, workspace: currentWS, on: screen)

		// 2. Update activeWorkspace
		activeWorkspace[id] = workspace

		// 3. Create the destination workspace if it doesn't exist
		if workspaceWindows[id]?[workspace] == nil {
			if workspaceWindows[id] == nil {
				workspaceWindows[id] = [:]
			}
			workspaceWindows[id]?[workspace] = []
		}

		// 4. Restore the destination workspace's TilingEngine state
		restoreTilingState(for: id, workspace: workspace, on: screen)

		// 5. Restore and tile the destination windows first (so an empty screen never shows)
		showWindowsForWorkspace(workspace, on: id)
		tilingEngine.tile(on: screen)

		// 6. Focus a window in the workspace (note down the ID actually focused)
		let focusedID: CGWindowID?
		if let windowID = focusWindowID {
			focusedID = focusWindow(windowID, in: workspace, on: id)
		} else {
			focusedID = focusFirstWindow(in: workspace, on: id)
		}

		// 7. Hide the old windows after a short delay (once the new windows have rendered on screen)
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
			self?.hideWindowsForWorkspace(currentWS, on: id)
		}

		// 8. Update the border and move the cursor to the center of the focused window
		syncBorderAndCursor(to: focusedID)

		// 9. Update the workspace number in the menu bar
		NotificationCenter.default.post(name: .workspaceChanged, object: nil)

		// 10. Clear the switching-in-progress flag after a short delay
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
			self?.isSwitching = false
		}

		// 11. Record window identities for matching after sleep
		refreshWindowIdentities()

	}

	/// Move to the next workspace (+1)
	func switchToNextWorkspace(on screen: NSScreen) {
		let id = screenIdentifier(for: screen)
		let currentWS = activeWorkspace[id] ?? 0
		switchWorkspace(to: currentWS + 1, on: screen)
	}

	/// Move to the previous workspace (-1)
	func switchToPreviousWorkspace(on screen: NSScreen) {
		let id = screenIdentifier(for: screen)
		let currentWS = activeWorkspace[id] ?? 0
		switchWorkspace(to: currentWS - 1, on: screen)
	}

	// MARK: - Move Window to Workspace

	/// Move the focused window to the next workspace (the space switches immediately too)
	func moveWindowToNextWorkspace(on screen: NSScreen) {
		guard let focusedWindow = accessibilityManager.getFocusedWindow() else { return }
		let id = screenIdentifier(for: screen)
		let currentWS = activeWorkspace[id] ?? 0
		let targetWS = currentWS + 1
		moveWindowToWorkspaceAndSwitch(focusedWindow.id, from: currentWS, to: targetWS, screenID: id, screen: screen)
	}

	/// Move the focused window to the previous workspace (the space switches immediately too)
	func moveWindowToPreviousWorkspace(on screen: NSScreen) {
		guard let focusedWindow = accessibilityManager.getFocusedWindow() else { return }
		let id = screenIdentifier(for: screen)
		let currentWS = activeWorkspace[id] ?? 0
		let targetWS = currentWS - 1
		moveWindowToWorkspaceAndSwitch(focusedWindow.id, from: currentWS, to: targetWS, screenID: id, screen: screen)
	}

	/// Register the window to the destination workspace and switch to it immediately
	private func moveWindowToWorkspaceAndSwitch(_ windowID: CGWindowID, from currentWS: Int, to targetWS: Int, screenID id: ScreenIdentifier, screen: NSScreen) {
		// Move the window to the destination workspace in the data
		workspaceWindows[id]?[currentWS]?.remove(windowID)

		if workspaceWindows[id]?[targetWS] == nil {
			if workspaceWindows[id] == nil {
				workspaceWindows[id] = [:]
			}
			workspaceWindows[id]?[targetWS] = []
		}
		workspaceWindows[id]?[targetWS]?.insert(windowID)

		// Also remove the window from TilingEngine's snapshot
		if var snapshot = tilingSnapshots[id]?[currentWS] {
			snapshot.columns = snapshot.columns.map { column in
				column.filter { $0 != windowID }
			}.filter { !$0.isEmpty }
			tilingSnapshots[id]?[currentWS] = snapshot
		}

		// Switch workspaces immediately (the window stays visible since it's already on screen)
		switchWorkspace(to: targetWS, on: screen, focusWindowID: windowID)

		// Clean up once the original workspace becomes empty
		cleanupEmptyWorkspaces(on: screen)
	}

	// MARK: - Hide Corner (the AeroSpace approach)

	/// The corner used to hide a window
	private func optimalHideCorner(for screenID: ScreenIdentifier) -> HideCorner {
		guard let screen = screen(for: screenID) else { return .bottomLeft }
		return HideCorner.best(for: screen)
	}

	private func hidePosition(for window: WindowInfo, corner: HideCorner, on screenID: ScreenIdentifier) -> CGPoint? {
		guard let screen = screen(for: screenID) else { return nil }
		return corner.position(forWindowWidth: window.frame.width, on: screen)
	}

	// MARK: - Private Helpers

	/// Move the given workspace's windows to the corner and hide them (the AeroSpace approach)
	private func hideWindowsForWorkspace(_ workspace: Int, on screenID: ScreenIdentifier) {
		guard let windowIDs = workspaceWindows[screenID]?[workspace] else { return }

		let corner = optimalHideCorner(for: screenID)
		let allWindows = accessibilityManager.getAllWindows()

		for window in allWindows {
			// Don't physically move windows that are in fullscreen (avoid polluting savedFrames)
			if windowIDs.contains(window.id) && !window.isFullscreen {
				// Save the original position and size
				savedFrames[window.id] = window.frame

				// Cache the window's identity info (used when saving)
				windowIdentityCache[window.id] = (
					bundleID: window.app.bundleIdentifier ?? "",
					title: window.title
				)

				// Move to the corner (position only, size unchanged)
				if let hidePos = hidePosition(for: window, corner: corner, on: screenID) {
					window.setPosition(hidePos)
				}
			}
		}
	}

	/// Restore every workspace's hidden windows to their original positions (used when the app quits)
	func restoreAllHiddenWindows() {
		guard !savedFrames.isEmpty else { return }

		let allWindows = accessibilityManager.getAllWindows()
		var restoredCount = 0

		for window in allWindows {
			if let savedFrame = savedFrames[window.id] {
				window.setFrame(savedFrame)
				restoredCount += 1
			}
		}

		savedFrames.removeAll()
	}

	/// Of the managed windows currently on screen,
	/// "The registered workspace differs from the monitor's currently active workspace"
	/// Detect ones that are "different" and stash them in the hidden corner.
	///
	/// A window that exited native fullscreen isn't unregistered, and instead
	/// Keeps the original workspace registration. Axis's workspaces are
	/// Since this is implemented by stashing the window in a corner within the same real Space, after exiting fullscreen
	/// The window always returns to the same real Space, and if the original workspace is inactive
	/// It ends up appearing overlapped with the currently shown workspace. This reclaims it.
	///
	/// - Parameter currentWindows: the list of currently on-screen, managed windows
	/// - Returns: the set of window IDs that were actually hidden (used by the caller to exclude them from focus targets)
	@discardableResult
	func hideStrayVisibleWindows(currentWindows: [WindowInfo]) -> Set<CGWindowID> {
		var hiddenIDs: Set<CGWindowID> = []

		for window in currentWindows {
			// Float (floating) windows are excluded
			guard !isFloating(window.id) else { continue }

			// Windows not registered anywhere are excluded (left to the new-window registration process)
			guard let location = workspaceLocation(for: window.id) else { continue }

			// Do nothing if the target workspace is already the active one, since it's showing normally
			let activeWS = currentWorkspace(on: location.screen)
			guard location.workspace != activeWS else { continue }

			// Skip it if it's already stashed in the hidden corner (an entry exists in savedFrames)
			// (Required guard, since hidden windows on inactive workspaces are still visible on-screen by 1px)
			guard !isWindowHidden(window.id) else { continue }

			PerfLog.event("workspace: stray \(PerfLog.describe(window)) belongs to ws\(location.workspace + 1) (active ws\(activeWS + 1)); hiding")
			hideWindow(window.id)
			hiddenIDs.insert(window.id)
		}

		return hiddenIDs
	}

	/// Restore the given workspace's windows to their original positions
	private func showWindowsForWorkspace(_ workspace: Int, on screenID: ScreenIdentifier) {
		guard let windowIDs = workspaceWindows[screenID]?[workspace] else { return }

		let allWindows = accessibilityManager.getAllWindows()
		for window in allWindows {
			// Don't physically move windows that are in fullscreen
			if windowIDs.contains(window.id) && !window.isFullscreen {
				// Restore the saved position and size
				if let savedFrame = savedFrames[window.id] {
					window.setFrame(savedFrame)
					savedFrames.removeValue(forKey: window.id)
				}
			}
		}
	}

	/// Move a single window to the corner and hide it
	private func hideWindow(_ windowID: CGWindowID) {
		let allWindows = accessibilityManager.getAllWindows()
		for window in allWindows {
			if window.id == windowID {
				// Skip the physical move while in fullscreen
				// (The workspace move in the data has already been done by the caller)
				guard !window.isFullscreen else { break }
				savedFrames[window.id] = window.frame

				// Cache the window's identity info
				windowIdentityCache[window.id] = (
					bundleID: window.app.bundleIdentifier ?? "",
					title: window.title
				)

				// Identify which monitor this window is on
				let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
				let windowCenterX = window.frame.midX
				let windowCenterY = mainScreenHeight - window.frame.midY
				let windowCenter = CGPoint(x: windowCenterX, y: windowCenterY)

				for screen in NSScreen.screens {
					if screen.frame.contains(windowCenter) {
						let screenID = screenIdentifier(for: screen)
						let corner = optimalHideCorner(for: screenID)
						if let hidePos = hidePosition(for: window, corner: corner, on: screenID) {
							window.setPosition(hidePos)
						}
						break
					}
				}
				break
			}
		}
	}

	/// Focus the first window of the given workspace
	/// - Returns: the ID of the window that was actually focused (nil if there was no target)
	@discardableResult
	private func focusFirstWindow(in workspace: Int, on screenID: ScreenIdentifier) -> CGWindowID? {
		guard let windowIDs = workspaceWindows[screenID]?[workspace],
			  !windowIDs.isEmpty else {
			return nil
		}

		let allWindows = accessibilityManager.getAllWindows()
		for window in allWindows {
			if windowIDs.contains(window.id) {
				window.focus()
				return window.id
			}
		}
		return nil
	}

	/// Focus the window with the given window ID
	/// - Returns: the ID of the window that was actually focused (nil if there was no target)
	@discardableResult
	private func focusWindow(_ windowID: CGWindowID, in workspace: Int, on screenID: ScreenIdentifier) -> CGWindowID? {
		let allWindows = accessibilityManager.getAllWindows()
		for window in allWindows {
			if window.id == windowID {
				window.focus()
				return window.id
			}
		}
		// If the specified window can't be found, focus the first window instead
		return focusFirstWindow(in: workspace, on: screenID)
	}

	/// Handle the post-focus-move border update and cursor movement together
	/// - Border: retries until focus actually moves to the target window before updating
	///   (Prevents the border from landing on the wrong window when macOS is slow to reflect focus. Same mechanism as log 001)
	/// - Cursor: moves to the center of the window, same as JKLI focus movement
	/// - Parameter windowID: the ID of the window that was focused (nil just updates the border once, as before)
	private func syncBorderAndCursor(to windowID: CGWindowID?) {
		guard let windowID = windowID else {
			// If there's nothing to focus (e.g. an empty workspace), fall back to the previous behavior
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
				BorderManager.shared.updateBorder()
			}
			return
		}

		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
			guard let self = self else { return }

			// Retry until focus actually moves to the target window before updating the border
			BorderManager.shared.updateBorderExpecting(windowID: windowID)

			// Move the mouse cursor to the center of the focused window
			let allWindows = self.accessibilityManager.getAllWindows()
			if let window = allWindows.first(where: { $0.id == windowID }) {
				self.tilingEngine.moveCursorToWindow(window)
			}
		}
	}

	// MARK: - Tiling State Management

	/// Save the current TilingEngine state
	private func saveTilingState(for screenID: ScreenIdentifier, workspace: Int, on screen: NSScreen) {
		let state = tilingEngine.saveTilingStateForScreen(screen)

		if tilingSnapshots[screenID] == nil {
			tilingSnapshots[screenID] = [:]
		}
		tilingSnapshots[screenID]?[workspace] = state

	}

	/// Get the column structure (window IDs only) for the given monitor and workspace
	/// For restoring a hidden window (the neighbor-memory approach), into an inactive workspace
	/// Used to find the insertion point
	func columnsSnapshot(on screenID: ScreenIdentifier, workspace: Int) -> [[CGWindowID]]? {
		return tilingSnapshots[screenID]?[workspace]?.columns
	}

	/// Update the column structure (window IDs only) for the given monitor and workspace
	/// Used for restoring a hidden window. If the target workspace is currently active,
	/// Since TilingEngine.tiledWindows holds the actual state, not this side,
	/// Operate directly on TilingEngine (only used when it's not active)
	func updateColumnsSnapshot(_ columns: [[CGWindowID]], on screenID: ScreenIdentifier, workspace: Int) {
		if tilingSnapshots[screenID] == nil {
			tilingSnapshots[screenID] = [:]
		}
		var snapshot = tilingSnapshots[screenID]?[workspace] ?? PerScreenSnapshot(columns: [], columnWidthRatios: nil, rowHeightRatios: nil)
		snapshot.columns = columns
		tilingSnapshots[screenID]?[workspace] = snapshot
	}

	/// Restore the saved TilingEngine state
	private func restoreTilingState(for screenID: ScreenIdentifier, workspace: Int, on screen: NSScreen) {
		if let snapshot = tilingSnapshots[screenID]?[workspace] {
			tilingEngine.restoreTilingStateForScreen(screen, snapshot: snapshot)
		} else {
			tilingEngine.clearTilingStateForScreen(screen)
		}
	}

	/// Return the focused monitor's workspace number (used for the menu bar display)
	func currentWorkspaceForFocusedScreen() -> Int {
		// The monitor the focused window is on
		if let focusedWindow = accessibilityManager.getFocusedWindow() {
			let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
			let windowCenterX = focusedWindow.frame.midX
			let windowCenterY = mainScreenHeight - focusedWindow.frame.midY
			let windowCenter = CGPoint(x: windowCenterX, y: windowCenterY)

			for screen in NSScreen.screens {
				if screen.frame.contains(windowCenter) {
					return currentWorkspace(on: screen)
				}
			}
		}

		// If there's no focused window, use the monitor the mouse cursor is on
		let mouseLocation = NSEvent.mouseLocation
		for screen in NSScreen.screens {
			if screen.frame.contains(mouseLocation) {
				return currentWorkspace(on: screen)
			}
		}

		// Otherwise, fall back to the main monitor's workspace
		if let mainScreen = NSScreen.main {
			return currentWorkspace(on: mainScreen)
		}

		return 0
	}

	/// Get the focused monitor
	func focusedScreen() -> NSScreen? {
		if let focusedWindow = accessibilityManager.getFocusedWindow() {
			let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
			let windowCenterX = focusedWindow.frame.midX
			let windowCenterY = mainScreenHeight - focusedWindow.frame.midY
			let windowCenter = CGPoint(x: windowCenterX, y: windowCenterY)

			for screen in NSScreen.screens {
				if screen.frame.contains(windowCenter) {
					return screen
				}
			}
		}

		// If there's no focused window, use the monitor the mouse cursor is on
		let mouseLocation = NSEvent.mouseLocation
		for screen in NSScreen.screens {
			if screen.frame.contains(mouseLocation) {
				return screen
			}
		}

		return NSScreen.main
	}

	// MARK: - Handling monitor connect/disconnect

	/// Handling for when a monitor is disconnected
	/// Migrate the disconnected monitor's workspaces to the remaining monitors as new workspaces
	func handleScreenDisconnected(removedScreenID: ScreenIdentifier) {

		// Exit the special mode
		if ZenModeManager.shared.isActive {
			ZenModeManager.shared.toggle()
		}
		if HotkeyManager.shared.currentMode == .windowPalette {
			WindowPaletteManager.shared.endPalette()
			HotkeyManager.shared.currentMode = .normal
			NotificationCenter.default.post(name: .modeChanged, object: HotkeyManager.Mode.normal)
		}
		isSwitching = true

		// Decide the destination monitor (normally the MacBook's built-in display)
		guard let targetScreen = NSScreen.screens.first else {
			isSwitching = false
			return
		}
		let targetScreenID = screenIdentifier(for: targetScreen)

		// Get the list of the disconnected monitor's workspaces
		let removedWSNumbers = workspaceWindows[removedScreenID]?.keys.sorted() ?? []
		guard !removedWSNumbers.isEmpty else {
			// Only clean up the data
			workspaceWindows.removeValue(forKey: removedScreenID)
			tilingSnapshots.removeValue(forKey: removedScreenID)
			activeWorkspace.removeValue(forKey: removedScreenID)
			tilingEngine.cleanupDisconnectedScreens()
			isSwitching = false
			return
		}

		// Assign a new number starting from the max existing destination workspace number + 1
		let existingWSNumbers = workspaceWindows[targetScreenID]?.keys.sorted() ?? [0]
		let maxExistingWS = existingWSNumbers.max() ?? 0
		var nextNewWS = maxExistingWS + 1

		// Collect all the window IDs to migrate
		var allMigratedWindowIDs = Set<CGWindowID>()

		// Record the destination workspace number, for use restoring on reconnect
		var migratedWSNumbers: [Int] = []

		for oldWS in removedWSNumbers {
			let windowIDs = workspaceWindows[removedScreenID]?[oldWS] ?? []
			allMigratedWindowIDs.formUnion(windowIDs)

			// Migrate workspaceWindows
			if workspaceWindows[targetScreenID] == nil {
				workspaceWindows[targetScreenID] = [:]
			}
			workspaceWindows[targetScreenID]?[nextNewWS] = windowIDs

			// Migrate tilingSnapshots (ratios are cleared, since screen sizes differ)
			if var snapshot = tilingSnapshots[removedScreenID]?[oldWS] {
				snapshot.columnWidthRatios = nil
				snapshot.rowHeightRatios = nil
				if tilingSnapshots[targetScreenID] == nil {
					tilingSnapshots[targetScreenID] = [:]

                }
				tilingSnapshots[targetScreenID]?[nextNewWS] = snapshot
			}

			migratedWSNumbers.append(nextNewWS)
			nextNewWS += 1
		}

		// Save the pre-disconnect data so the original state can be restored on reconnect
		disconnectedScreenData[removedScreenID] = DisconnectedScreenData(
			workspaces: workspaceWindows[removedScreenID] ?? [:],
			tilingSnapshots: tilingSnapshots[removedScreenID] ?? [:],
			activeWorkspace: activeWorkspace[removedScreenID] ?? 0,
			migratedToScreenID: targetScreenID,
			migratedWorkspaceNumbers: migratedWSNumbers
		)

		// Since disconnecting a monitor is a deliberate action, clear closedWindowsCache (used for sleep/lock)
		resetClosedWindowsCache()

		// Delete the migrated window's savedFrames (unusable since it's the disconnected monitor's coordinates)
		for windowID in allMigratedWindowIDs {
			savedFrames.removeValue(forKey: windowID)
		}

		// Move the migrated window to the destination monitor's hidden corner
		// (Since it's an inactive workspace, put it in a not-shown state)
		let allWindows = accessibilityManager.getAllWindows()
		let corner = optimalHideCorner(for: targetScreenID)

		for window in allWindows {
			// Don't physically move windows that are in fullscreen (the data-level migration is already done above)
			if allMigratedWindowIDs.contains(window.id) && !window.isFullscreen {
				// Save the current position to savedFrames before moving to the corner
				// (This gets restored correctly later via showWindowsForWorkspace -> tile when the space is switched)
				savedFrames[window.id] = window.frame
				if let hidePos = hidePosition(for: window, corner: corner, on: targetScreenID) {
					window.setPosition(hidePos)
				}
			}
		}

		// Delete the disconnected monitor's data
		workspaceWindows.removeValue(forKey: removedScreenID)
		tilingSnapshots.removeValue(forKey: removedScreenID)
		activeWorkspace.removeValue(forKey: removedScreenID)

		// Clean up TilingEngine
		tilingEngine.cleanupDisconnectedScreens()

		// Re-tile (rearrange the remaining monitors' active workspaces)
		tilingEngine.tileAllScreens()

		NotificationCenter.default.post(name: .workspaceChanged, object: nil)

		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
			BorderManager.shared.updateBorder()
		}

		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
			self?.isSwitching = false
		}

	}

	/// Handling for when a monitor is reconnected
	/// Restore the data saved at disconnect time, and delete the workspace that was migrated to the MacBook side
	func handleScreenReconnected(reconnectedScreenID: ScreenIdentifier) {
		// Look for an exact displayID match first.
		// Since macOS can change the displayID when a monitor is reconnected,
		// If there's no exact match, use the sole remaining entry in disconnectedScreenData
		// Treat it as the same physical monitor and use it as a fallback.
		let exactMatch = disconnectedScreenData[reconnectedScreenID]
		let fallback: (key: ScreenIdentifier, data: DisconnectedScreenData)? = {
			guard exactMatch == nil, disconnectedScreenData.count == 1,
			      let entry = disconnectedScreenData.first else { return nil }
			return (key: entry.key, data: entry.value)
		}()
		let savedDataOldKey: ScreenIdentifier? = exactMatch != nil ? reconnectedScreenID : fallback?.key
		let resolvedSavedData: DisconnectedScreenData? = exactMatch ?? fallback?.data

		if let savedData = resolvedSavedData, let oldKey = savedDataOldKey {
			// Restore data for a previously disconnected monitor
			workspaceWindows[reconnectedScreenID] = savedData.workspaces
			tilingSnapshots[reconnectedScreenID] = savedData.tilingSnapshots
			activeWorkspace[reconnectedScreenID] = savedData.activeWorkspace

			// Restore TilingEngine's column structure (avoids the column order getting scrambled after reconnecting)
			// Since tiledWindows[E] has already been cleared by cleanupDisconnectedScreens(),
			// Calling tile() as-is would treat every window as "new" and break the ordering.
			// Rebuild TilingEngine's state from the restored tilingSnapshots.
			if let reconnectedScreen = screen(for: reconnectedScreenID),
			   let snapshot = tilingSnapshots[reconnectedScreenID]?[savedData.activeWorkspace] {
				tilingEngine.restoreTilingStateForScreen(reconnectedScreen, snapshot: snapshot)
			}

			// Delete the migrated workspace on the MacBook side
			let migTargetID = savedData.migratedToScreenID

			// If the migrated workspace was active on the MacBook side,
			// its windows would otherwise stay visible after deletion.
			// Hide the "currently shown windows" before deletion, then return to ws0.
			let currentActiveMigWS = activeWorkspace[migTargetID] ?? 0
			if savedData.migratedWorkspaceNumbers.contains(currentActiveMigWS) {
				hideWindowsForWorkspace(currentActiveMigWS, on: migTargetID)
				activeWorkspace[migTargetID] = 0
			}

			for wsNum in savedData.migratedWorkspaceNumbers {
				workspaceWindows[migTargetID]?.removeValue(forKey: wsNum)
				tilingSnapshots[migTargetID]?.removeValue(forKey: wsNum)
			}

			disconnectedScreenData.removeValue(forKey: oldKey)

			// Avoids the focus border disappearing
			// tile() places windows directly but doesn't clear savedFrames.
			// If an entry remains in savedFrames, isWindowHidden() keeps returning true, and
			// The focus border stops showing up.
			// -> Clear savedFrames for windows belonging to each screen's active workspace.
			let reconnectedActiveWS = savedData.activeWorkspace
			for windowID in workspaceWindows[reconnectedScreenID]?[reconnectedActiveWS] ?? [] {
				savedFrames.removeValue(forKey: windowID)
			}
			let macBookActiveWS = activeWorkspace[migTargetID] ?? 0
			for windowID in workspaceWindows[migTargetID]?[macBookActiveWS] ?? [] {
				savedFrames.removeValue(forKey: windowID)
			}

			NotificationCenter.default.post(name: .workspaceChanged, object: nil)
		} else {
			// A new monitor (no prior connection data) - initialize workspace 0
			workspaceWindows[reconnectedScreenID] = [0: []]
			activeWorkspace[reconnectedScreenID] = 0

			// Register managed windows that are physically on this monitor
			let allWindows = accessibilityManager.getAllWindows()
			let onScreenIDs = accessibilityManager.getOnScreenWindowIDs()
			let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0

			if let newScreen = screen(for: reconnectedScreenID) {
				for window in allWindows {
					guard window.shouldBeManaged() && !window.shouldFloat() else { continue }
					guard onScreenIDs.contains(window.id) else { continue }
					guard !isWindowInAnyWorkspace(window.id) else { continue }

					let center = CGPoint(
						x: window.frame.midX,
						y: mainScreenHeight - window.frame.midY
					)
					if newScreen.frame.contains(center) {
						workspaceWindows[reconnectedScreenID]?[0]?.insert(window.id)
					}
				}
			}
		}
	}

	// MARK: - Re-matching window IDs after waking from sleep

	/// Since window IDs may have changed after waking from sleep,
	/// Re-match by bundleID + title and update the workspace data
	func rematchWindowIDsAfterWake() {
		let allWindows = accessibilityManager.getAllWindows()
		let managedWindows = allWindows.filter {
			$0.shouldBeManaged() && !$0.shouldFloat()
		}


		// Group the current windows into a bundleID+title -> [WindowInfo] dictionary
		var exactPool: [String: [WindowInfo]] = [:]
		var bundlePool: [String: [WindowInfo]] = [:]
		for window in managedWindows {
			let bundleID = window.app.bundleIdentifier ?? ""
			let key = bundleID + "||" + window.title
			exactPool[key, default: []].append(window)
			bundlePool[bundleID, default: []].append(window)
		}

		// Track new window IDs that have already been used
		var usedNewIDs = Set<CGWindowID>()
		// Mapping from old ID to new ID
		var idMapping: [CGWindowID: CGWindowID] = [:]
		// Whether anything changed
		var hasChanges = false

		// Re-match window IDs for each workspace
		for (_, workspaces) in workspaceWindows {
			for (
                _, windowIDs) in workspaces {
				for oldID in windowIDs {
					// First check whether the same ID exists in the current window list
					if managedWindows.contains(where: { $0.id == oldID }) {
						// ID hasn't changed -> use it as is
						usedNewIDs.insert(oldID)
						idMapping[oldID] = oldID
						continue
					}

					// ID has changed -> match against the cached info
					guard let cached = windowIdentityCache[oldID] else {
						continue
					}

					// Step 1: exact match on bundleID + title
					let exactKey = cached.bundleID + "||" + cached.title
					if var candidates = exactPool[exactKey],
					   let idx = candidates.firstIndex(where: { !usedNewIDs.contains($0.id) }) {
						let newWindow = candidates[idx]
						candidates.remove(at: idx)
						exactPool[exactKey] = candidates
						// Also remove from bundlePool
						if var bCandidates = bundlePool[cached.bundleID] {
							bCandidates.removeAll { $0.id == newWindow.id }
							bundlePool[cached.bundleID] = bCandidates
						}
						usedNewIDs.insert(newWindow.id)
						idMapping[oldID] = newWindow.id
						hasChanges = true
						continue
					}

					// Step 2: match on bundleID alone
					if var candidates = bundlePool[cached.bundleID],
					   let idx = candidates.firstIndex(where: { !usedNewIDs.contains($0.id) }) {
						let newWindow = candidates[idx]
						candidates.remove(at: idx)
						bundlePool[cached.bundleID] = candidates
						usedNewIDs.insert(newWindow.id)
						idMapping[oldID] = newWindow.id
						hasChanges = true
						continue
					}

					// Couldn't be matched (the window may have been closed)
				}
			}
		}

		guard hasChanges else {
			return
		}

		// Update the ID in the workspace data
		var newWorkspaceWindows: [ScreenIdentifier: [Int: Set<CGWindowID>]] = [:]
		for (screenID, workspaces) in workspaceWindows {
			newWorkspaceWindows[screenID] = [:]
			for (wsNumber, windowIDs) in workspaces {
				var newIDs = Set<CGWindowID>()
				for oldID in windowIDs {
					if let newID = idMapping[oldID] {
						newIDs.insert(newID)
					}
					// If there's no mapping, remove the old ID (the window is gone)
				}
				newWorkspaceWindows[screenID]?[wsNumber] = newIDs
			}
		}
		workspaceWindows = newWorkspaceWindows

		// Also update the ID in savedFrames
		var newSavedFrames: [CGWindowID: CGRect] = [:]
		for (oldID, frame) in savedFrames {
			if let newID = idMapping[oldID] {
				newSavedFrames[newID] = frame
			}
		}
		savedFrames = newSavedFrames

		// Also update the ID in windowIdentityCache
		var newCache: [CGWindowID: (bundleID: String, title: String)] = [:]
		for (oldID, info) in windowIdentityCache {
			if let newID = idMapping[oldID] {
				newCache[newID] = info
			}
		}
		windowIdentityCache = newCache

		// Also update the ID inside tilingSnapshots' column structure
		var newSnapshots: [ScreenIdentifier: [Int: PerScreenSnapshot]] = [:]
		for (screenID, wsSnapshots) in tilingSnapshots {
			newSnapshots[screenID] = [:]
			for (wsNumber, snapshot) in wsSnapshots {
				let newColumns = snapshot.columns.map { column in
					column.compactMap { oldID in idMapping[oldID] }
				}.filter { !$0.isEmpty }
				newSnapshots[screenID]?[wsNumber] = PerScreenSnapshot(
					columns: newColumns,
					columnWidthRatios: snapshot.columnWidthRatios,
					rowHeightRatios: snapshot.rowHeightRatios
				)
			}
		}
		tilingSnapshots = newSnapshots

		// Add windows that weren't matched (new windows) to workspace 0
		let unassigned = managedWindows.filter { !usedNewIDs.contains($0.id) }
		if !unassigned.isEmpty {
			let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
			for window in unassigned {
				let centerX = window.frame.midX
				let centerY = mainScreenHeight - window.frame.midY
				let center = CGPoint(x: centerX, y: centerY)
				for screen in NSScreen.screens {
					if screen.frame.contains(center) {
						let screenID = screenIdentifier(for: screen)
						if workspaceWindows[screenID]?[0] == nil {
							if workspaceWindows[screenID] == nil {
								workspaceWindows[screenID] = [:]
							}
							workspaceWindows[screenID]?[0] = []
						}
						workspaceWindows[screenID]?[0]?.insert(window.id)
						break
					}
				}
			}
		}

	}

	// MARK: - Window identities

	/// Record which app and title each window has. Window IDs can change across
	/// sleep and lock; this is what the windows are matched back up by.
	func refreshWindowIdentities() {
		for window in accessibilityManager.getAllWindows() {
			windowIdentityCache[window.id] = (
				bundleID: window.app.bundleIdentifier ?? "",
				title: window.title
			)
		}
	}

}

// MARK: - Notification Names

extension Notification.Name {
	static let workspaceChanged = Notification.Name("workspaceChanged")
}
