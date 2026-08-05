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

// MARK: - Struct for persisting workspace state

/// Information for identifying a window (used to match it up again after a restart)
struct WindowIdentity: Codable {
	let bundleID: String
	let title: String
	let savedFrame: CGRect
}

/// Saved data for a single workspace
struct WorkspaceEntry: Codable {
	let number: Int
	let windows: [WindowIdentity]
	/// Column width ratios
	let columnWidthRatios: [CGFloat]?
	/// Row height ratios (keys are the string representation of the column index)
	let rowHeightRatios: [String: [CGFloat]]?
	/// Column structure (indices of the windows in each column, referring to positions in the `windows` array)
	let columnStructure: [[Int]]?
}

/// Saved data for a single monitor
struct ScreenState: Codable {
	let displayID: UInt32
	let activeWorkspace: Int
	let workspaces: [WorkspaceEntry]
}

/// The overall saved data
struct WorkspaceState: Codable {
	let screenStates: [ScreenState]
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
	let migratedWorkspaceNumbers: [Int]  // MacBook 側に新たに作られたワークスペース番号
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

	/// Whether it was restored from saved data at launch
	private(set) var didRestoreStateFromDisk: Bool = false

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

	    func allWindowsByWorkspace() -> [ScreenIdentifier: [Int: Set<CGWindowID>]] {

	        return workspaceWindows

	    }

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
		// Skip if it's already been restored from saved data, or if the initial setup is already complete
		// (So being called on every Space switch doesn't corrupt the workspace assignments)
		if didRestoreStateFromDisk || isInitialized {
			return
		}


		let allWindows = accessibilityManager.getAllWindows()
		let onScreenIDs = accessibilityManager.getOnScreenWindowIDs()

		let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0

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

				// Determine the screen from the window's center point
				let windowCenterX = window.frame.midX
				let windowCenterY = mainScreenHeight - window.frame.midY
				let windowCenter = CGPoint(x: windowCenterX, y: windowCenterY)

				let contains = screen.frame.contains(windowCenter)

