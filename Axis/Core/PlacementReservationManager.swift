//
//  PlacementReservationManager.swift
//  Axis
//
//  Created on 2026/08/05.
//

import AppKit

/// The kind of placement reservation (corresponds to the key pressed after Ctrl+Option+N):
/// I/K stack above/below in the focused column, J/L open a new column left/right of it, F floats
typealias PlacementReservationKind = ReservationKind

/// The class that manages the "placement reservation" feature
/// Ctrl+Option+N enters the waiting state, and then pressing I/K/J/L/F without any modifier
/// Reserves a spot for the next new window that opens. Once the reservation is confirmed, it shows a translucent preview, and
/// the tracking state places the next new window there and clears it. Pressing Ctrl+Option+N again, or
/// a timeout, cancels it.
class PlacementReservationManager {
	static let shared = PlacementReservationManager()

	/// The number of seconds before a reservation auto-expires (kept as a single constant for easy tuning later)
	static let timeoutInterval: TimeInterval = 10.0

	/// The focus position at the moment the wait started (Ctrl+Opt+N was pressed)
	private struct FocusSnapshot {
		let monitor: MonitorKey
		let columnIndex: Int
	}

	/// The focus position at the moment the wait started (held only until the confirm key is pressed)
	private var pendingFocusSnapshot: FocusSnapshot?

	/// Whether a confirmed reservation is waiting in the tracking state (while the preview is showing)
	private var isConfirmed: Bool = false

	/// The delayed task used for the timeout
	private var timeoutWorkItem: DispatchWorkItem?

	/// The preview overlay window (reused)
	private var previewWindow: PlacementPreviewOverlayWindow?

	/// A flag for whether the pre-placement layout has been applied
	private var isLayoutApplied: Bool = false

	/// A callback to tell the caller (HotkeyManager) that the wait was cleared automatically
	var onAwaitingCanceled: (() -> Void)?

	private var coordinator: TrackingCoordinator { TrackingCoordinator.shared }

	private init() {}

	/// Whether there's a confirmed reservation
	var hasActiveReservation: Bool {
		coordinator.state.reservation != nil
	}

	// MARK: - Starting/canceling the wait

	/// Remember the focus position at the moment Ctrl+Opt+N was pressed
	/// Since focus shifts when a new window opens, it must not be evaluated after opening
	func beginAwaiting() {
		pendingFocusSnapshot = Self.captureFocusSnapshot()

		// To signal "now waiting on a reservation" without adding anything to the screen, just switch the focus border to dotted
		BorderManager.shared.setDashed(true)

		// Also auto-clear it after the same duration as after confirming, if it's left waiting untouched
		scheduleTimeout()
	}

	/// Cancel the reservation (Ctrl+Opt+N was pressed again, it timed out, etc.)
	/// Clearing it from the tracking state lays the windows out without the reserved slot again
	func cancel() {
		isLayoutApplied = false
		isConfirmed = false
		pendingFocusSnapshot = nil
		timeoutWorkItem?.cancel()
		timeoutWorkItem = nil
		BorderManager.shared.setDashed(false)
		hidePreview()

		if coordinator.state.reservation != nil {
			coordinator.perform("reservation") { state in
				state.setReservation(nil)
			}
		}
	}

	// MARK: - Confirm

