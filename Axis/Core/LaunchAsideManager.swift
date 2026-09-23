import AppKit

/// Opens an app so that its windows land on an empty workspace of their own,
/// out of sight, instead of joining the workspace on screen. Reached through
/// `axis://launch-aside?path=<app>`: a build script relaunching the app it just
/// built would otherwise drop a window into the middle of someone's layout.
///
/// The workspace on screen, its tiling and the keyboard focus all stay where
/// they were; the new workspace is the first empty one past the last in use.
final class LaunchAsideManager {
	static let shared = LaunchAsideManager()

	/// How long after the launch the app's new windows are still caught.
	private static let claimInterval: TimeInterval = 20
	/// How long after a window is caught its app is kept from taking focus.
	/// Launched apps activate themselves a moment after their first window.
	private static let focusHoldInterval: TimeInterval = 3

	private struct Pending {
		let screen: NSScreen
		let deadline: Date
		/// Chosen when the first window arrives, so later windows join it.
		var workspace: Int?
		var holdFocusUntil: Date?
	}

	/// Keyed by bundle identifier.
	private var pending: [String: Pending] = [:]
	/// The app that had focus when the launch was asked for.
	private var previousApp: NSRunningApplication?

	/// Launch the app at `url`, its windows bound for an empty workspace on `screen`.
	func launch(appAt url: URL, on screen: NSScreen?) {
		guard let bundleID = Bundle(url: url)?.bundleIdentifier,
		      let screen = screen ?? NSScreen.main
		else {
			NSWorkspace.shared.open(url)
			return
		}
		if let front = NSWorkspace.shared.frontmostApplication,
		   front.bundleIdentifier != bundleID,
		   front.bundleIdentifier != Bundle.main.bundleIdentifier {
			previousApp = front
		}
		pending[bundleID] = Pending(screen: screen, deadline: Date().addingTimeInterval(Self.claimInterval))
		PerfLog.event("launch-aside: \(bundleID) -> \(PerfLog.describe(screen))")

		let configuration = NSWorkspace.OpenConfiguration()
		configuration.activates = false
		NSWorkspace.shared.openApplication(at: url, configuration: configuration)
	}

	/// Take a newly appeared window when its app was launched aside: register
	/// it on the set-aside workspace and move it out of sight. True when taken.
	func claim(_ window: WindowInfo, workspaces: WorkspaceManager) -> Bool {
		guard let bundleID = window.app.bundleIdentifier, var entry = pending[bundleID] else { return false }
		guard entry.deadline > Date() else {
			pending[bundleID] = nil
			return false
		}
		let workspace = entry.workspace ?? workspaces.firstUnusedWorkspace(on: entry.screen)
		entry.workspace = workspace
		entry.holdFocusUntil = Date().addingTimeInterval(Self.focusHoldInterval)
		pending[bundleID] = entry

		PerfLog.event("launch-aside: \(PerfLog.describe(window)) -> ws\(workspace + 1)")
		workspaces.registerWindowOutOfSight(window.id, on: entry.screen, workspace: workspace)
		returnFocus(ifTakenBy: bundleID)
		return true
	}

	/// Whether focus landing on `window` should be sent back rather than followed
	/// to its workspace: true just after its app's window was set aside. Hands
	/// focus back as a side effect.
	func holdsFocus(from window: WindowInfo) -> Bool {
		guard let bundleID = window.app.bundleIdentifier,
		      let until = pending[bundleID]?.holdFocusUntil,
		      until > Date()
		else { return false }
		returnFocus(ifTakenBy: bundleID)
		return true
	}

	private func returnFocus(ifTakenBy bundleID: String) {
		guard let previousApp, !previousApp.isTerminated,
		      NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
		else { return }
		NSApp.yieldActivation(to: previousApp)
		previousApp.activate()
	}
}
