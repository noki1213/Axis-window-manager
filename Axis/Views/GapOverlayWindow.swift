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
	func showOnScreen(_ screen: NSScreen, gaps: [GapInfo], selectedIndex: Int?) {
		self.setFrame(screen.frame, display: true)
		overlayView.update(gaps: gaps, selectedIndex: selectedIndex, screenFrame: screen.frame)
		self.orderFront(nil)
	}

	/// Update the overlay
	func update(gaps: [GapInfo], selectedIndex: Int?) {
		overlayView.update(gaps: gaps, selectedIndex: selectedIndex, screenFrame: self.frame)
	}

	/// Hide the overlay
	func hide() {
		self.orderOut(nil)
	}
}

/// The view that draws the gap
class GapOverlayView: NSView {

	private var gaps: [GapInfo] = []
	private var selectedIndex: Int? = nil
	private var screenFrame: CGRect = .zero
	
	private let selectionLayer = CAShapeLayer()

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		self.wantsLayer = true
		setupLayer()
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}
	
	private func setupLayer() {
		selectionLayer.strokeColor = NSColor.white.cgColor
		selectionLayer.fillColor = nil
		selectionLayer.lineWidth = 8
		selectionLayer.lineCap = .round
		self.layer?.addSublayer(selectionLayer)
	}

	func update(gaps: [GapInfo], selectedIndex: Int?, screenFrame: CGRect) {
		self.gaps = gaps
		self.selectedIndex = selectedIndex
		self.screenFrame = screenFrame

		updateSelectionLayer()
	}

	private func updateSelectionLayer() {
		guard let selectedIndex = selectedIndex, selectedIndex >= 0 && selectedIndex < gaps.count else {
			selectionLayer.path = nil
			return
		}

		let gap = gaps[selectedIndex]
		let localFrame = convertToViewCoordinates(gap.frame)

		let path = CGMutablePath()
		if gap.type == .vertical {
			let x = localFrame.midX
			path.move(to: CGPoint(x: x, y: localFrame.minY))
			path.addLine(to: CGPoint(x: x, y: localFrame.maxY))
		} else {
			let y = localFrame.midY
			path.move(to: CGPoint(x: localFrame.minX, y: y))
			path.addLine(to: CGPoint(x: localFrame.maxX, y: y))
		}

		// The edge being manipulated is always highlighted in white
		selectionLayer.strokeColor = NSColor.white.cgColor

		// Update the path with animation
		let animation = CABasicAnimation(keyPath: "path")
		animation.duration = 0.2
		animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
		animation.fromValue = selectionLayer.path
		animation.toValue = path
		
		selectionLayer.add(animation, forKey: "pathAnimation")
		selectionLayer.path = path
	}

	override func draw(_ dirtyRect: NSRect) {
		// Since drawing is done with a CAShapeLayer, there's nothing to do here
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
