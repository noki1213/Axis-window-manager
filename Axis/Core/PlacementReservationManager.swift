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
/// Reserves a spot for the next new window that opens. Once the reservation is confirmed, the layout keeps
/// that slot free and a translucent preview shows it; the tracking state places the next new window there
/// and clears it. Pressing Ctrl+Option+N again, or a timeout, cancels it.
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
				  let visibleFrame = coordinator.state.monitors[monitor]?.visibleFrame else {
				hidePreview()
				return
			}
			reserve(PlacementReservation(kind: .float, monitor: monitor, columnIndex: 0))
			showPreview(axFrame: Self.floatPreviewFrame(in: visibleFrame))

		case .aboveInColumn, .belowInColumn, .newColumnLeft, .newColumnRight:
			// A within-column or column-relative reservation can't be resolved without a known focus position
			guard let snapshot = pendingFocusSnapshot else {
				hidePreview()
				return
			}
			// The windows make room for the reserved slot right away, and the preview shows that slot
			reserve(PlacementReservation(kind: kind, monitor: snapshot.monitor, columnIndex: snapshot.columnIndex))
			if let slot = coordinator.state.reservedSlot {
				showPreview(axFrame: slot)
			} else {
				hidePreview()
			}
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

	/// A float reservation has no slot (the window opens centred at its own size), so the preview
	/// marks the middle of the screen with a window-sized area (Accessibility coordinates)
	private static func floatPreviewFrame(in visibleFrame: CGRect) -> CGRect {
		let size = CGSize(width: 640, height: 480)
		return CGRect(x: visibleFrame.midX - size.width / 2, y: visibleFrame.midY - size.height / 2,
			width: size.width, height: size.height)
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