	/// Called when I/K/J/L/F is pressed while waiting. Confirms the reservation and shows the preview
	func confirm(kind: PlacementReservationKind) {
		defer { pendingFocusSnapshot = nil }

		// Once confirmed, its job as a signal is done (from here on, the preview border shows the state)
		BorderManager.shared.setDashed(false)

		switch kind {
		case .float:
			// Float can be resolved even without focused-column info
			guard let monitor = pendingFocusSnapshot?.monitor
					?? WorkspaceManager.shared.focusedScreen().flatMap({ WorkspaceManager.shared.monitorKey(for: $0) }),
				  let screen = WorkspaceManager.shared.screen(for: monitor) else {
				hidePreview()
				return
			}
			reserve(PlacementReservation(kind: .float, monitor: monitor, columnIndex: 0))
			isLayoutApplied = false
			let axFrame = Self.previewFrame(kind: .float, screen: screen, columnIndex: 0)
			showPreview(axFrame: axFrame)

		case .aboveInColumn, .belowInColumn, .newColumnLeft, .newColumnRight:
			// A within-column or column-relative reservation can't be resolved without a known focus position
			guard let snapshot = pendingFocusSnapshot, let screen = WorkspaceManager.shared.screen(for: snapshot.monitor) else {
				hidePreview()
				return
			}
			if let axFrame = TilingEngine.shared.applyReservedSlotLayout(columnIndex: snapshot.columnIndex, kind: kind, on: screen) {
				isLayoutApplied = true
				showPreview(axFrame: axFrame)
			} else {
				isLayoutApplied = false
				let axFrame = Self.previewFrame(kind: kind, screen: screen, columnIndex: snapshot.columnIndex)
				showPreview(axFrame: axFrame)
			}
			reserve(PlacementReservation(kind: kind, monitor: snapshot.monitor, columnIndex: snapshot.columnIndex))
		}

		scheduleTimeout()
	}

	/// The tracking state holds the reservation: the layout keeps the reserved slot free, and the
	/// next window that opens takes it
	private func reserve(_ reservation: PlacementReservation) {
		isConfirmed = true
		coordinator.perform("reservation") { state in
			state.setReservation(reservation)
		}
	}

	// MARK: - Consumption

	/// Called after a window was admitted. The tracking state places a new window that fits the
	/// reservation (dialogs and other floating windows leave it alone) and clears it; the preview
	/// and the timeout go with it (one-shot reservation).
	func noteWindowAdmitted() {
		guard isConfirmed, coordinator.state.reservation == nil else { return }
		cancel()
	}

	// MARK: - Snapshot of the focus position

