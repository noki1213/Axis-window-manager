//
//  ScreenFlip.swift
//  Axis
//
//  The vertical flip between the two screen coordinate systems: Accessibility and CoreGraphics
//  put the origin at the top-left of the primary display, Cocoa at its bottom-left.
//

import Foundation
import CoreGraphics

/// The flip is its own inverse, so the same call converts in either direction.
/// `primaryHeight` is the height of the primary display, the one holding the menu bar
/// (`NSScreen.screens.first`).
nonisolated enum ScreenFlip {
	static func point(_ p: CGPoint, primaryHeight: CGFloat) -> CGPoint {
		CGPoint(x: p.x, y: primaryHeight - p.y)
	}

	/// The size is unchanged; the top edge becomes the bottom edge and the other way round.
	static func rect(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
		CGRect(x: r.origin.x, y: primaryHeight - r.origin.y - r.height, width: r.width, height: r.height)
	}
}
