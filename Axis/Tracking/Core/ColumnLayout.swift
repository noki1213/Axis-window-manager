//
//  ColumnLayout.swift
//  Axis
//
//  The tiling math: slot frames for a workspace's drawable columns on a monitor's visible area,
//  with width and row ratios, gaps and padding, and the phantom slot of a placement reservation.
//  Frames are global and top-left based.
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
	/// Even-split slot frames for columns of the given sizes, each kept inside the padded visible
	/// area. A column of size 0 keeps its share of the width but has no slots.
	static func slotFrames(columnSizes: [Int], visibleFrame: CGRect, config: LayoutConfig) -> [[CGRect]] {
		guard !columnSizes.isEmpty else { return [] }
		let gap = config.gap
		let padding = config.padding
		let columnCount = CGFloat(columnSizes.count)

		let totalColumnGaps = gap * (columnCount - 1)
		let availableWidth = visibleFrame.width - (padding * 2) - totalColumnGaps
		let columnWidth = availableWidth / columnCount

		var currentX = visibleFrame.minX + padding
		var result: [[CGRect]] = []
		for count in columnSizes {
			guard count > 0 else {
				result.append([])
				currentX += columnWidth + gap
				continue
			}
			let rowCount = CGFloat(count)
			let totalRowGaps = gap * (rowCount - 1)
			let availableHeight = visibleFrame.height - (padding * 2) - totalRowGaps

			var currentY = visibleFrame.minY + padding
			var columnFrames: [CGRect] = []
			for _ in 0..<count {
				let rowHeight = availableHeight / rowCount
				let frame = CGRect(x: currentX, y: currentY, width: columnWidth, height: rowHeight)
				columnFrames.append(fitted(frame, visibleFrame: visibleFrame, padding: padding))
				currentY += rowHeight + gap
			}
			result.append(columnFrames)
			currentX += columnWidth + gap
		}
		return result
	}

	/// Slot frames of the drawable columns in `input`. `reservation` is passed only when it
	/// targets this workspace's monitor.
	///
	/// Ratios are normalized here: width ratios matching the column count are used with the row
	/// ratios that still match their column; when the widths do not match but some column's row
	/// ratios do, the widths are even for this layout while the stored width ratios stay as they
	/// are (they apply again once the column count returns to theirs); otherwise both reset to an
	/// even split. Nothing drawable leaves the ratios untouched, so a trip of every window to
	/// another Space keeps them.
	static func frames(for input: LayoutInput, visibleFrame: CGRect, config: LayoutConfig,
		reservation: PlacementReservation?) -> LayoutResult {
		if let reservation, reservation.kind != .float {
			return reservedLayout(input, kind: reservation.kind, columnIndex: reservation.columnIndex,
				visibleFrame: visibleFrame, config: config)
		}
		let columns = input.columns
		guard !columns.isEmpty else {
			return LayoutResult(widthRatios: input.widthRatios, rowRatios: input.rowRatios)
		}

		if let ratios = input.widthRatios, ratios.count == columns.count {
			return ratioLayout(columns, widthRatios: ratios, storedWidthRatios: ratios, rowRatios: input.rowRatios,
				visibleFrame: visibleFrame, config: config)
		}

		if !input.rowRatios.isEmpty {
			let hasValidRowRatio = columns.indices.contains { columnIndex in
				if let ratios = input.rowRatios[columnIndex], ratios.count == columns[columnIndex].count {
					return true
				}
				return false
			}
			if hasValidRowRatio {
				let evenRatios = Array(repeating: 1.0 / CGFloat(columns.count), count: columns.count)
				return ratioLayout(columns, widthRatios: evenRatios, storedWidthRatios: input.widthRatios,
					rowRatios: input.rowRatios, visibleFrame: visibleFrame, config: config)
			}
		}

		let slots = slotFrames(columnSizes: columns.map { $0.count }, visibleFrame: visibleFrame, config: config)
		var frames: [WindowID: CGRect] = [:]
		for (columnIndex, column) in columns.enumerated() {
			guard columnIndex < slots.count else { continue }
			for (rowIndex, id) in column.enumerated() {
				guard rowIndex < slots[columnIndex].count else { continue }
				frames[id] = slots[columnIndex][rowIndex]
			}
		}
		return LayoutResult(frames: frames, widthRatios: nil, rowRatios: [:])
	}

	/// Frames from width ratios (one per column, same count) and the stored row ratios. Row ratios
	/// of a column whose window count changed are dropped; entries for columns past the end stay.
	private static func ratioLayout(_ columns: [[WindowID]], widthRatios: [CGFloat], storedWidthRatios: [CGFloat]?,
		rowRatios storedRowRatios: [Int: [CGFloat]], visibleFrame: CGRect, config: LayoutConfig) -> LayoutResult {
		var rowRatios = storedRowRatios
		for (columnIndex, column) in columns.enumerated() {
			if let ratios = rowRatios[columnIndex], ratios.count != column.count {
				rowRatios[columnIndex] = nil
			}
		}

		let gap = config.gap
		let padding = config.padding
		let columnCount = CGFloat(columns.count)
		let totalColumnGaps = gap * (columnCount - 1)
		let availableWidth = visibleFrame.width - (padding * 2) - totalColumnGaps

		var currentX = visibleFrame.minX + padding
		var frames: [WindowID: CGRect] = [:]
		for (columnIndex, column) in columns.enumerated() {
			guard !column.isEmpty else { continue }
			let columnWidth = availableWidth * widthRatios[columnIndex]
			let columnRowRatios = rowRatios[columnIndex] ?? Array(repeating: 1.0 / CGFloat(column.count), count: column.count)

			let rowCount = CGFloat(column.count)
			let totalRowGaps = gap * (rowCount - 1)
			let availableHeight = visibleFrame.height - (padding * 2) - totalRowGaps

			var currentY = visibleFrame.minY + padding
			for (rowIndex, id) in column.enumerated() {
				let rowHeight: CGFloat
				if rowIndex < columnRowRatios.count {
					rowHeight = availableHeight * columnRowRatios[rowIndex]
				} else {
					rowHeight = availableHeight / rowCount
				}
				let frame = CGRect(x: currentX, y: currentY, width: columnWidth, height: rowHeight)
				frames[id] = fitted(frame, visibleFrame: visibleFrame, padding: padding)
				currentY += rowHeight + gap
			}
			currentX += columnWidth + gap
		}
		return LayoutResult(frames: frames, widthRatios: storedWidthRatios, rowRatios: rowRatios)
	}

	/// The layout with a phantom slot where the next window will go: an even split of the columns
	/// with the slot added, the existing windows moved into the other slots. The ratios are left
	/// as they are; the layout after the window arrives normalizes them. With no drawable column
	/// the slot covers the whole padded area.
	private static func reservedLayout(_ input: LayoutInput, kind: ReservationKind, columnIndex: Int,
		visibleFrame: CGRect, config: LayoutConfig) -> LayoutResult {
		let columns = input.columns
		var result = LayoutResult(widthRatios: input.widthRatios, rowRatios: input.rowRatios)

		if columns.isEmpty || columns.allSatisfy({ $0.isEmpty }) {
			result.reservedSlot = slotFrames(columnSizes: [1], visibleFrame: visibleFrame, config: config).first?.first
			return result
		}

		var columnSizes = columns.map { $0.count }
		var reservedColumn = 0
		var reservedRow = 0
		switch kind {
		case .aboveInColumn:
			let column = min(max(columnIndex, 0), columns.count - 1)
			columnSizes[column] += 1
			reservedColumn = column
			reservedRow = 0
		case .belowInColumn:
			let column = min(max(columnIndex, 0), columns.count - 1)
			columnSizes[column] += 1
			reservedColumn = column
			reservedRow = columnSizes[column] - 1
		case .newColumnLeft:
			let column = min(max(columnIndex, 0), columns.count)
			columnSizes.insert(1, at: column)
			reservedColumn = column
			reservedRow = 0
		case .newColumnRight:
			let column = min(max(columnIndex + 1, 0), columns.count)
			columnSizes.insert(1, at: column)
			reservedColumn = column
			reservedRow = 0
		case .float:
			return result
		}

		let slots = slotFrames(columnSizes: columnSizes, visibleFrame: visibleFrame, config: config)
		guard reservedColumn < slots.count, reservedRow < slots[reservedColumn].count else { return result }
		result.reservedSlot = slots[reservedColumn][reservedRow]

		for (columnIndex, column) in columns.enumerated() {
			let targetColumn: Int
			switch kind {
			case .aboveInColumn, .belowInColumn:
				targetColumn = columnIndex
			case .newColumnLeft, .newColumnRight:
				targetColumn = columnIndex >= reservedColumn ? columnIndex + 1 : columnIndex
			case .float:
				continue
			}
			for (rowIndex, id) in column.enumerated() {
				let targetRow = kind == .aboveInColumn && columnIndex == reservedColumn ? rowIndex + 1 : rowIndex
				guard targetColumn < slots.count, targetRow < slots[targetColumn].count else { continue }
				result.frames[id] = slots[targetColumn][targetRow]
			}
		}
		return result
	}

	/// Moves a slot back inside the padded visible area: ratios adding up to more than 1 would push
	/// it past the right or bottom edge. A slot wider than the area stays at its left edge.
	private static func fitted(_ frame: CGRect, visibleFrame: CGRect, padding: CGFloat) -> CGRect {
		var adjusted = frame

		if adjusted.minX < visibleFrame.minX + padding {
			adjusted.origin.x = visibleFrame.minX + padding
		}
		let rightEdge = visibleFrame.maxX - padding
		if adjusted.maxX > rightEdge {
			adjusted.origin.x = rightEdge - adjusted.width
			if adjusted.minX < visibleFrame.minX + padding {
				adjusted.origin.x = visibleFrame.minX + padding
			}
		}

		let bottomEdge = visibleFrame.maxY
		let frameBottom = adjusted.origin.y + adjusted.height
		if frameBottom > bottomEdge - padding {
			adjusted.origin.y = bottomEdge - padding - adjusted.height
		}
		let topEdge = visibleFrame.minY + padding
		if adjusted.origin.y < topEdge {
			adjusted.origin.y = topEdge
		}

		return adjusted
	}
}
