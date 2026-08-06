//
//  GapSelectManager.swift
//  Axis
//
//  Created on 2026/01/27.
//

import AppKit
import Combine

/// The kind of gap
enum GapType {
	/// The gap between columns (vertical line) - can be moved left/right
	case vertical
	/// The gap between rows (horizontal line) - can be moved up/down
	case horizontal
}

/// Information about the gap
struct GapInfo: Equatable {
	let type: GapType
	/// The gap's position (a column index or row index)
	/// vertical: the index of the left column (0 = between column 0 and column 1)
	/// horizontal: (column index, the row index of the window above)
	let columnIndex: Int
	let rowIndex: Int? // horizontal の場合のみ使用
	/// The gap's on-screen rect (where the line is drawn)
	var frame: CGRect

	static func == (lhs: GapInfo, rhs: GapInfo) -> Bool {
		lhs.type == rhs.type && lhs.columnIndex == rhs.columnIndex && lhs.rowIndex == rhs.rowIndex
	}
}

/// Manages the new gap mode
/// Directly moves the four edges (left, right, top, bottom) of the focused window.
/// While in this mode, each key immediately switches which edge is being adjusted, allowing continuous adjustment.
class GapSelectManager: ObservableObject {
	static let shared = GapSelectManager()

	// MARK: - Published Properties

	/// Whether the new gap mode is active
	var isActive: Bool {
		return !availableGaps.isEmpty
	}

	/// Every gap that can be moved on the current screen
	@Published var availableGaps: [GapInfo] = []

	/// The gap index corresponding to the edge currently being operated on (nil if no edge has been touched yet)
	@Published var currentGapIndex: Int? = nil

	/// The gap indices for edges the focused window can actually move (used for candidate display)
	@Published var candidateGapIndices: [Int] = []

	// MARK: - Dependencies

	private let tilingEngine = TilingEngine.shared
	private var overlayWindow: GapOverlayWindow?

	private init() {}

	// MARK: - Public Methods

	/// Start the new gap mode
	func startGapSelectMode() {
		guard let screen = getCurrentScreen() else { return }

		calculateGaps(for: screen)
		guard !availableGaps.isEmpty else { return }

		currentGapIndex = nil
		updateCandidateGapIndices(on: screen)

		// Show the overlay (no highlight yet, since no edge has been touched)
		showOverlay(on: screen)

		// Update the focus border (hide it)
		BorderManager.shared.updateBorder()
	}

	/// End the new gap mode
	func endGapSelectMode() {
		hideOverlay()

		availableGaps = []
		currentGapIndex = nil
		candidateGapIndices = []

		// Update the focus border (show it again)
		BorderManager.shared.updateBorder()
	}

	/// Move the focused window's given edge.
	/// - Parameters:
	///   - edge: the edge to move (left/right/up/down)
	///   - widen: true = move the edge outward to grow the window, false = move it inward to shrink it
	func resizeFocusedEdge(_ edge: Direction, widen: Bool) {
		guard let screen = getCurrentScreen() else { return }

		// Bring the gaps up to date
		calculateGaps(for: screen)
		guard !availableGaps.isEmpty else { return }

		// Find the focused window's position and the gap corresponding to the given edge
		guard let (colIndex, rowIndex) = focusedWindowPosition(on: screen) else { return }

		// Do nothing if it's flush against the screen edge and there's no corresponding gap
		guard let index = findGapIndex(edge: edge, colIndex: colIndex, rowIndex: rowIndex) else { return }

		currentGapIndex = index
		updateCandidateGapIndices(on: screen)
		let gap = availableGaps[index]

		// Movement amount (pixels)
		let moveAmount: CGFloat = 50

		// Convert widen/shrink into the gap's actual direction of movement
		let moveDirection: Direction
		switch edge {
		case .left:  moveDirection = widen ? .left : .right
		case .right: moveDirection = widen ? .right : .left
		case .up:    moveDirection = widen ? .up : .down
		case .down:  moveDirection = widen ? .down : .up
		}

		switch gap.type {
		case .vertical:
			let delta = moveDirection == .left ? -moveAmount : moveAmount
			tilingEngine.resizeColumnGap(at: gap.columnIndex, delta: delta, on: screen)

		case .horizontal:
			guard let gapRowIndex = gap.rowIndex else { return }
			let delta = moveDirection == .up ? -moveAmount : moveAmount
			tilingEngine.resizeRowGap(columnIndex: gap.columnIndex, rowIndex: gapRowIndex, delta: delta, on: screen)
		}

		// Recompute the gaps and update the overlay
		// (Since the column/row layout doesn't change, it stays consistent at the same index)
		calculateGaps(for: screen)
		updateOverlay()
	}

	// MARK: - Private Methods

	/// Get the focused window's tiling position (column index, row index)
	private func focusedWindowPosition(on screen: NSScreen) -> (Int, Int)? {
		guard var focusedWindow = AccessibilityManager.shared.getFocusedWindow() else { return nil }
		focusedWindow.refreshFrame()

		let columns = tilingEngine.tiledWindows[ScreenIdentifier(from: screen)] ?? []
		guard columns.count > 0 else { return nil }

		return tilingEngine.findWindowPosition(window: focusedWindow, in: columns)
	}

