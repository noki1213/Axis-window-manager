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
	func showOnScreen(_ screen: NSScreen, gaps: [GapInfo], selectedIndex: Int?, candidateIndices: [Int]) {
		self.setFrame(screen.frame, display: true)
		overlayView.update(gaps: gaps, selectedIndex: selectedIndex, candidateIndices: candidateIndices, screenFrame: screen.frame)
		self.orderFront(nil)
	}

	/// Update the overlay
	func update(gaps: [GapInfo], selectedIndex: Int?, candidateIndices: [Int]) {
		overlayView.update(gaps: gaps, selectedIndex: selectedIndex, candidateIndices: candidateIndices, screenFrame: self.frame)
	}

	/// Hide the overlay
	func hide() {
		overlayView.reset()
		self.orderOut(nil)
	}
}

/// The view that draws the gap
class GapOverlayView: NSView {

	private var gaps: [GapInfo] = []
	private var selectedIndex: Int? = nil
	/// The gap indices of the movable edges (only these are drawn thin)
	private var candidateIndices: [Int] = []
	private var screenFrame: CGRect = .zero
	
	private let selectionLayer = CAShapeLayer()
	/// A layer that faintly shows the candidate edges that can be operated on (also signals that the mode was entered)
	private let candidateLayer = CAShapeLayer()

	/// Whether the candidates were just drawn (so the fade-in only happens the moment the mode is entered)
	private var hasDrawnCandidates = false

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		self.wantsLayer = true
		setupLayer()
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	private func setupLayer() {
		candidateLayer.strokeColor = NSColor.white.withAlphaComponent(0.3).cgColor
		candidateLayer.fillColor = nil
		candidateLayer.lineWidth = 4
		candidateLayer.lineCap = .round
		self.layer?.addSublayer(candidateLayer)

		selectionLayer.strokeColor = NSColor.white.cgColor
		selectionLayer.fillColor = nil
		selectionLayer.lineWidth = 8
		selectionLayer.lineCap = .round
		self.layer?.addSublayer(selectionLayer)
	}

	func update(gaps: [GapInfo], selectedIndex: Int?, candidateIndices: [Int], screenFrame: CGRect) {
		self.gaps = gaps
		self.selectedIndex = selectedIndex
		self.candidateIndices = candidateIndices
		self.screenFrame = screenFrame

		updateCandidateLayer()
		updateSelectionLayer()
	}

	/// Draw every movable edge except the selected one as a thin line
	private func updateCandidateLayer() {
		guard !candidateIndices.isEmpty else {
			candidateLayer.path = nil
			hasDrawnCandidates = false
			return
		}

		let path = CGMutablePath()
		for index in candidateIndices {
			// The selected edge is drawn thick by selectionLayer, so exclude it from the candidates
			if index == selectedIndex { continue }
			guard index >= 0 && index < gaps.count else { continue }
			appendLine(for: gaps[index], to: path)
		}

		// Don't animate the path swap itself (it would jitter every time the edge changes)
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		candidateLayer.path = path
		CATransaction.commit()

		// Fade in only the first draw after entering the mode, to make entry clearly noticeable
		if !hasDrawnCandidates {
			let fade = CABasicAnimation(keyPath: "opacity")
			fade.duration = 0.15
			fade.fromValue = 0
			fade.toValue = 1
			candidateLayer.add(fade, forKey: "fadeIn")
			hasDrawnCandidates = true
		}
	}

	/// Add the line for one gap to the path
	private func appendLine(for gap: GapInfo, to path: CGMutablePath) {
		let localFrame = convertToViewCoordinates(gap.frame)
		if gap.type == .vertical {
			let x = localFrame.midX
			path.move(to: CGPoint(x: x, y: localFrame.minY))
			path.addLine(to: CGPoint(x: x, y: localFrame.maxY))
		} else {
			let y = localFrame.midY
			path.move(to: CGPoint(x: localFrame.minX, y: y))
			path.addLine(to: CGPoint(x: localFrame.maxX, y: y))
		}
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

	/// Reset the state when the mode ends (so candidates fade in again next time it's entered)
	func reset() {
		gaps = []
		selectedIndex = nil
		candidateIndices = []
		candidateLayer.path = nil
		selectionLayer.path = nil
		hasDrawnCandidates = false
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
