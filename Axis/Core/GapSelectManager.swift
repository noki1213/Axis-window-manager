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

/// Gap-selection mode state
enum GapSelectState {
	/// A gap is selected (movement steps between gaps)
	case selecting
	/// A gap is grabbed and being resized (movement moves the gap)
	case resizing
}

	/// Management of gap-selection mode
class GapSelectManager: ObservableObject {
	static let shared = GapSelectManager()

	// MARK: - Published Properties

	/// Whether gap-selection mode is active
	var isActive: Bool {
		return !availableGaps.isEmpty
	}

	/// Current state
	@Published var state: GapSelectState = .selecting
	/// All available gaps
	@Published var availableGaps: [GapInfo] = []

	/// The index of the currently selected gap
	@Published var selectedGapIndex: Int = 0

	/// The currently selected gap
	var selectedGap: GapInfo? {
		guard selectedGapIndex >= 0 && selectedGapIndex < availableGaps.count else {
			return nil
		}
		return availableGaps[selectedGapIndex]
	}

	// MARK: - Dependencies

	private let tilingEngine = TilingEngine.shared
	private var overlayWindow: GapOverlayWindow?

	private init() {}

	// MARK: - Public Methods

	/// Start gap-selection mode
	func startGapSelectMode() {
		print("[Axis] GapSelectManager: startGapSelectMode")

		// Get the current screen
		guard let screen = getCurrentScreen() else {
			print("[Axis] GapSelectManager: No current screen")
			return
		}

		// Calculate the gap
		calculateGaps(for: screen)

		guard !availableGaps.isEmpty else {
			print("[Axis] GapSelectManager: No gaps available")
			return
		}

		// Initialize the state
		state = .selecting
		selectedGapIndex = 0

		// Show the overlay
		showOverlay(on: screen)
		
		// Update the focus border (hide it)
		BorderManager.shared.updateBorder()
	}

	/// End gap-selection mode
	func endGapSelectMode() {
		print("[Axis] GapSelectManager: endGapSelectMode")

		// Hide the overlay
		hideOverlay()

		// Reset the state
		availableGaps = []
		selectedGapIndex = 0
		state = .selecting
		
		// Update the focus border (show it again)
		BorderManager.shared.updateBorder()
	}

	/// Move to the next gap
	func moveToNextGap(direction: Direction) {
		guard state == .selecting else { return }
		guard !availableGaps.isEmpty else { return }

		print("[Axis] GapSelectManager: moveToNextGap direction=\(direction)")

		// Find the next gap based on direction
		let currentGap = selectedGap
		var bestIndex: Int? = nil
		var bestDistance: CGFloat = .infinity

		for (index, gap) in availableGaps.enumerated() {
			guard index != selectedGapIndex else { continue }

			let isValidDirection: Bool
			let distance: CGFloat

			switch direction {
			case .left:
				isValidDirection = gap.frame.midX < (currentGap?.frame.midX ?? 0)
				distance = (currentGap?.frame.midX ?? 0) - gap.frame.midX
			case .right:
				isValidDirection = gap.frame.midX > (currentGap?.frame.midX ?? 0)
				distance = gap.frame.midX - (currentGap?.frame.midX ?? 0)
			case .up:
				isValidDirection = gap.frame.midY < (currentGap?.frame.midY ?? 0)
				distance = (currentGap?.frame.midY ?? 0) - gap.frame.midY
			case .down:
				isValidDirection = gap.frame.midY > (currentGap?.frame.midY ?? 0)
				distance = gap.frame.midY - (currentGap?.frame.midY ?? 0)
			}

			if isValidDirection && distance < bestDistance {
				bestDistance = distance
				bestIndex = index
			}
		}

		if let newIndex = bestIndex {
			selectedGapIndex = newIndex
			updateOverlay()
			print("[Axis] GapSelectManager: moved to gap \(newIndex)")
		}
	}

	/// Select the current gap (enters resize mode)
	func selectCurrentGap() {
		guard state == .selecting else {
			// Confirm it if a resize is already in progress
			confirmResize()
			return
		}

		guard selectedGap != nil else { return }

		print("[Axis] GapSelectManager: selectCurrentGap - entering resize mode")
		state = .resizing
		updateOverlay()
	}

	/// Confirm the resize
	func confirmResize() {
		print("[Axis] GapSelectManager: confirmResize")
		state = .selecting
		updateOverlay()
	}

	/// Move the gap (resize)
	func moveGap(direction: Direction) {
		guard state == .resizing else { return }
		guard let gap = selectedGap else { return }

		print("[Axis] GapSelectManager: moveGap direction=\(direction)")

		// Movement amount (pixels)
		let moveAmount: CGFloat = 50

		guard let screen = getCurrentScreen() else { return }

		switch gap.type {
		case .vertical:
			// A vertical gap can only be moved left and right
			guard direction == .left || direction == .right else { return }
			let delta = direction == .left ? -moveAmount : moveAmount
			tilingEngine.resizeColumnGap(at: gap.columnIndex, delta: delta, on: screen)

		case .horizontal:
			// A horizontal gap can only be moved up and down
			guard direction == .up || direction == .down else { return }
			guard let rowIndex = gap.rowIndex else { return }
			let delta = direction == .up ? -moveAmount : moveAmount
			tilingEngine.resizeRowGap(columnIndex: gap.columnIndex, rowIndex: rowIndex, delta: delta, on: screen)
		}

		// Recalculate the gap
		calculateGaps(for: screen)
		updateOverlay()
	}

	// MARK: - Private Methods

	/// Get the current screen
	private func getCurrentScreen() -> NSScreen? {
		// Get the screen the mouse cursor is on
		let mouseLocation = NSEvent.mouseLocation
		return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
	}

	/// Compute the gaps
	private func calculateGaps(for screen: NSScreen) {
		var gaps: [GapInfo] = []

		var columns = tilingEngine.tiledWindows[screen] ?? []
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

			guard let leftWindow = leftColumn.first, let rightWindow = rightColumn.first else { continue }

			// Compute the gap position (between the right edge of the left column and the left edge of the right column)
			let gapX = leftWindow.frame.maxX
			let gapY = min(leftWindow.frame.minY, rightWindow.frame.minY)
			let gapHeight = max(leftWindow.frame.maxY, rightWindow.frame.maxY) - gapY

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
		print("[Axis] GapSelectManager: calculated \(gaps.count) gaps")
	}

	/// Show the overlay
	private func showOverlay(on screen: NSScreen) {
		if overlayWindow == nil {
			overlayWindow = GapOverlayWindow()
		}

		overlayWindow?.showOnScreen(screen, gaps: availableGaps, selectedIndex: selectedGapIndex, state: state)
	}

	/// Update the overlay
	private func updateOverlay() {
		guard getCurrentScreen() != nil else { return }
		overlayWindow?.update(gaps: availableGaps, selectedIndex: selectedGapIndex, state: state)
	}

	/// Hide the overlay
	private func hideOverlay() {
		overlayWindow?.hide()
	}
}