	/// Find the gap index corresponding to the focused window's given edge.
	/// Returns nil for an edge that's flush against the screen edge with no corresponding gap.
	private func findGapIndex(edge: Direction, colIndex: Int, rowIndex: Int) -> Int? {
		for (index, gap) in availableGaps.enumerated() {
			switch edge {
			case .left:
				// Vertical gap to the left of this column (colIndex), at index colIndex - 1
				if gap.type == .vertical && gap.columnIndex == colIndex - 1 { return index }
			case .right:
				// Vertical gap to the right of this column (colIndex), at index colIndex
				if gap.type == .vertical && gap.columnIndex == colIndex { return index }
			case .up:
				// Horizontal gap between this row and the one above it (rowIndex - 1), at index rowIndex - 1
				if gap.type == .horizontal && gap.columnIndex == colIndex && gap.rowIndex == rowIndex - 1 { return index }
			case .down:
				// Horizontal gap between this row and the one below it (rowIndex + 1), at index rowIndex
				if gap.type == .horizontal && gap.columnIndex == colIndex && gap.rowIndex == rowIndex { return index }
			}
		}
		return nil
	}

	/// Collect as candidates only the gaps for edges the focused window can actually move
	private func updateCandidateGapIndices(on screen: NSScreen) {
		guard let (colIndex, rowIndex) = focusedWindowPosition(on: screen) else {
			candidateGapIndices = []
			return
		}

		candidateGapIndices = [Direction.left, .right, .up, .down].compactMap {
			findGapIndex(edge: $0, colIndex: colIndex, rowIndex: rowIndex)
		}
	}

	/// Get the current screen
	private func getCurrentScreen() -> NSScreen? {
		// Get the screen the mouse cursor is on
		let mouseLocation = NSEvent.mouseLocation
		return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
	}

	/// Compute the gaps
	private func calculateGaps(for screen: NSScreen) {
		var gaps: [GapInfo] = []

		var columns = tilingEngine.tiledWindows[ScreenIdentifier(from: screen)] ?? []
		guard columns.count > 0 else {
			availableGaps = []
			return
		}

		// Get the latest frame info for each window
		for colIndex in 0..<columns.count {
			for rowIndex in 0..<columns[colIndex].count {
				columns[colIndex][rowIndex].refreshFrame()
			}
		}

		let gapWidth = tilingEngine.windowGap
		let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0

		// The gap between columns (vertical line)
		for colIndex in 0..<(columns.count - 1) {
			let leftColumn = columns[colIndex]
			let rightColumn = columns[colIndex + 1]

			guard !leftColumn.isEmpty && !rightColumn.isEmpty else { continue }

			// Compute the top and bottom of the whole column (considering every window)
			let leftMinY = leftColumn.map { $0.frame.minY }.min() ?? 0
			let leftMaxY = leftColumn.map { $0.frame.maxY }.max() ?? 0
			let rightMinY = rightColumn.map { $0.frame.minY }.min() ?? 0
			let rightMaxY = rightColumn.map { $0.frame.maxY }.max() ?? 0

			// Compute the gap position (between the right edge of the left column and the left edge of the right column)
			let gapX = leftColumn.first!.frame.maxX
			let gapY = min(leftMinY, rightMinY)
			let gapHeight = max(leftMaxY, rightMaxY) - gapY

			// Convert to NSScreen coordinates (bottom-left origin)
			let gapYInNSScreen = mainScreenHeight - gapY - gapHeight

			let gapFrame = CGRect(
				x: gapX,
				y: gapYInNSScreen,
				width: gapWidth,
				height: gapHeight
			)

			gaps.append(GapInfo(
				type: .vertical,
				columnIndex: colIndex,
				rowIndex: nil,
				frame: gapFrame
			))
		}

		// The gap between rows (horizontal line) - when a column has multiple windows
		for (colIndex, column) in columns.enumerated() {
			guard column.count > 1 else { continue }

			for rowIndex in 0..<(column.count - 1) {
				let upperWindow = column[rowIndex]

				// Compute the gap position (between the bottom edge of the upper window and the top edge of the lower one)
				let gapX = upperWindow.frame.minX
				let gapY = upperWindow.frame.maxY
				let gapWidth = upperWindow.frame.width

				// Convert to NSScreen coordinates
				let gapYInNSScreen = mainScreenHeight - gapY - tilingEngine.windowGap

				let gapFrame = CGRect(
					x: gapX,
					y: gapYInNSScreen,
					width: gapWidth,
					height: tilingEngine.windowGap
				)

				gaps.append(GapInfo(
					type: .horizontal,
					columnIndex: colIndex,
					rowIndex: rowIndex,
					frame: gapFrame
				))
			}
		}

		availableGaps = gaps
	}

	/// Show the overlay
	private func showOverlay(on screen: NSScreen) {
		if overlayWindow == nil {
			overlayWindow = GapOverlayWindow()
		}

		overlayWindow?.showOnScreen(screen, gaps: availableGaps, selectedIndex: currentGapIndex, candidateIndices: candidateGapIndices)
	}

	/// Update the overlay
	private func updateOverlay() {
		guard getCurrentScreen() != nil else { return }
		overlayWindow?.update(gaps: availableGaps, selectedIndex: currentGapIndex, candidateIndices: candidateGapIndices)
	}

	/// Hide the overlay
	private func hideOverlay() {
		overlayWindow?.hide()
	}
}
