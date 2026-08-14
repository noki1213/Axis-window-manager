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
	/// A relaxed, smooth decay time close to macOS's built-in Spaces switching
	private let transitionDuration: TimeInterval = 0.36

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
	///   - completion: handler called after the animation finishes
	func performSlideTransition(
		oldSnapshot: CGImage,
		newSnapshot: CGImage,
		isMovingNext: Bool,
		on screen: NSScreen,
		completion: (() -> Void)? = nil
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
		overlay.backgroundColor = .black
		overlay.level = .floating + 20
		overlay.ignoresMouseEvents = true
		overlay.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
		overlay.isReleasedWhenClosed = false

		let width = screenFrame.width
		let height = screenFrame.height
		let gap: CGFloat = 16.0 // 画面間のわずかなセパレータ余白（macOS Spacesの立体感）

		let contentView = NSView(frame: NSRect(origin: .zero, size: screenFrame.size))
		contentView.wantsLayer = true
		contentView.layer?.masksToBounds = true
		overlay.contentView = contentView

		// Container layer that lays the two screens side by side (width: (width + gap) * 2)
		let containerLayer = CALayer()
		containerLayer.frame = CGRect(x: 0, y: 0, width: (width + gap) * 2, height: height)

		let leftLayer = CALayer()
		leftLayer.frame = CGRect(x: 0, y: 0, width: width, height: height)
		leftLayer.contentsScale = screen.backingScaleFactor
		leftLayer.contentsGravity = .resizeAspectFill
		leftLayer.shadowColor = NSColor.black.cgColor
		leftLayer.shadowOpacity = 0.35
		leftLayer.shadowRadius = 20
		leftLayer.shadowOffset = CGSize(width: 0, height: 0)

		let rightLayer = CALayer()
		rightLayer.frame = CGRect(x: width + gap, y: 0, width: width, height: height)
		rightLayer.contentsScale = screen.backingScaleFactor
		rightLayer.contentsGravity = .resizeAspectFill
		rightLayer.shadowColor = NSColor.black.cgColor
		rightLayer.shadowOpacity = 0.35
		rightLayer.shadowRadius = 20
		rightLayer.shadowOffset = CGSize(width: 0, height: 0)

		let startX: CGFloat
		let endX: CGFloat

		if isMovingNext {
			// +1 (next): old on the left, new on the right. The container slides from 0 to -(width + gap)
			leftLayer.contents = oldSnapshot
			rightLayer.contents = newSnapshot
			startX = 0
			endX = -(width + gap)
		} else {
			// -1 (previous): new on the left, old on the right. The container slides from -(width + gap) to 0
			leftLayer.contents = newSnapshot
			rightLayer.contents = oldSnapshot
			startX = -(width + gap)
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
		// A decay curve that accelerates smoothly from the initial velocity and eases softly down to zero at the end
		CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.25, 1.0))

		CATransaction.setCompletionBlock { [weak self, weak overlay] in
			// Fade very slightly before handing off to the real window, to avoid a jarring landing
			NSAnimationContext.runAnimationGroup({ context in
				context.duration = 0.05
				overlay?.animator().alphaValue = 0.0
			}, completionHandler: {
				overlay?.orderOut(nil as Any?)
				overlay?.alphaValue = 1.0
				if let self = self {
					self.overlayWindows.removeValue(forKey: screenID)
				}
				completion?()
			})
		}

		let anim = CABasicAnimation(keyPath: "transform.translation.x")
		anim.fromValue = startX
		anim.toValue = endX
		anim.duration = transitionDuration
		anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.25, 1.0)
		anim.fillMode = .forwards
		anim.isRemovedOnCompletion = false
		containerLayer.add(anim, forKey: "slide")

		CATransaction.commit()
	}
}
