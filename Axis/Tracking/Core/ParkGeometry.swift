//
//  ParkGeometry.swift
//  Axis
//
//  Where parked windows go: past a bottom corner of their monitor with a sliver left on screen
//  (macOS pulls a window that is entirely off screen back into view), on the side facing away
//  from neighbouring monitors; and whether an observed frame counts as out of sight.
//
//  Placeholder bodies: the corner choice and the hidden test are not implemented yet; the
//  origin follows the existing hide corner.
//

import Foundation
import CoreGraphics

nonisolated enum ParkCorner: Hashable, Sendable {
	case bottomLeft
	case bottomRight
}

nonisolated enum ParkGeometry {
	/// The corner of `monitor` to park at, given every connected monitor.
	static func corner(for monitor: MonitorState, monitors: [MonitorState]) -> ParkCorner {
		.bottomRight
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

	/// Whether a window at `frame` is out of sight on every monitor.
	static func isEffectivelyHidden(_ frame: CGRect, monitors: [MonitorState]) -> Bool {
		false
	}
}
