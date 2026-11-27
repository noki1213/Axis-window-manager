//
//  ScreenCoordinates.swift
//  Axis
//
//  ScreenFlip against the live primary display.
//

import AppKit

extension ScreenFlip {
	/// The height of the primary display, or nil while no screen is attached.
	@MainActor static var primaryHeight: CGFloat? { NSScreen.screens.first?.frame.height }

	/// Flips with the live primary height; 0 when no screen is attached.
	@MainActor static func point(_ p: CGPoint) -> CGPoint {
		point(p, primaryHeight: primaryHeight ?? 0)
	}

	@MainActor static func rect(_ r: CGRect) -> CGRect {
		rect(r, primaryHeight: primaryHeight ?? 0)
	}
}
