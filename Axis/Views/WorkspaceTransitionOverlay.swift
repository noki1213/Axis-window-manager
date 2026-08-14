//
//  WorkspaceTransitionOverlay.swift
//  Axis
//
//  Created on 2026/08/14.
//

import AppKit
import QuartzCore

/// Class that manages the slide animation for workspace switching
class WorkspaceTransitionManager {
	static let shared = WorkspaceTransitionManager()

	private var overlayWindows: [ScreenIdentifier: NSWindow] = [:]
	private let transitionDuration: TimeInterval = 0.26 // 自然なバネ・減衰時間

	private init() {}

	/// Start the transition animation for a workspace switch
	/// - Parameters:
	///   - from: the workspace number being switched from
	///   - to: the workspace number being switched to
	///   - screen: the target monitor
	func startTransition(from fromWS: Int, to toWS: Int, on screen: NSScreen) {
		guard fromWS != toWS else { return }

		let isMovingNext = (toWS > fromWS)
		let screenFrame = screen.frame
		let screenID = ScreenIdentifier(from: screen)

		// Close any existing transition window
		if let oldWindow = overlayWindows[screenID] {
			oldWindow.orderOut(nil as Any?)
			overlayWindows.removeValue(forKey: screenID)
		}

		// Capture the screen before switching
		let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
		let cgRect = CGRect(
			x: screenFrame.origin.x,
			y: mainScreenHeight - screenFrame.origin.y - screenFrame.height,
			width: screenFrame.width,
			height: screenFrame.height
		)

		let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
		guard let snapshot = CGWindowListCreateImage(
			cgRect,
			[.optionOnScreenOnly],
			kCGNullWindowID,
			[.bestResolution]
		) ?? CGDisplayCreateImage(displayID) else {
			return
		}

		// Create the overlay window
		let overlay = NSWindow(
			contentRect: screenFrame,
			styleMask: .borderless,
			backing: .buffered,
			defer: false
		)
		overlay.isOpaque = false
		overlay.backgroundColor = .clear
		overlay.level = .floating + 20
		overlay.ignoresMouseEvents = true
		overlay.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
		overlay.isReleasedWhenClosed = false

		let contentView = NSView(frame: NSRect(origin: .zero, size: screenFrame.size))
		contentView.wantsLayer = true
		contentView.layer?.masksToBounds = true
		overlay.contentView = contentView

		// Layer that holds the captured image
		let snapshotLayer = CALayer()
		snapshotLayer.frame = contentView.bounds
		snapshotLayer.contentsScale = screen.backingScaleFactor
		snapshotLayer.contents = snapshot
		snapshotLayer.contentsGravity = .resizeAspectFill
		contentView.layer?.addSublayer(snapshotLayer)

		overlay.orderFront(nil as Any?)
		overlayWindows[screenID] = overlay

		// Calculate the slide distance and direction
		// +1 (next): the old screen slides out to the left (-width)
		// -1 (previous): the old screen slides out to the right (+width)
		let slideDistance = isMovingNext ? -screenFrame.width : screenFrame.width

		CATransaction.begin()
		CATransaction.setAnimationDuration(transitionDuration)
		CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)) // 減衰カーブ

		CATransaction.setCompletionBlock { [weak self, weak overlay] in
			overlay?.orderOut(nil as Any?)
			if let self = self {
				self.overlayWindows.removeValue(forKey: screenID)
			}
		}

		// Position animation (slide out)
		let positionAnim = CABasicAnimation(keyPath: "transform.translation.x")
		positionAnim.fromValue = 0
		positionAnim.toValue = slideDistance
		positionAnim.duration = transitionDuration
		positionAnim.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
		positionAnim.fillMode = .forwards
		positionAnim.isRemovedOnCompletion = false
		snapshotLayer.add(positionAnim, forKey: "slideOut")

		// A slight scale-down for a sense of depth
		let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
		scaleAnim.fromValue = 1.0
		scaleAnim.toValue = 0.98
		scaleAnim.duration = transitionDuration
		scaleAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
		scaleAnim.fillMode = .forwards
		scaleAnim.isRemovedOnCompletion = false
		snapshotLayer.add(scaleAnim, forKey: "scale")

		// Opacity animation (fades slightly as it exits)
		let opacityAnim = CABasicAnimation(keyPath: "opacity")
		opacityAnim.fromValue = 1.0
		opacityAnim.toValue = 0.85
		opacityAnim.duration = transitionDuration
		opacityAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
		opacityAnim.fillMode = .forwards
		opacityAnim.isRemovedOnCompletion = false
		snapshotLayer.add(opacityAnim, forKey: "fade")

		CATransaction.commit()
	}
}
