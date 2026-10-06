//
//  ColumnLayout.swift
//  Axis
//
//  The tiling math: slot frames for a workspace's drawable columns on a monitor's visible area,
//  with width and row ratios, gaps and padding, and the phantom slot of a placement reservation.
//  Frames are global and top-left based.
//
//  Placeholder bodies: the layout math is not implemented yet.
//

import Foundation
import CoreGraphics

/// Slot frames for one workspace and the ratios to store back after normalization.
nonisolated struct LayoutResult: Equatable, Sendable {
	var frames: [WindowID: CGRect]
	/// Width ratios after normalization (nil = even); stored back on the workspace.
	var widthRatios: [CGFloat]?
	/// Row ratios after normalization; stored back on the workspace.
	var rowRatios: [Int: [CGFloat]]
	/// The reserved slot of a placement reservation on this workspace.
	var reservedSlot: CGRect?

	init(frames: [WindowID: CGRect] = [:], widthRatios: [CGFloat]? = nil, rowRatios: [Int: [CGFloat]] = [:], reservedSlot: CGRect? = nil) {
		self.frames = frames
		self.widthRatios = widthRatios
		self.rowRatios = rowRatios
		self.reservedSlot = reservedSlot
	}
}

nonisolated enum ColumnLayout {
	/// Even-split slot frames for columns of the given sizes.
	static func slotFrames(columnSizes: [Int], visibleFrame: CGRect, config: LayoutConfig) -> [[CGRect]] {
		[]
	}

	/// Slot frames of the drawable columns in `input`. `reservation` is passed only when it
	/// targets this workspace's monitor.
	static func frames(for input: LayoutInput, visibleFrame: CGRect, config: LayoutConfig,
		reservation: PlacementReservation?) -> LayoutResult {
		LayoutResult(widthRatios: input.widthRatios, rowRatios: input.rowRatios)
	}
}
