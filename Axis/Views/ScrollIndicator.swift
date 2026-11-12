//
//  ScrollIndicator.swift
//  Axis
//
//  Replaces the system scroller with a short segment riding on the line at a scroll view's
//  trailing edge, so the position shows without adding a bar of its own. The segment can be
//  dragged, and pressing the line jumps there. SwiftUI scroll views use `edgeScrollIndicator`,
//  AppKit scroll views use `EdgeScrollIndicatorView.attach(to:)`.
//

import SwiftUI
import AppKit

/// Where the visible part of a scroll view sits within its content,
/// measured along the scroll view's own height.
private struct ScrollThumb: Equatable {
	var start: CGFloat
	var length: CGFloat
	/// Height of the scroll view, which is the track the segment moves along.
	var track: CGFloat
	/// How far the content can scroll.
	var range: CGFloat
	var insetTop: CGFloat

	static let minLength: CGFloat = 24

	/// Nil when everything fits and there is nothing to scroll.
	/// `scrolled` is the distance from the top of the content to the top of the visible part.
	static func from(visible: CGFloat, content: CGFloat, scrolled: CGFloat, insetTop: CGFloat) -> ScrollThumb? {
		guard visible > 0, content > visible + 0.5 else { return nil }
		// Half the proportional length, capped at 30% of the view: a full-size
		// segment on a slightly-too-long list reads as a heavy bar, not a marker.
		let length = max(minLength, min(visible * 0.3, visible * visible / content * 0.5))
		let range = content - visible
		let progress = min(max(scrolled / range, 0), 1)
		return ScrollThumb(
			start: (visible - length) * progress,
			length: length,
			track: visible,
			range: range,
			insetTop: insetTop
		)
	}

	@available(macOS 15, *)
	static func from(_ geometry: ScrollGeometry) -> ScrollThumb? {
		from(
			visible: geometry.containerSize.height,
			content: geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom,
			scrolled: geometry.contentOffset.y + geometry.contentInsets.top,
			insetTop: geometry.contentInsets.top
		)
	}

	/// The content offset that puts the segment's top at `start`.
	func offset(forStart start: CGFloat) -> CGFloat {
		let travel = track - length
		let progress = travel > 0 ? min(max(start / travel, 0), 1) : 0
		return progress * range - insetTop
	}

	/// Distance from the segment's top to a press at `y`: inside the segment it is kept,
	/// elsewhere the segment's centre jumps to the press.
	func grab(at y: CGFloat) -> CGFloat {
		y >= start && y <= start + length ? y - start : length / 2
	}
}

private enum ScrollIndicatorStyle {
	static let width: CGFloat = 2
	static let activeWidth: CGFloat = 4
	static let opacity: Double = 0.75
	/// Wider than the segment so it can be grabbed without aiming at 2pt.
	static let hitWidth: CGFloat = 12
	static let duration: Double = 0.12
}

// MARK: - SwiftUI

@available(macOS 15, *)
private struct EdgeScrollIndicator: ViewModifier {
	let offset: CGFloat
	@State private var thumb: ScrollThumb?
	@State private var position = ScrollPosition()
	@State private var isHovered = false
	/// Distance from the segment's top to the pointer while dragging.
	@State private var grab: CGFloat?

	func body(content: Content) -> some View {
		content
			.scrollIndicators(.never)
			.scrollPosition($position)
			.onScrollGeometryChange(for: ScrollThumb?.self, of: ScrollThumb.from) { _, new in
				thumb = new
			}
			.overlay(alignment: .topTrailing) {
				if let thumb {
					let isActive = isHovered || grab != nil
					let width = isActive ? ScrollIndicatorStyle.activeWidth : ScrollIndicatorStyle.width
					Capsule()
						.fill(Palette.green.opacity(isActive ? 1 : ScrollIndicatorStyle.opacity))
						.frame(width: width, height: thumb.length)
						// Keep the segment centred on the line as it widens.
						.offset(x: offset + (width - ScrollIndicatorStyle.width) / 2, y: thumb.start)
						.allowsHitTesting(false)
						.animation(.easeOut(duration: ScrollIndicatorStyle.duration), value: isActive)
				}
			}
			.overlay(alignment: .topTrailing) {
				if let thumb {
					Color.clear
						.frame(width: ScrollIndicatorStyle.hitWidth, height: thumb.track)
						.contentShape(Rectangle())
						.offset(x: offset + (ScrollIndicatorStyle.hitWidth - ScrollIndicatorStyle.width) / 2)
						.onHover { isHovered = $0 }
						.gesture(drag)
				}
			}
	}

	private var drag: some Gesture {
		DragGesture(minimumDistance: 0)
			.onChanged { value in
				guard let current = self.thumb else { return }
				if grab == nil {
					grab = current.grab(at: value.startLocation.y)
				}
				position.scrollTo(y: current.offset(forStart: value.location.y - (grab ?? 0)))
			}
			.onEnded { _ in grab = nil }
	}
}

extension View {
	/// Shows the scroll position as a segment on the line at the scroll view's trailing edge.
	/// `offset` shifts it right onto a line that sits outside the scroll view. Before macOS 15
	/// the system scroller is only hidden.
	@ViewBuilder
	func edgeScrollIndicator(offset: CGFloat = 0) -> some View {
		if #available(macOS 15, *) {
			modifier(EdgeScrollIndicator(offset: offset))
		} else {
			scrollIndicators(.never)
		}
	}
}

