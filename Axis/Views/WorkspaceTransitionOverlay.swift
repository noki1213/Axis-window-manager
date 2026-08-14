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
	private let transitionDuration: TimeInterval = 0.28 // 自然なバネ・減衰時間

	private init() {}

	/// Check and request screen recording permission (called at launch)
	func checkScreenCaptureAccess() {
		if #available(macOS 11.0, *) {
			if !CGPreflightScreenCaptureAccess() {
				CGRequestScreenCaptureAccess()
			}
		}
	}

	/// Capture the current screen of the target monitor for the switch
	func captureCurrentScreen(on screen: NSScreen) -> CGImage? {
		let screenFrame = screen.frame
		let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
		let cgRect = CGRect(
			x: screenFrame.origin.x,
			y: mainScreenHeight - screenFrame.origin.y - screenFrame.height,
			width: screenFrame.width,
			height: screenFrame.height
		)

		let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
		return CGWindowListCreateImage(
			cgRect,
			[.optionOnScreenOnly],
			kCGNullWindowID,
			[.bestResolution]
		) ?? CGDisplayCreateImage(displayID)
	}

	/// Run a transition that lays the two screens side by side and slides them in/out
	/// - Parameters:
	///   - oldSnapshot: the screen capture before switching
	///   - newSnapshot: the screen capture after switching
	///   - isMovingNext: true for the +1 direction (next), false for the -1 direction (previous)
	///   - screen: the target monitor
	func performSlideTransition(
		oldSnapshot: CGImage,
		newSnapshot: CGImage,
		isMovingNext: Bool,
		on screen: NSScreen
	) {
		let screenFrame = screen.frame
		let screenID = ScreenIdentifier(from: screen)

		// Close any existing transition window
		if let oldWindow = overlayWindows[screenID] {
			oldWindow.orderOut(nil as Any?)
			overlayWindows.removeValue(forKey: screenID)
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

		let width = screenFrame.width
		let height = screenFrame.height

		let contentView = NSView(frame: NSRect(origin: .zero, size: screenFrame.size))
		contentView.wantsLayer = true
		contentView.layer?.masksToBounds = true
		overlay.contentView = contentView

		// Container layer that lays the two screens side by side (width: width * 2)
		let containerLayer = CALayer()
		containerLayer.frame = CGRect(x: 0, y: 0, width: width * 2, height: height)

		let leftLayer = CALayer()
		leftLayer.frame = CGRect(x: 0, y: 0, width: width, height: height)
		leftLayer.contentsScale = screen.backingScaleFactor
		leftLayer.contentsGravity = .resizeAspectFill

		let rightLayer = CALayer()
		rightLayer.frame = CGRect(x: width, y: 0, width: width, height: height)
		rightLayer.contentsScale = screen.backingScaleFactor
		rightLayer.contentsGravity = .resizeAspectFill

		let startX: CGFloat
		let endX: CGFloat

		if isMovingNext {
			// +1 (next): old on the left, new on the right. The container slides from 0 to -width
			leftLayer.contents = oldSnapshot
			rightLayer.contents = newSnapshot
			startX = 0
			endX = -width
		} else {
			// -1 (previous): new on the left, old on the right. The container slides from -width to 0
			leftLayer.contents = newSnapshot
			rightLayer.contents = oldSnapshot
			startX = -width
			endX = 0
		}

		containerLayer.addSublayer(leftLayer)
		containerLayer.addSublayer(rightLayer)
		contentView.layer?.addSublayer(containerLayer)

		// Set the initial position
		containerLayer.transform = CATransform3DMakeTranslation(startX, 0, 0)
		overlay.orderFront(nil as Any?)
		overlayWindows[screenID] = overlay

		// Run the animation
		CATransaction.begin()
		CATransaction.setAnimationDuration(transitionDuration)
		CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)) // 臨界減衰バネ

		CATransaction.setCompletionBlock { [weak self, weak overlay] in
			overlay?.orderOut(nil as Any?)
			if let self = self {
				self.overlayWindows.removeValue(forKey: screenID)
			}
		}

		let anim = CABasicAnimation(keyPath: "transform.translation.x")
		anim.fromValue = startX
		anim.toValue = endX
		anim.duration = transitionDuration
		anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
		anim.fillMode = .forwards
		anim.isRemovedOnCompletion = false
		containerLayer.add(anim, forKey: "slide")

		CATransaction.commit()
	}
}
