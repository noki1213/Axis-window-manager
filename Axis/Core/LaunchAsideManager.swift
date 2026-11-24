import AppKit

/// Opens an app so that its windows land on an empty workspace of their own,
/// out of sight, instead of joining the workspace on screen. Reached through
/// `axis://launch-aside?path=<app>`: a build script relaunching the app it just
/// built would otherwise drop a window into the middle of someone's layout.
///
/// The workspace on screen, its tiling and the keyboard focus all stay where
/// they were; the new workspace is the first empty one past the last in use.
/// The tracking state keeps the app's entry and places its windows as they
/// are admitted; this manager starts the launch and hands focus back.
final class LaunchAsideManager {
	static let shared = LaunchAsideManager()

	/// The app that had focus when the launch was asked for.
	private var previousApp: NSRunningApplication?

	private var coordinator: TrackingCoordinator { TrackingCoordinator.shared }

	/// Launch the app at `url`, its windows bound for an empty workspace on `screen`.
	func launch(appAt url: URL, on screen: NSScreen?) {
		// The URL scheme can be called by any app or web page, so nothing but an app is opened:
		// any other path would run a script or open a document with its default handler
		guard url.pathExtension == "app", let bundleID = Bundle(url: url)?.bundleIdentifier else {
			PerfLog.event("launch-aside: not an app, ignored")
			return
		}
		guard let screen = screen ?? NSScreen.main,
		      let monitor = WorkspaceManager.shared.monitorKey(for: screen),
		      coordinator.isRunning
		else {
			NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
			return
		}
		if let front = NSWorkspace.shared.frontmostApplication,
		   front.bundleIdentifier != bundleID,
		   front.bundleIdentifier != Bundle.main.bundleIdentifier {
			previousApp = front
		} else {
			// No app to hand focus back to; the one remembered from an earlier launch isn't it
			previousApp = nil
		}
		let now = ProcessInfo.processInfo.systemUptime
		coordinator.note { state in
			state.registerLaunchAside(bundleID: bundleID, monitor: monitor, now: now)
		}
		PerfLog.event("launch-aside: \(bundleID) -> \(PerfLog.describe(screen))")

		let configuration = NSWorkspace.OpenConfiguration()
		configuration.activates = false
		NSWorkspace.shared.openApplication(at: url, configuration: configuration)
	}

	/// Whether focus landing on a window of the app `bundleID` should be sent
	/// back rather than followed to its workspace: true just after one of its
	/// windows was set aside. Hands focus back as a side effect.
	func holdsFocus(bundleID: String) -> Bool {
		guard let until = coordinator.state.launchAside[bundleID]?.holdFocusUntil,
		      until > ProcessInfo.processInfo.systemUptime
		else { return false }
		returnFocus(ifTakenBy: bundleID)
		return true
	}

	/// Gives focus back to the app that had it when the launch was asked for,
	/// if the app launched aside has taken it.
	func returnFocus(ifTakenBy bundleID: String) {
		guard let previousApp, !previousApp.isTerminated,
		      NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
		else { return }
		NSApp.yieldActivation(to: previousApp)
		previousApp.activate()
	}
}
