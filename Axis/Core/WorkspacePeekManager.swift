//
//  WorkspacePeekManager.swift
//  Axis
//
//  Created on 2026/08/05.
//

import AppKit

/// The class that manages the neighboring-workspace peek
/// Holding Ctrl+Option (modifier keys only) shows, at the left edge of each monitor, the left-neighboring workspace's
/// Show the right-neighboring workspace's app icons stacked vertically at the right edge. When the modifier key is released, or
/// Dismiss it immediately if another key is pressed.
class WorkspacePeekManager {
	static let shared = WorkspacePeekManager()

	/// The delay before showing (to avoid false triggers). Tune this one value to adjust the feel
	static let showDelay: TimeInterval = 0.2

	/// Whether exactly Ctrl+Option is currently held
	private var isModifierHeld = false

	/// The delayed task waiting to show it
	private var pendingShowWorkItem: DispatchWorkItem?

	/// The currently displayed overlay window (one per monitor)
	private var overlayWindows: [WorkspacePeekOverlayWindow] = []

	private init() {}

	// MARK: - Input from flagsChanged

	/// Called from a flagsChanged event. Passes whether exactly Ctrl+Option is held
	/// - Parameter isExactlyCtrlOption: whether exactly Ctrl+Option is held (no other modifier keys)
	func handleModifiersChanged(isExactlyCtrlOption: Bool) {
		if isExactlyCtrlOption {
			// Do nothing if it's already recognized as being held down
			guard !isModifierHeld else { return }
			isModifierHeld = true
			scheduleShow()
		} else {
			isModifierHeld = false
			cancelPendingShow()
			hide()
		}
	}

	/// Called when a normal key input (i.e. a shortcut operation) occurs
	/// Cancel a pending peek preview, and dismiss it immediately if it's already showing
	func cancelDueToKeyPress() {
		cancelPendingShow()
		hide()
	}

	// MARK: - Display control

	private func scheduleShow() {
		cancelPendingShow()

		let workItem = DispatchWorkItem { [weak self] in
			self?.show()
		}
		pendingShowWorkItem = workItem
		DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay, execute: workItem)
	}

	private func cancelPendingShow() {
		pendingShowWorkItem?.cancel()
		pendingShowWorkItem = nil
	}

	/// Show the peek-preview overlay on every monitor
	private func show() {
		// Do nothing if the modifier key was released while showing (a belt-and-suspenders double check)
		guard isModifierHeld else { return }

		hide()

		for screen in NSScreen.screens {
			let currentWS = WorkspaceManager.shared.currentWorkspace(on: screen)

			let leftIcons = appIcons(inWorkspace: currentWS - 1, on: screen)
			let rightIcons = appIcons(inWorkspace: currentWS + 1, on: screen)

			// Don't create the overlay at all if there's nothing to show on either side
			guard !leftIcons.isEmpty || !rightIcons.isEmpty else { continue }

			let overlay = WorkspacePeekOverlayWindow()
			overlay.show(on: screen, leftIcons: leftIcons, rightIcons: rightIcons)
			overlayWindows.append(overlay)
		}
	}

	/// Hide all overlays
	private func hide() {
		guard !overlayWindows.isEmpty else { return }
		for overlay in overlayWindows {
			overlay.hide()
		}
		overlayWindows.removeAll()
	}

	// MARK: - Icon fetching

	/// Return deduplicated app icons, in tiling order, for the windows belonging to the given monitor and workspace
	private func appIcons(inWorkspace workspace: Int, on screen: NSScreen) -> [NSImage] {
		let orderedIDs = WorkspaceManager.shared.windowIDsInTilingOrder(workspace: workspace, on: screen)
		guard !orderedIDs.isEmpty else { return [] }

		let allWindows = AccessibilityManager.shared.getAllWindows()
		let windowsByID = Dictionary(uniqueKeysWithValues: allWindows.map { ($0.id, $0) })

		var seenApps = Set<pid_t>()
		var icons: [NSImage] = []

		for windowID in orderedIDs {
			guard let window = windowsByID[windowID] else { continue }
			let pid = window.app.processIdentifier

			// Show only one icon even if the same app has multiple windows
			guard !seenApps.contains(pid) else { continue }
			seenApps.insert(pid)

			if let icon = window.app.icon {
				icons.append(icon)
			}
		}

		return icons
	}
}