				if contains {
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

			let centerX = window.frame.midX
			let centerY = mainScreenHeight - window.frame.midY
			let center = CGPoint(x: centerX, y: centerY)

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
	/// Reset didRestoreStateFromDisk and re-register every window to workspace 0
	func forceReinitialize() {

		// Clear the state
		didRestoreStateFromDisk = false
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

		// 11. Save the workspace state to a file
		saveStateToDisk()

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

	/// Move the focused window to a different workspace
	/// - Parameters:
	///   - windowID: the ID of the window being moved
	///   - workspace: the destination workspace number
	///   - screen: the target monitor
	///   - keepSwitchingFlag: if true, don't clear isSwitching (leave it to the subsequent switchWorkspace call)
	func moveWindowToWorkspace(_ windowID: CGWindowID, workspace: Int, on screen: NSScreen, keepSwitchingFlag: Bool = false) {
		let id = screenIdentifier(for: screen)
		let currentWS = activeWorkspace[id] ?? 0

		// Do nothing if it's the same workspace
		guard workspace != currentWS else { return }


		// Set the switching-in-progress flag
		isSwitching = true

		// Reset the cache since this is a user action
		resetClosedWindowsCache()

		// Remove the window from the current workspace
		workspaceWindows[id]?[currentWS]?.remove(windowID)

		// Create the destination workspace if it doesn't exist
		if workspaceWindows[id]?[workspace] == nil {
			if workspaceWindows[id] == nil {
				workspaceWindows[id] = [:]
			}
			workspaceWindows[id]?[workspace] = []
		}

		// Add the window to the destination workspace
		workspaceWindows[id]?[workspace]?.insert(windowID)

		// Also remove the window from TilingEngine's snapshot
		if var snapshot = tilingSnapshots[id]?[currentWS] {
			snapshot.columns = snapshot.columns.map { column in
				column.filter { $0 != windowID }
			}.filter { !$0.isEmpty }
			tilingSnapshots[id]?[currentWS] = snapshot
		}

		// Move the window off screen
		hideWindow(windowID)

		// Re-apply tiling on the current monitor
		tilingEngine.tile(on: screen)

        // Clean up once the original workspace becomes empty
        let prevActiveWS = activeWorkspace[id] ?? 0
        cleanupEmptyWorkspaces(on: screen)

        // Re-fetch it, since cleanup may have changed activeWorkspace
        let updatedCurrentWS = activeWorkspace[id] ?? 0

		// If cleanup automatically switched to the destination workspace,
		// Or if the active space changed because cleanup compacted the spaces,
		// Restore and tile windows that had been stashed off screen
		let focusedID: CGWindowID?
		if updatedCurrentWS == workspace || updatedCurrentWS != prevActiveWS {
			showWindowsForWorkspace(updatedCurrentWS, on: id)
			tilingEngine.tile(on: screen)
			// If the moved window is on the new active space, focus it
			if workspaceWindows[id]?[updatedCurrentWS]?.contains(windowID) == true {
				focusedID = focusWindow(windowID, in: updatedCurrentWS, on: id)
			} else {
				focusedID = focusFirstWindow(in: updatedCurrentWS, on: id)
			}
		} else {
			// Focus a window remaining in the original workspace
			focusedID = focusFirstWindow(in: updatedCurrentWS, on: id)
		}

		// Update the border and move the cursor to the center of the focused window
		syncBorderAndCursor(to: focusedID)

		// Update the menu bar
		NotificationCenter.default.post(name: .workspaceChanged, object: nil)

		// Save the workspace state to a file
		saveStateToDisk()

		// Clear the switching-in-progress flag after a short delay
		// If keepSwitchingFlag is true, the caller (switchWorkspace) clears it
		if !keepSwitchingFlag {
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
				self?.isSwitching = false
			}
		}
	}

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
	private enum HideCorner {
		case bottomLeft
		case bottomRight
	}

	/// Determine the best hidden corner for the given monitor
	/// Avoid the side that has a neighboring monitor
	private func optimalHideCorner(for screenID: ScreenIdentifier) -> HideCorner {
		guard let screen = screen(for: screenID) else {
			return .bottomLeft
		}

		let screenFrame = screen.frame

		// Check whether there's another monitor to the right
		var hasMonitorOnRight = false
		for otherScreen in NSScreen.screens {
			let otherId = screenIdentifier(for: otherScreen)
			if otherId == screenID { continue }

			// If another monitor's left edge is near this monitor's right edge, treat it as being "to the right"
			if otherScreen.frame.minX >= screenFrame.maxX - 10 {
				hasMonitorOnRight = true
				break
			}
		}

		// Bottom-left if there's a monitor to the right, otherwise bottom-right (default)
		return hasMonitorOnRight ? .bottomLeft : .bottomRight
	}

	/// Compute the position for hiding a window (AX coordinates: top-left origin, Y increases downward)
	/// Position it at the monitor's corner, leaving just 1 pixel inside the monitor
	private func hidePosition(for window: WindowInfo, corner: HideCorner, on screenID: ScreenIdentifier) -> CGPoint? {
		guard let screen = screen(for: screenID) else { return nil }

		// Convert NSScreen coordinates to AX coordinates
		// AX coordinate system: (0, 0) is top-left, Y increases downward
		// NSScreen coordinate system: the origin is bottom-left
		let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
		let visibleFrame = screen.visibleFrame

		// Convert visibleFrame to AX coordinates
		let axVisibleBottom = mainScreenHeight - visibleFrame.minY

		switch corner {
		case .bottomLeft:
			// Position it so the window's right edge sits 1px inside visibleFrame's left edge
			let x = visibleFrame.minX - window.frame.width + 1
			// Position it so the window's top edge sits 1px inside visibleFrame's bottom edge
			let y = axVisibleBottom - 1
			return CGPoint(x: x, y: y)

		case .bottomRight:
			// Position it so the window's left edge sits 1px inside visibleFrame's right edge
			let x = visibleFrame.maxX - 1
			// Position it so the window's top edge sits 1px inside visibleFrame's bottom edge
			let y = axVisibleBottom - 1
			return CGPoint(x: x, y: y)
		}
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
	/// Keeps the original workspace registration (after this document's revision). Axis's workspaces are
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

			// Restore TilingEngine's column structure (Bug fix: column order getting scrambled after reconnecting)
			// Since tiledWindows[E] has already been cleared by cleanupDisconnectedScreens(),
			// Calling tile() as-is would treat every window as "new" and break the ordering.
			// Rebuild TilingEngine's state from the restored tilingSnapshots.
			if let reconnectedScreen = screen(for: reconnectedScreenID),
			   let snapshot = tilingSnapshots[reconnectedScreenID]?[savedData.activeWorkspace] {
				tilingEngine.restoreTilingStateForScreen(reconnectedScreen, snapshot: snapshot)
			}

			// Delete the migrated workspace on the MacBook side
			let migTargetID = savedData.migratedToScreenID

			// Bug fix: if the migrated workspace was active on the MacBook side,
			// Fixes the issue where that workspace's windows stay visible.
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

			// Bug fix: the border disappearing issue
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

	// MARK: - Persisting workspace state

	/// The path to the save destination file
	private var stateFilePath: URL {
		let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		let axisDir = appSupport.appendingPathComponent("Axis")
		return axisDir.appendingPathComponent("workspaces.json")
	}

	/// Save the workspace state to a file
	func saveStateToDisk() {
		let allWindows = accessibilityManager.getAllWindows()
		// Build a dictionary of the windows getAllWindows can retrieve
		var windowDict: [CGWindowID: WindowInfo] = [:]
		for window in allWindows {
			windowDict[window.id] = window
			// Also update the cache of on-screen windows
			windowIdentityCache[window.id] = (
				bundleID: window.app.bundleIdentifier ?? "",
				title: window.title
			)
		}

		var screenStates: [ScreenState] = []
		var totalSavedWindows = 0

		for (screenID, workspaces) in workspaceWindows {
			var entries: [WorkspaceEntry] = []

			for (wsNumber, windowIDs) in workspaces.sorted(by: { $0.key < $1.key }) {
				var windowIdentities: [WindowIdentity] = []

				for windowID in windowIDs {
					// First use whatever windows getAllWindows could retrieve
					if let window = windowDict[windowID] {
						let frame = savedFrames[windowID] ?? window.frame
						let identity = WindowIdentity(
							bundleID: window.app.bundleIdentifier ?? "",
							title: window.title,
							savedFrame: frame
						)
						windowIdentities.append(identity)
					}
					// Fall back to the cache when getAllWindows fails to retrieve it
					else if let cached = windowIdentityCache[windowID] {
						let frame = savedFrames[windowID] ?? .zero
						let identity = WindowIdentity(
							bundleID: cached.bundleID,
							title: cached.title,
							savedFrame: frame
						)
						windowIdentities.append(identity)
					} else {
					}
				}

				// Get the ratios from the tiling snapshot
				let snapshot = tilingSnapshots[screenID]?[wsNumber]
				let colWidthRatios = snapshot?.columnWidthRatios

				// Convert rowHeightRatios' Int keys to String (JSON keys must be strings)
				var rowRatiosStringKeyed: [String: [CGFloat]]? = nil
				if let rowRatios = snapshot?.rowHeightRatios {
					rowRatiosStringKeyed = [:]
					for (key, value) in rowRatios {
						rowRatiosStringKeyed?[String(key)] = value
					}
				}

				// Save the column structure (so window ordering can be restored)
				var columnStructure: [[Int]]? = nil
				if let snapshot = snapshot {
					var structure: [[Int]] = []
					for column in snapshot.columns {
						var colIndices: [Int] = []
						for wid in column {
							// Find the matching index in windowIdentities
							let bundleID: String
							let title: String
							if let window = windowDict[wid] {
								bundleID = window.app.bundleIdentifier ?? ""
								title = window.title
							} else if let cached = windowIdentityCache[wid] {
								bundleID = cached.bundleID
								title = cached.title
							} else {
								continue
							}
							if let idx = windowIdentities.firstIndex(where: {
								$0.bundleID == bundleID && $0.title == title
							}) {
								colIndices.append(idx)
							}
						}
						if !colIndices.isEmpty {
							structure.append(colIndices)
						}
					}
					if !structure.isEmpty {
						columnStructure = structure
					}
				}

				totalSavedWindows += windowIdentities.count

				let entry = WorkspaceEntry(
					number: wsNumber,
					windows: windowIdentities,
					columnWidthRatios: colWidthRatios,
					rowHeightRatios: rowRatiosStringKeyed,
					columnStructure: columnStructure
				)
				entries.append(entry)
			}

			let screenState = ScreenState(
				displayID: screenID.displayID,
				activeWorkspace: activeWorkspace[screenID] ?? 0,
				workspaces: entries
			)
			screenStates.append(screenState)
		}

		let state = WorkspaceState(screenStates: screenStates)

		// Safeguard: if not a single window could be saved,
		// Don't overwrite good existing data with empty data
		if totalSavedWindows == 0 {
			return
		}

		do {
			// Create the directory if it doesn't exist
			let dir = stateFilePath.deletingLastPathComponent()
			try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

			let encoder = JSONEncoder()
			encoder.outputFormatting = .prettyPrinted
			let data = try encoder.encode(state)
			try data.write(to: stateFilePath)
		} catch {
		}
	}

	/// Restore the workspace state from a file
	/// - Returns: true if the restore succeeded
	@discardableResult
	func restoreStateFromDisk() -> Bool {
		guard FileManager.default.fileExists(atPath: stateFilePath.path) else {
			return false
		}

		do {
			let data = try Data(contentsOf: stateFilePath)
			let state = try JSONDecoder().decode(WorkspaceState.self, from: data)

			// Don't restore if the saved data has no windows at all
			let totalSavedWindows = state.screenStates.flatMap { $0.workspaces }.flatMap { $0.windows }.count
			guard totalSavedWindows > 0 else {
				return false
			}

			// Get all current windows (including ones hidden off-screen)
			let allWindows = accessibilityManager.getAllWindows()
			let managedWindows = allWindows.filter {
				$0.shouldBeManaged() && !$0.shouldFloat()
			}


			// --- Matching ---
			// Step 1: match by exact bundleID + title
			// Step 2: if not found by exact match, match on bundleID alone

			// Dictionary of bundleID+title -> [WindowInfo]
			var exactMatchPool: [String: [WindowInfo]] = [:]
			// Dictionary of bundleID -> [WindowInfo] (for step 2)
			var bundleIDPool: [String: [WindowInfo]] = [:]

			for window in managedWindows {
				let bundleID = window.app.bundleIdentifier ?? ""
				let exactKey = bundleID + "||" + window.title
				exactMatchPool[exactKey, default: []].append(window)
				bundleIDPool[bundleID, default: []].append(window)
			}

			// Track window IDs that have already been matched
			var assignedWindowIDs = Set<CGWindowID>()

			// Collect the match requests for every workspace
			struct MatchRequest {
				let screenID: ScreenIdentifier
				let wsNumber: Int
				let index: Int
				let identity: WindowIdentity
			}
			var matchRequests: [MatchRequest] = []

			for screenState in state.screenStates {
				let screenID = ScreenIdentifier(displayID: screenState.displayID)
				for entry in screenState.workspaces {
					for (index, identity) in entry.windows.enumerated() {
						matchRequests.append(MatchRequest(
							screenID: screenID, wsNumber: entry.number,
							index: index, identity: identity
						))
					}
				}
			}

			// Step 1: exact match
			var matchResults: [Int: WindowInfo] = [:] // matchRequests のインデックス -> WindowInfo
			for (reqIndex, req) in matchRequests.enumerated() {
				let exactKey = req.identity.bundleID + "||" + req.identity.title
				if var candidates = exactMatchPool[exactKey], !candidates.isEmpty {
					let window = candidates.removeFirst()
					exactMatchPool[exactKey] = candidates
					// Also remove from bundleIDPool
					if var bCandidates = bundleIDPool[req.identity.bundleID] {
						bCandidates.removeAll { $0.id == window.id }
						bundleIDPool[req.identity.bundleID] = bCandidates
					}
					matchResults[reqIndex] = window
					assignedWindowIDs.insert(window.id)
				}
			}

			// Step 2: match on bundleID alone (for what wasn't found by exact match)
			for (reqIndex, req) in matchRequests.enumerated() {
				guard matchResults[reqIndex] == nil else { continue }
				if var candidates = bundleIDPool[req.identity.bundleID], !candidates.isEmpty {
					// Pick from windows that haven't been assigned yet
					if let idx = candidates.firstIndex(where: { !assignedWindowIDs.contains($0.id) }) {
						let window = candidates[idx]
						candidates.remove(at: idx)
						bundleIDPool[req.identity.bundleID] = candidates
						matchResults[reqIndex] = window
						assignedWindowIDs.insert(window.id)
					}
				}
			}

			// Build the workspace using the match results
			for screenState in state.screenStates {
				let screenID = ScreenIdentifier(displayID: screenState.displayID)

				// Check whether this monitor is currently connected
				guard let screen = screen(for: screenID) else {
					continue
				}

				activeWorkspace[screenID] = screenState.activeWorkspace

				if workspaceWindows[screenID] == nil {
					workspaceWindows[screenID] = [:]
				}
				if tilingSnapshots[screenID] == nil {
					tilingSnapshots[screenID] = [:]
				}

				for entry in screenState.workspaces {
					var matchedWindowIDs = Set<CGWindowID>()
					var matchedByIndex: [Int: WindowInfo] = [:]

					// Look up the matchRequests corresponding to this entry
					for (reqIndex, req) in matchRequests.enumerated() {
						if req.screenID == screenID && req.wsNumber == entry.number {
							if let window = matchResults[reqIndex] {
								matchedWindowIDs.insert(window.id)
								matchedByIndex[req.index] = window
							}
						}
					}

					workspaceWindows[screenID]?[entry.number] = matchedWindowIDs

					// Restore the tiling ratios
					var rowRatiosIntKeyed: [Int: [CGFloat]]? = nil
					if let rowRatios = entry.rowHeightRatios {
						rowRatiosIntKeyed = [:]
						for (key, value) in rowRatios {
							if let intKey = Int(key) {
								rowRatiosIntKeyed?[intKey] = value
							}
						}
					}

					// Restore the column structure
					var restoredColumns: [[CGWindowID]] = []
					if let columnStructure = entry.columnStructure {
						for colIndices in columnStructure {
							var column: [CGWindowID] = []
							for idx in colIndices {
								if let window = matchedByIndex[idx] {
									column.append(window.id)
								}
							}
							if !column.isEmpty {
								restoredColumns.append(column)
							}
						}
					}

					// Also add windows that weren't part of the column structure
					let windowsInColumns = Set(restoredColumns.flatMap { $0 })
					let remainingWindows = matchedWindowIDs.subtracting(windowsInColumns)
					for wid in remainingWindows {
						restoredColumns.append([wid])
					}

					let snapshot = PerScreenSnapshot(
						columns: restoredColumns.isEmpty ? matchedWindowIDs.map { [$0] } : restoredColumns,
						columnWidthRatios: entry.columnWidthRatios,
						rowHeightRatios: rowRatiosIntKeyed
					)
					tilingSnapshots[screenID]?[entry.number] = snapshot

				}

				// Move windows outside the active workspace off-screen
				let activeWS = screenState.activeWorkspace
				for (wsNumber, windowIDs) in workspaceWindows[screenID] ?? [:] {
					guard wsNumber != activeWS else { continue }
					guard !windowIDs.isEmpty else { continue }

					let corner = optimalHideCorner(for: screenID)
					let savedEntry = screenState.workspaces.first { $0.number == wsNumber }

					for window in allWindows {
						guard windowIDs.contains(window.id) else { continue }

						// Record the previously saved original position into savedFrames
						let bundleID = window.app.bundleIdentifier ?? ""
						if let savedEntry = savedEntry,
						   let identity = savedEntry.windows.first(where: { $0.bundleID == bundleID }) {
							savedFrames[window.id] = identity.savedFrame
						} else {
							savedFrames[window.id] = window.frame
						}

						// Update the cache too
						windowIdentityCache[window.id] = (bundleID: bundleID, title: window.title)

						if let hidePos = hidePosition(for: window, corner: corner, on: screenID) {
							window.setPosition(hidePos)
						}
					}
				}

				// Restore the active workspace's tiling state into TilingEngine
				if let snapshot = tilingSnapshots[screenID]?[activeWS] {
					tilingEngine.restoreTilingStateForScreen(screen, snapshot: snapshot)
				}
			}

			// Place windows that couldn't be matched into workspace 0
			let unassignedWindows = managedWindows.filter { !assignedWindowIDs.contains($0.id) }
			if !unassignedWindows.isEmpty {

				let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
				for window in unassignedWindows {
					let centerX = window.frame.midX
					let centerY = mainScreenHeight - window.frame.midY
					let center = CGPoint(x: centerX, y: centerY)

					for screen in NSScreen.screens {
						if screen.frame.contains(center) {
							let screenID = screenIdentifier(for: screen)
							if workspaceWindows[screenID] == nil {
								workspaceWindows[screenID] = [:]
							}
							if workspaceWindows[screenID]?[0] == nil {
								workspaceWindows[screenID]?[0] = []
							}
							workspaceWindows[screenID]?[0]?.insert(window.id)
							break
						}
					}
				}
			}

			let totalMatched = assignedWindowIDs.count
			didRestoreStateFromDisk = totalMatched > 0
			return totalMatched > 0

		} catch {
			didRestoreStateFromDisk = false
			return false
		}
	}

}

// MARK: - Notification Names

extension Notification.Name {
	static let workspaceChanged = Notification.Name("workspaceChanged")
}