// MARK: - AppKit

/// The same segment for an NSScrollView with a flipped document view. It sits as a strip over
/// the scroll view's trailing edge, follows the clip view's scrolling, and handles hover and drag itself.
final class EdgeScrollIndicatorView: NSView {
	private weak var scrollView: NSScrollView?
	private let segment = CALayer()
	private var thumb: ScrollThumb?
	private var isHovered = false
	/// Distance from the segment's top to the pointer while dragging.
	private var grab: CGFloat?

	/// Hides the scroll view's scrollers and lays the segment on its trailing edge. `offset`
	/// shifts it right onto a line that sits outside the scroll view.
	@discardableResult
	static func attach(to scrollView: NSScrollView, offset: CGFloat = 0) -> EdgeScrollIndicatorView {
		scrollView.hasVerticalScroller = false
		scrollView.hasHorizontalScroller = false
		let indicator = EdgeScrollIndicatorView(scrollView: scrollView)
		indicator.translatesAutoresizingMaskIntoConstraints = false
		scrollView.addSubview(indicator)
		NSLayoutConstraint.activate([
			indicator.topAnchor.constraint(equalTo: scrollView.topAnchor),
			indicator.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
			indicator.widthAnchor.constraint(equalToConstant: ScrollIndicatorStyle.hitWidth),
			// Centre the strip on the segment's line.
			indicator.trailingAnchor.constraint(
				equalTo: scrollView.trailingAnchor,
				constant: offset + (ScrollIndicatorStyle.hitWidth - ScrollIndicatorStyle.width) / 2
			),
		])
		return indicator
	}

	private init(scrollView: NSScrollView) {
		self.scrollView = scrollView
		super.init(frame: .zero)
		wantsLayer = true
		segment.backgroundColor = NSPalette.green.cgColor
		layer?.addSublayer(segment)

		let clipView = scrollView.contentView
		clipView.postsBoundsChangedNotifications = true
		clipView.postsFrameChangedNotifications = true
		let center = NotificationCenter.default
		center.addObserver(self, selector: #selector(update), name: NSView.boundsDidChangeNotification, object: clipView)
		center.addObserver(self, selector: #selector(update), name: NSView.frameDidChangeNotification, object: clipView)
		if let document = scrollView.documentView {
			document.postsFrameChangedNotifications = true
			center.addObserver(self, selector: #selector(update), name: NSView.frameDidChangeNotification, object: document)
		}
	}

	required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

	deinit { NotificationCenter.default.removeObserver(self) }

	override var isFlipped: Bool { true }

	override func layout() {
		super.layout()
		update()
	}

	@objc private func update() {
		guard let scrollView, let document = scrollView.documentView else { return }
		let clipView = scrollView.contentView
		let insets = scrollView.contentInsets
		let visible = clipView.bounds.height
		let content = document.frame.height + insets.top + insets.bottom
		let scrolled = clipView.bounds.origin.y + insets.top
		thumb = ScrollThumb.from(visible: visible, content: content, scrolled: scrolled, insetTop: insets.top)
		isHidden = thumb == nil
		if thumb == nil { grab = nil }
		layoutSegment(animated: false)
	}

	private func layoutSegment(animated: Bool) {
		guard let thumb else { return }
		let isActive = isHovered || grab != nil
		let width = isActive ? ScrollIndicatorStyle.activeWidth : ScrollIndicatorStyle.width
		CATransaction.begin()
		if animated {
			CATransaction.setAnimationDuration(ScrollIndicatorStyle.duration)
			CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
		} else {
			CATransaction.setDisableActions(true)
		}
		segment.frame = CGRect(x: (bounds.width - width) / 2, y: thumb.start, width: width, height: thumb.length)
		segment.cornerRadius = width / 2
		segment.opacity = Float(isActive ? 1 : ScrollIndicatorStyle.opacity)
		CATransaction.commit()
	}

	private func setActive(hovered: Bool? = nil, grab newGrab: CGFloat?? = nil) {
		let wasActive = isHovered || grab != nil
		if let hovered { isHovered = hovered }
		if let newGrab { grab = newGrab }
		if wasActive != (isHovered || grab != nil) {
			layoutSegment(animated: true)
		}
	}

	// MARK: Hover and drag

	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		trackingAreas.forEach(removeTrackingArea)
		addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
	}

	override func mouseEntered(with event: NSEvent) { setActive(hovered: true) }
	override func mouseExited(with event: NSEvent) { setActive(hovered: false) }

	override func mouseDown(with event: NSEvent) {
		guard let thumb else { return }
		let y = convert(event.locationInWindow, from: nil).y
		setActive(grab: .some(thumb.grab(at: y)))
		scroll(toPointerAt: y)
	}

	override func mouseDragged(with event: NSEvent) {
		scroll(toPointerAt: convert(event.locationInWindow, from: nil).y)
	}

	override func mouseUp(with event: NSEvent) {
		setActive(grab: .some(nil))
	}

	private func scroll(toPointerAt y: CGFloat) {
		guard let thumb, let grab, let scrollView else { return }
		let clipView = scrollView.contentView
		clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: thumb.offset(forStart: y - grab)))
		scrollView.reflectScrolledClipView(clipView)
	}
}
