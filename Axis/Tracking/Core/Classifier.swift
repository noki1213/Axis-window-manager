//
//  Classifier.swift
//  Axis
//
//  Decides once, at admission, how a new window is managed: ignored (helpers, non-windows, Axis
//  itself), unmanaged (dialogs, small panels, settings windows) or tiled. Tracked windows are
//  never re-classified, so a window does not flip between tiled and floating as layouts resize it.
//

import Foundation
import CoreGraphics

nonisolated enum WindowClass: Hashable, Sendable {
	/// Never tracked.
	case ignore
	/// Tracked without a workspace.
	case unmanaged
	case tiled
}

nonisolated enum Classifier {
	/// System Settings shows fixed-size panes that do not tile (older and newer bundle ids).
	static let settingsBundleIDs: Set<String> = [
		"com.apple.systempreferences",
		"com.apple.SystemPreferences",
		"com.apple.systemsettings",
		"com.apple.SystemSettings",
	]

	/// Subroles of real windows that are tracked but never tiled.
	static let unmanagedSubroles: Set<String> = [
		AXNames.dialogSubrole,
		AXNames.systemDialogSubrole,
		AXNames.floatingWindowSubrole,
	]

	/// A new window smaller than this in both directions starts out unmanaged: dialogs and utility
	/// panels often report the standard subrole.
	static let smallWindowSize = CGSize(width: 500, height: 500)

	/// `relaunchTiled` holds windows that were tiled when Axis last quit: a stacked column may have
	/// left them small enough to look like dialogs.
	static func classify(_ facts: WindowFacts, bundleID: String?, ownPID: PID, relaunchTiled: Set<WindowID>) -> WindowClass {
		guard facts.pid != ownPID, facts.role == AXNames.windowRole else { return .ignore }
		let isStandard = facts.subrole == AXNames.standardWindowSubrole
		let isUnmanagedKind = facts.subrole.map { unmanagedSubroles.contains($0) } ?? false
		// Helper windows (invisible 1x1 windows, tooltips, internal panes) have neither the standard
		// subrole nor a close button. A close button marks a document window even when the app
		// reports a non-standard subrole.
		guard isStandard || facts.hasCloseButton || isUnmanagedKind else { return .ignore }
		if isUnmanagedKind {
			return .unmanaged
		}
		if let bundleID, settingsBundleIDs.contains(bundleID) {
			return .unmanaged
		}
		if facts.frame.width < smallWindowSize.width && facts.frame.height < smallWindowSize.height
			&& !relaunchTiled.contains(facts.id) {
			return .unmanaged
		}
		return .tiled
	}
}
