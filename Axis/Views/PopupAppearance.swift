//
//  PopupAppearance.swift
//  Axis
//
//  Created on 2026/08/13.
//

import AppKit

/// The look and appearance animation of popups (the window palette, the neighboring-Space peek), and
/// Consolidated into one place.
///
/// Look: 55% black layered over the hudWindow's blur, with 22pt continuous corner rounding, and
/// Adds a 1px border at 12% white.
/// Appearance: driven by a single progress value, animating scale (0.94→1.0), blur (12→0), and opacity (0→1)
/// into three. The motion is a spring with no bounce, 0.30 seconds.
/// On dismissal: disappear instantly with no animation.
enum PopupAppearance {

	// MARK: - Appearance constants

	/// The corner radius
	static let cornerRadius: CGFloat = 22

	/// The black overlay on the backing (#262427 at 55%)
	static let backgroundColor = NSColor(srgbRed: 0x26 / 255.0, green: 0x24 / 255.0, blue: 0x27 / 255.0, alpha: 0.55)

	/// Border (white at 12% opacity)
	static let borderColor = NSColor.white.withAlphaComponent(0.12)

	// MARK: - Animation constants

	/// The duration of the appearance animation
	private static let appearDuration: TimeInterval = 0.30

	/// The scale factor before it appears
	private static let startScale: CGFloat = 0.94

	/// The blur radius before it appears
	private static let startBlurRadius: CGFloat = 12

	/// The fade duration when reduceMotion is on
	private static let reducedDuration: TimeInterval = 0.12

	/// The name given to the blur filter (needed to animate it via key path)
	private static let blurFilterName = "axisPopupBlur"

	/// Whether "Reduce Motion" is on
	private static var reduceMotion: Bool {
		return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
	}

	// MARK: - Appearance

	/// Set up the panel's backing (rounded corners, border, black overlay) per the rules
	static func styleBackground(_ view: NSView) {
		view.wantsLayer = true
		guard let layer = view.layer else { return }
		layer.cornerRadius = cornerRadius
		layer.cornerCurve = .continuous
		layer.masksToBounds = true
		layer.backgroundColor = backgroundColor.cgColor
		layer.borderWidth = 1
		layer.borderColor = borderColor.cgColor
	}

	// MARK: - Appearing and disappearing

	/// Bring the window to the front with an appearance animation
	/// - Parameters:
	///   - window: the target window
	///   - orderFront: the actual bring-to-front action (passed in by the caller since panels and overlays call different methods)
	static func show(_ window: NSWindow, orderFront: () -> Void) {
		guard let contentView = window.contentView else {
			orderFront()
			window.alphaValue = 1.0
			return
		}

		contentView.wantsLayer = true
		guard let layer = contentView.layer else {
			orderFront()
			window.alphaValue = 1.0
			return
		}

		// Scale it up around its center
		layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
		layer.position = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)

		// Don't replay the appearance animation when only the content is swapped while it's already showing
		let wasInvisible = !window.isVisible || window.alphaValue == 0

		// Always clear anything left over from last time (otherwise it starts from the previous fading-out value)
		layer.removeAllAnimations()
		layer.transform = CATransform3DIdentity
		layer.filters = nil

		if reduceMotion {
			if wasInvisible { window.alphaValue = 0.0 }
			orderFront()
			NSAnimationContext.runAnimationGroup { context in
				context.duration = reducedDuration
				context.timingFunction = CAMediaTimingFunction(name: .easeOut)
				window.animator().alphaValue = 1.0
			}
			return
		}

		guard wasInvisible else {
			orderFront()
			window.alphaValue = 1.0
			return
		}

		window.alphaValue = 0.0
		orderFront()

		// Set up the blur as a named filter so it can be driven by progress
		if let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: startBlurRadius]) {
			blur.name = blurFilterName
			layer.filters = [blur]
		}

		CATransaction.begin()
		CATransaction.setCompletionBlock {
			// Remove the blur once it's finished appearing (leaving it on keeps costing rendering time)
			layer.filters = nil
		}

		let scale = CASpringAnimation(perceptualDuration: appearDuration, bounce: 0)
		scale.keyPath = "transform.scale"
		scale.fromValue = startScale
		scale.toValue = 1.0
		layer.add(scale, forKey: "axisPopupScale")

		if layer.filters != nil {
			let blurAnimation = CASpringAnimation(perceptualDuration: appearDuration, bounce: 0)
			blurAnimation.keyPath = "filters.\(blurFilterName).inputRadius"
			blurAnimation.fromValue = startBlurRadius
			blurAnimation.toValue = 0
			layer.setValue(0, forKeyPath: "filters.\(blurFilterName).inputRadius")
			layer.add(blurAnimation, forKey: "axisPopupBlur")
		}

		CATransaction.commit()

		NSAnimationContext.runAnimationGroup { context in
			context.duration = appearDuration
			context.timingFunction = CAMediaTimingFunction(name: .easeOut)
			window.animator().alphaValue = 1.0
		}
	}

	// MARK: - Frame movement animation

	/// Move the view to the target frame, with animation (or instantly)
	/// - Parameters:
	///   - view: the view being moved
	///   - targetFrame: the destination frame
	///   - animated: whether to animate (when false, it's placed instantly)
	static func animateFrame(of view: NSView, to targetFrame: NSRect, animated: Bool = true) {
		guard animated else {
			view.layer?.removeAllAnimations()
			view.frame = targetFrame
			return
		}

		if reduceMotion {
			NSAnimationContext.runAnimationGroup { context in
				context.duration = 0.1
				context.timingFunction = CAMediaTimingFunction(name: .easeOut)
				view.animator().frame = targetFrame
			}
			return
		}

		guard let layer = view.layer else {
			view.frame = targetFrame
			return
		}

		let oldPosition = layer.presentation()?.position ?? layer.position
		let oldBoundsSize = layer.presentation()?.bounds.size ?? layer.bounds.size

		// Update the model value
		view.frame = targetFrame

		let newPosition = layer.position
		let newBoundsSize = layer.bounds.size

		CATransaction.begin()

		let positionAnim = CASpringAnimation(perceptualDuration: 0.28, bounce: 0)
		positionAnim.keyPath = "position"
		positionAnim.fromValue = oldPosition
		positionAnim.toValue = newPosition

		let boundsAnim = CASpringAnimation(perceptualDuration: 0.28, bounce: 0)
		boundsAnim.keyPath = "bounds.size"
		boundsAnim.fromValue = oldBoundsSize
		boundsAnim.toValue = newBoundsSize

		layer.add(positionAnim, forKey: "highlightPosition")
		layer.add(boundsAnim, forKey: "highlightBoundsSize")

		CATransaction.commit()
	}

	/// Dismiss it immediately, without animation
	static func hide(_ window: NSWindow) {
		if let layer = window.contentView?.layer {
			layer.removeAllAnimations()
			layer.filters = nil
			layer.transform = CATransform3DIdentity
		}
		window.orderOut(nil)
		window.alphaValue = 0.0
	}
}