	/// Get the monitor and column index the currently focused window belongs to
	private static func captureFocusSnapshot() -> FocusSnapshot? {
		guard let focused = AccessibilityManager.shared.getFocusedWindow() else { return nil }

		let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
		let center = CGPoint(x: focused.frame.midX, y: mainScreenHeight - focused.frame.midY)
		guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }),
			  let monitor = WorkspaceManager.shared.monitorKey(for: screen) else { return nil }

		let columns = TilingEngine.shared.tiledColumns(on: screen)
		guard let (columnIndex, _) = TilingEngine.shared.findWindowPosition(window: focused, in: columns) else { return nil }

		return FocusSnapshot(monitor: monitor, columnIndex: columnIndex)
	}

	// MARK: - Timeout

	private func scheduleTimeout() {
		timeoutWorkItem?.cancel()
		let workItem = DispatchWorkItem { [weak self] in
			guard let self = self else { return }
			self.cancel()
			self.onAwaitingCanceled?()
		}
		timeoutWorkItem = workItem
		DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeoutInterval, execute: workItem)
	}

	// MARK: - Preview display

	/// After confirming: show the chosen destination with a dotted border
	private func showPreview(axFrame: CGRect) {
		let screenRect = Self.toScreenRect(axFrame)

		if previewWindow == nil {
			previewWindow = PlacementPreviewOverlayWindow()
		}
		previewWindow?.show(frame: screenRect)
	}

	private func hidePreview() {
		previewWindow?.hide()
	}

	/// Compute the approximate region to show the preview in, from the reservation content (Accessibility coordinates, top-left origin)
	/// A simplified calculation independent of the actual tiling computation (TilingEngine.applyColumnTiling), which
	/// Purely a preview to show "roughly where it will be placed"
	private static func previewFrame(kind: PlacementReservationKind, screen: NSScreen, columnIndex: Int) -> CGRect {
		let engine = TilingEngine.shared
		let visibleFrame = screen.visibleFrame
		let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
		let screenTopInAX = mainScreenHeight - (visibleFrame.minY + visibleFrame.height)
		let gap = engine.windowGap
		let padding = engine.screenPadding

		if kind == .float {
			let width: CGFloat = 640
			let height: CGFloat = 480
			let x = visibleFrame.midX - width / 2
			let yBottom = visibleFrame.midY - height / 2 // NSScreen coordinates (bottom-left origin)
			let yAX = mainScreenHeight - yBottom - height
			return CGRect(x: x, y: yAX, width: width, height: height)
		}

		let columns = engine.tiledColumns(on: screen)

		switch kind {
		case .aboveInColumn, .belowInColumn:
			guard !columns.isEmpty else {
				// If there are no columns, target the whole screen
				return CGRect(
					x: visibleFrame.minX + padding,
					y: screenTopInAX + padding,
					width: visibleFrame.width - padding * 2,
					height: visibleFrame.height - padding * 2
				)
			}
			let idx = min(max(columnIndex, 0), columns.count - 1)
			let column = columns[idx]
			guard let sample = column.first else { return .zero }

			let colX = sample.frame.minX
			let colWidth = sample.frame.width

			let rowCount = CGFloat(column.count + 1)
			let totalGaps = gap * (rowCount - 1)
			let availableHeight = visibleFrame.height - padding * 2 - totalGaps
			let rowHeight = availableHeight / rowCount

			let y = (kind == .aboveInColumn)
				? screenTopInAX + padding
				: screenTopInAX + padding + (rowHeight + gap) * (rowCount - 1)
			return CGRect(x: colX, y: y, width: colWidth, height: rowHeight)

		case .newColumnLeft, .newColumnRight:
			let insertIdx = (kind == .newColumnLeft) ? columnIndex : columnIndex + 1
			let clampedInsertIdx = min(max(insertIdx, 0), columns.count)
			let newColumnCount = CGFloat(columns.count + 1)
			let totalGaps = gap * (newColumnCount - 1)
			let availableWidth = visibleFrame.width - padding * 2 - totalGaps
			let colWidth = availableWidth / newColumnCount
			let x = visibleFrame.minX + padding + CGFloat(clampedInsertIdx) * (colWidth + gap)
			return CGRect(x: x, y: screenTopInAX + padding, width: colWidth, height: visibleFrame.height - padding * 2)

		case .float:
			return .zero // Unreachable
		}
	}

	/// Convert a rect in Accessibility coordinates (top-left origin) to NSWindow coordinates (bottom-left origin)
	private static func toScreenRect(_ axFrame: CGRect) -> CGRect {
		let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
		let y = mainScreenHeight - axFrame.origin.y - axFrame.height
		return CGRect(x: axFrame.origin.x, y: y, width: axFrame.width, height: axFrame.height)
	}

}

// MARK: - PlacementPreviewOverlayWindow

/// The overlay window that shows the placement-reservation preview
/// To never steal focus, treat it as a non-activating panel and ignore mouse events too
private class PlacementPreviewOverlayWindow: NSWindow {

	private let previewView = PlacementPreviewView()

	init() {
		super.init(
			contentRect: .zero,
			styleMask: .borderless,
			backing: .buffered,
			defer: false
		)

		self.isOpaque = false
		self.backgroundColor = .clear
		self.level = .floating
		self.ignoresMouseEvents = true
		self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
		self.hasShadow = false

		self.contentView = previewView
	}

	/// Show the preview in the given region (NSWindow coordinates)
	func show(frame: CGRect) {
		self.setFrame(frame, display: true)
		self.orderFront(nil)
	}

	/// Hide the preview
	func hide() {
		self.orderOut(nil)
	}
}

// MARK: - PlacementPreviewView

/// A view that draws the preview area with a translucent dashed border plus fill
private class PlacementPreviewView: NSView {
	override func draw(_ dirtyRect: NSRect) {
		super.draw(dirtyRect)

		let inset: CGFloat = 4
		let cornerRadius: CGFloat = 12
		let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: cornerRadius, yRadius: cornerRadius)

		NSColor.white.withAlphaComponent(0.18).setFill()
		path.fill()

		path.lineWidth = 3
		path.setLineDash([8, 6], count: 2, phase: 0)
		NSColor.white.withAlphaComponent(0.9).setStroke()
		path.stroke()
	}
}
