//
//  PlacementReservationManager.swift
//  Axis
//
//  Created on 2026/08/05.
//

import AppKit

/// The kind of placement reservation (corresponds to the key pressed after Ctrl+Option+N)
enum PlacementReservationKind {
	case aboveInColumn   // I: フォーカス列の同じ列の上に積む
	case belowInColumn   // K: フォーカス列の同じ列の下に積む
	case newColumnLeft   // J: フォーカス列の左に新規列
	case newColumnRight  // L: フォーカス列の右に新規列
	case float           // F: Float で開く
}

/// The class that manages the "placement reservation" feature
/// Ctrl+Option+N enters the waiting state, and then pressing I/K/J/L/F without any modifier
/// Reserves a spot for the next new window that opens. Once the reservation is confirmed, it shows a translucent preview, and
/// It's consumed the moment the next new window is registered. Pressing Ctrl+Option+N again, or
/// It gets cancelled on timeout.
class PlacementReservationManager {
	static let shared = PlacementReservationManager()

	/// The number of seconds before a reservation auto-expires (kept as a single constant for easy tuning later)
	static let timeoutInterval: TimeInterval = 10.0

	/// The focus position at the moment the wait started (Ctrl+Opt+N was pressed)
	private struct FocusSnapshot {
		let screen: NSScreen
		let columnIndex: Int
	}

	/// A confirmed reservation
	private struct PendingReservation {
		let kind: PlacementReservationKind
		let screen: NSScreen
		let columnIndex: Int
	}

	/// The focus position at the moment the wait started (held only until the confirm key is pressed)
	private var pendingFocusSnapshot: FocusSnapshot?

	/// A confirmed reservation (while the preview is showing)
	private var current: PendingReservation?

	/// The delayed task used for the timeout
	private var timeoutWorkItem: DispatchWorkItem?

	/// The preview overlay window (reused)
	private var previewWindow: PlacementPreviewOverlayWindow?

	/// A callback to tell the caller (HotkeyManager) that the wait was cleared automatically
	var onAwaitingCanceled: (() -> Void)?

	private init() {}

	/// Whether there's a confirmed reservation
	var hasActiveReservation: Bool {
		current != nil
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
	func cancel() {
		pendingFocusSnapshot = nil
		current = nil
		timeoutWorkItem?.cancel()
		timeoutWorkItem = nil
		BorderManager.shared.setDashed(false)
		hidePreview()
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
			guard let screen = pendingFocusSnapshot?.screen ?? WorkspaceManager.shared.focusedScreen() else {
				hidePreview()
				return
			}
			current = PendingReservation(kind: .float, screen: screen, columnIndex: 0)
			showPreview(kind: .float, screen: screen, columnIndex: 0)

		case .aboveInColumn, .belowInColumn, .newColumnLeft, .newColumnRight:
			// A within-column or column-relative reservation can't be resolved without a known focus position
			guard let snapshot = pendingFocusSnapshot else {
				hidePreview()
				return
			}
			current = PendingReservation(kind: kind, screen: snapshot.screen, columnIndex: snapshot.columnIndex)
			showPreview(kind: kind, screen: snapshot.screen, columnIndex: snapshot.columnIndex)
		}

		scheduleTimeout()
	}

	// MARK: - Consumption (called when a new window is detected)

	/// Called when a new window is detected. If there's a valid reservation, consume it and apply the placement
	/// Floating windows like dialogs (ones matching the existing floating check) don't consume the reservation
	/// - Returns: true if the reservation was consumed and placement plus workspace registration were completed (the caller can skip the normal registration path)
	@discardableResult
	func consumeIfApplicable(newWindow: WindowInfo) -> Bool {
		guard let reservation = current else { return false }
		guard newWindow.shouldBeManaged() && !newWindow.shouldFloat() else { return false }

		// Register it to the monitor it was reserved on (regardless of where the new window physically appears)
		WorkspaceManager.shared.registerWindow(newWindow.id, on: reservation.screen)

		switch reservation.kind {
		case .float:
			WorkspaceManager.shared.toggleFloat(windowID: newWindow.id)
			let visibleFrame = reservation.screen.visibleFrame
			let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
			let centerX = visibleFrame.midX - newWindow.frame.width / 2
			let centerY = mainScreenHeight - visibleFrame.midY - newWindow.frame.height / 2
			newWindow.setPosition(CGPoint(x: centerX, y: centerY))

		case .aboveInColumn, .belowInColumn, .newColumnLeft, .newColumnRight:
			TilingEngine.shared.insertReservedWindow(
				newWindow,
				columnIndex: reservation.columnIndex,
				kind: reservation.kind,
				on: reservation.screen
			)
		}

		cancel() // 一度きりの予約なので消費したら解除する（プレビューも消える）
		return true
	}

	// MARK: - Snapshot of the focus position

	/// Get the screen and column index the currently focused window belongs to
	private static func captureFocusSnapshot() -> FocusSnapshot? {
		guard let focused = AccessibilityManager.shared.getFocusedWindow() else { return nil }

		let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
		let center = CGPoint(x: focused.frame.midX, y: mainScreenHeight - focused.frame.midY)
		guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) else { return nil }

		let screenID = ScreenIdentifier(from: screen)
		let columns = TilingEngine.shared.tiledWindows[screenID] ?? []
		guard let (columnIndex, _) = TilingEngine.shared.findWindowPosition(window: focused, in: columns) else { return nil }

		return FocusSnapshot(screen: screen, columnIndex: columnIndex)
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
	private func showPreview(kind: PlacementReservationKind, screen: NSScreen, columnIndex: Int) {
		let axFrame = Self.previewFrame(kind: kind, screen: screen, columnIndex: columnIndex)
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
			let yBottom = visibleFrame.midY - height / 2 // NSScreen座標系（左下原点）
			let yAX = mainScreenHeight - yBottom - height
			return CGRect(x: x, y: yAX, width: width, height: height)
		}

		let screenID = ScreenIdentifier(from: screen)
		let columns = engine.tiledWindows[screenID] ?? []

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
			return .zero // 到達しない
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
