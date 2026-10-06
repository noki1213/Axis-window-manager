//
//  Classifier.swift
//  Axis
//
//  Decides once, at admission, how a new window is managed: ignored (helpers, non-windows, Axis
//  itself), unmanaged (dialogs, small panels, settings windows) or tiled. Tracked windows are
//  never re-classified, so a window does not flip between tiled and floating as layouts resize it.
//
//  Placeholder body: the classification rules are not implemented yet.
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
	static func classify(_ facts: WindowFacts, bundleID: String?, ownPID: PID, relaunchTiled: Set<WindowID>) -> WindowClass {
		facts.pid == ownPID || facts.role != AXNames.windowRole ? .ignore : .tiled
	}
}
