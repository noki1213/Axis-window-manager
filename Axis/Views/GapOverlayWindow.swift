//
//  GapOverlayWindow.swift
//  Axis
//
//  Created on 2026/01/27.
//

import AppKit

/// An overlay window that visually displays the gap
class GapOverlayWindow: NSWindow {

	private var overlayView: GapOverlayView!

	init() {
		super.init(
			contentRect: .zero,
			styleMask: .borderless,
			backing: .buffered,
			defer: false
		)

		// Window settings
		self.isOpaque = false
		self.backgroundColor = .clear
		self.level = .floating
		self.ignoresMouseEvents = true
		self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

		// Set up the overlay view
		overlayView = GapOverlayView()
		self.contentView = overlayView
	}

	/// Show the overlay on the given screen
	func showOnScreen(_ screen: NSScreen, gaps: [GapInfo], selectedIndex: Int, state: GapSelectState) {
		self.setFrame(screen.frame, display: true)
		overlayView.update(gaps: gaps, selectedIndex: selectedIndex, state: state, screenFrame: screen.frame)
		self.orderFront(nil)
	}

	/// Update the overlay
	func update(gaps: [GapInfo], selectedIndex: Int, state: GapSelectState) {
		overlayView.update(gaps: gaps, selectedIndex: selectedIndex, state: state, screenFrame: self.frame)
	}

	/// Hide the overlay
	func hide() {
		self.orderOut(nil)
	}
}

/// The view that draws the gap
class GapOverlayView: NSView {

	private var gaps: [GapInfo] = []
	private var selectedIndex: Int = 0
	private var state: GapSelectState = .selecting
	private var screenFrame: CGRect = .zero

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		self.wantsLayer = true
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func update(gaps: [GapInfo], selectedIndex: Int, state: GapSelectState, screenFrame: CGRect) {
		self.gaps = gaps
		self.selectedIndex = selectedIndex
		self.state = state
		self.screenFrame = screenFrame
		self.setNeedsDisplay(self.bounds)
	}

	override func draw(_ dirtyRect: NSRect) {
		super.draw(dirtyRect)

		guard let context = NSGraphicsContext.current?.cgContext else { return }

		for (index, gap) in gaps.enumerated() {
			let isSelected = index == selectedIndex

			// Convert the gap's frame to the view's coordinate system
			let localFrame = convertToViewCoordinates(gap.frame)

			// Line thickness
			let lineWidth: CGFloat = isSelected ? 8 : 4

			// Decide the color
			let color: NSColor
			if isSelected {
				if state == .resizing {
					// Green while resizing
					color = NSColor.systemGreen.withAlphaComponent(0.8)
				} else {
					// Blue while selected
					color = NSColor.systemBlue.withAlphaComponent(0.8)
				}
			} else {
				// Light gray when not selected
				color = NSColor.white.withAlphaComponent(0.4)
			}

			context.setStrokeColor(color.cgColor)
			context.setLineWidth(lineWidth)

			// Draw the line
			if gap.type == .vertical {
				// Vertical line (between columns)
				let x = localFrame.midX
				context.move(to: CGPoint(x: x, y: localFrame.minY))
				context.addLine(to: CGPoint(x: x, y: localFrame.maxY))
			} else {
				// Horizontal line (between rows)
				let y = localFrame.midY
				context.move(to: CGPoint(x: localFrame.minX, y: y))
				context.addLine(to: CGPoint(x: localFrame.maxX, y: y))
			}

			context.strokePath()

			// Draw a handle on the currently selected gap
			if isSelected {
				drawHandle(context: context, gap: gap, localFrame: localFrame)
			}
		}
	}

	/// Draw the handle (the grabbable part)
	private func drawHandle(context: CGContext, gap: GapInfo, localFrame: CGRect) {
		let handleSize: CGFloat = 20
		let handleRect: CGRect

		if gap.type == .vertical {
			// Handle at the center of the vertical line
			handleRect = CGRect(
				x: localFrame.midX - handleSize / 2,
				y: localFrame.midY - handleSize / 2,
				width: handleSize,
				height: handleSize
			)
		} else {
			// Handle at the center of the horizontal line
			handleRect = CGRect(
				x: localFrame.midX - handleSize / 2,
				y: localFrame.midY - handleSize / 2,
				width: handleSize,
				height: handleSize
			)
		}

		let handleColor: NSColor
		if state == .resizing {
			handleColor = NSColor.systemGreen
		} else {
			handleColor = NSColor.systemBlue
		}

		context.setFillColor(handleColor.cgColor)
		context.fillEllipse(in: handleRect)

		// White border
		context.setStrokeColor(NSColor.white.cgColor)
		context.setLineWidth(2)
		context.strokeEllipse(in: handleRect)
	}

	/// Convert from screen coordinates to view coordinates
	private func convertToViewCoordinates(_ rect: CGRect) -> CGRect {
		// Convert to a position relative to screenFrame.origin
		return CGRect(
			x: rect.origin.x - screenFrame.origin.x,
			y: rect.origin.y - screenFrame.origin.y,
			width: rect.width,
			height: rect.height
		)
	}
}