// MARK: - WorkspacePeekOverlayWindow

/// The overlay window responsible for showing the peek preview (one is created per monitor)
/// To never steal focus, treat it as a non-activating panel and ignore mouse events too
private class WorkspacePeekOverlayWindow: NSWindow {

	private let peekView = WorkspacePeekView()

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

		self.contentView = peekView
	}

	/// Show the peek preview on the given monitor
	func show(on screen: NSScreen, leftIcons: [NSImage], rightIcons: [NSImage]) {
		self.setFrame(screen.frame, display: true)
		peekView.update(leftIcons: leftIcons, rightIcons: rightIcons, screenSize: screen.frame.size)
		self.orderFront(nil)
	}

	/// Hide the overlay
	func hide() {
		self.orderOut(nil)
	}
}

// MARK: - WorkspacePeekView

/// The view that draws the left and right icon panels for the peek preview
private class WorkspacePeekView: NSView {

	/// Icon size
	private static let iconSize: CGFloat = 40
	/// Spacing between icons
	private static let iconSpacing: CGFloat = 12
	/// The padding inside the panel
	private static let panelPadding: CGFloat = 10
	/// Distance from the screen edge to the panel
	private static let edgeInset: CGFloat = 16
	/// The panel's corner radius
	private static let cornerRadius: CGFloat = 14

	private var leftPanel: NSVisualEffectView?
	private var rightPanel: NSVisualEffectView?

	/// Update the left and right icon lists and re-lay them out
	func update(leftIcons: [NSImage], rightIcons: [NSImage], screenSize: CGSize) {
		subviews.forEach { $0.removeFromSuperview() }
		leftPanel = nil
		rightPanel = nil

		if !leftIcons.isEmpty {
			let panel = Self.makePanel(icons: leftIcons)
			addSubview(panel)
			leftPanel = panel
		}
		if !rightIcons.isEmpty {
			let panel = Self.makePanel(icons: rightIcons)
			addSubview(panel)
			rightPanel = panel
		}

		layoutPanels(screenSize: screenSize)
	}

	/// Build a translucent panel for one row of icons (size derived from the icon count, laid out with an explicit frame)
	private static func makePanel(icons: [NSImage]) -> NSVisualEffectView {
		let count = icons.count
		let width = iconSize + panelPadding * 2
		let height = CGFloat(count) * iconSize + CGFloat(max(0, count - 1)) * iconSpacing + panelPadding * 2

		let panel = NSVisualEffectView(frame: CGRect(x: 0, y: 0, width: width, height: height))
		panel.material = .hudWindow
		panel.state = .active
		panel.blendingMode = .withinWindow
		panel.wantsLayer = true
		panel.layer?.cornerRadius = cornerRadius
		panel.layer?.masksToBounds = true

		// NSView's origin is at the bottom-left, so stack from the bottom up to get top-to-bottom ordering
		for (index, icon) in icons.enumerated() {
			let y = height - panelPadding - iconSize - CGFloat(index) * (iconSize + iconSpacing)
			let imageView = NSImageView(frame: CGRect(x: panelPadding, y: y, width: iconSize, height: iconSize))
			imageView.image = icon
			imageView.imageScaling = .scaleProportionallyUpOrDown
			panel.addSubview(imageView)
		}

		return panel
	}

	/// Position the panel vertically centered and aligned to the monitor's edge
	private func layoutPanels(screenSize: CGSize) {
		if let panel = leftPanel {
			var frame = panel.frame
			frame.origin = CGPoint(x: Self.edgeInset, y: (screenSize.height - frame.height) / 2)
			panel.frame = frame
		}
		if let panel = rightPanel {
			var frame = panel.frame
			frame.origin = CGPoint(x: screenSize.width - Self.edgeInset - frame.width, y: (screenSize.height - frame.height) / 2)
			panel.frame = frame
		}
	}
}
