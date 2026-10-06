//
//  ParkGeometry.swift
//  Axis
//
//  Where parked windows go: past a bottom corner of their monitor with a sliver left on screen
//  (macOS pulls a window that is entirely off screen back into view), on the side facing away
//  from neighbouring monitors; and whether an observed frame counts as out of sight.
//

import Foundation
import CoreGraphics

nonisolated enum ParkCorner: Hashable, Sendable {
	case bottomLeft
	case bottomRight
}

nonisolated enum ParkGeometry {
	/// An overlap with a visible area at most this wide or high does not show the window: the
	/// 1 pt sliver a parked window keeps, or a sliver macOS nudged a little.
	static let hiddenTolerance: CGFloat = 2

	/// A monitor whose left edge is at least this far right of another's right edge counts as
	/// lying to its right.
	static let rightNeighbourSlack: CGFloat = 10

	/// The corner of `monitor` to park at, given every connected monitor. The bottom-right corner,
	/// or the bottom-left one when a monitor lies to the right. A corner whose parked windows would
	/// show on another monitor (one below, or one reaching past the side) gives way to the other
	/// corner when that one shows less. A parked window is assumed as large as the monitor.
	static func corner(for monitor: MonitorState, monitors: [MonitorState]) -> ParkCorner {
		let others = monitors.filter { $0.key != monitor.key }
		let hasMonitorOnRight = others.contains { $0.frame.minX >= monitor.frame.maxX - rightNeighbourSlack }
		let preferred: ParkCorner = hasMonitorOnRight ? .bottomLeft : .bottomRight
		let preferredOverlap = shownArea(parkedAt: preferred, on: monitor, others: others)
		guard preferredOverlap > 0 else { return preferred }
		let alternative: ParkCorner = preferred == .bottomLeft ? .bottomRight : .bottomLeft
		return shownArea(parkedAt: alternative, on: monitor, others: others) < preferredOverlap ? alternative : preferred
	}

	/// The top-left point of a parked window of `size`: its top edge 1 pt above the visible area's
	/// bottom edge and 1 pt of it inside the visible area horizontally.
	static func parkOrigin(size: CGSize, visibleFrame: CGRect, corner: ParkCorner) -> CGPoint {
		let y = visibleFrame.maxY - 1
		switch corner {
		case .bottomLeft: return CGPoint(x: visibleFrame.minX - size.width + 1, y: y)
		case .bottomRight: return CGPoint(x: visibleFrame.maxX - 1, y: y)
		}
	}

	/// Whether a window at `frame` is out of sight on every monitor: its overlap with each visible
	/// area is empty or a sliver. The Dock and menu bar strips outside a visible area do not count.
	static func isEffectivelyHidden(_ frame: CGRect, monitors: [MonitorState]) -> Bool {
		!monitors.contains { shownArea(of: frame, in: $0.visibleFrame) > 0 }
	}

	/// How much of a monitor-sized window parked at `corner` lies on the other monitors.
	private static func shownArea(parkedAt corner: ParkCorner, on monitor: MonitorState, others: [MonitorState]) -> CGFloat {
		let size = monitor.frame.size
		let parked = CGRect(origin: parkOrigin(size: size, visibleFrame: monitor.visibleFrame, corner: corner), size: size)
		return others.reduce(0) { $0 + shownArea(of: parked, in: $1.frame) }
	}

	/// The area of `frame` inside `area`, zero when the overlap is only a sliver.
	private static func shownArea(of frame: CGRect, in area: CGRect) -> CGFloat {
		let overlap = frame.intersection(area)
		guard !overlap.isNull, overlap.width > hiddenTolerance, overlap.height > hiddenTolerance else { return 0 }
		return overlap.width * overlap.height
	}
}
