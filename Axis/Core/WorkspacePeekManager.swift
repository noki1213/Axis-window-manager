//
//  WorkspacePeekManager.swift
//  Axis
//
//  Created on 2026/08/05.
//

import AppKit

/// The class that manages the neighboring-workspace peek
/// Holding Ctrl+Option (modifier keys alone), while there's a focused window,
/// Displays two cards side by side at the center of the monitor, representing the neighboring workspaces to the left and right.
/// Dismiss it immediately when the modifier keys are released or another key is pressed.
class WorkspacePeekManager {
	static let shared = WorkspacePeekManager()

	/// The delay before showing (to avoid false triggers). Tune this one value to adjust the feel
	static let showDelay: TimeInterval = 0.08

	/// Whether exactly Ctrl+Option is currently held
	private var isModifierHeld = false

	/// The delayed task waiting to show it
	private var pendingShowWorkItem: DispatchWorkItem?

	/// The currently displayed overlay window
	private var overlayWindow: WorkspacePeekOverlayWindow?

	/// The display content gathered in advance at the moment the modifier key was pressed
	/// Since scanning windows at the moment of display makes it feel slow to appear,
	/// Gather it right after the press, so only drawing remains after the delay
	private var preparedContent: PeekContent?

	private init() {}

	// MARK: - Display content

	/// Info for a single window shown in the peek preview (same content as a window palette card)
	struct PeekItem {
		let icon: NSImage?
		let appName: String
		let windowTitle: String
	}

	/// The content shown in the peek preview
	private struct PeekContent {
		let screen: NSScreen
		let leftWorkspace: Int
		let leftItems: [PeekItem]
		let rightWorkspace: Int
		let rightItems: [PeekItem]

		/// There's no point showing it if both sides are empty
		var isEmpty: Bool {
			return leftItems.isEmpty && rightItems.isEmpty
		}
	}

	// MARK: - Input from flagsChanged

	/// Called from a flagsChanged event. Passes whether exactly Ctrl+Option is held
	/// - Parameter isExactlyCtrlOption: whether exactly Ctrl+Option is held (no other modifier keys)
	func handleModifiersChanged(isExactlyCtrlOption: Bool) {
		if isExactlyCtrlOption {
			// Do nothing if it's already recognized as being held down
			guard !isModifierHeld else { return }
			isModifierHeld = true
			prepareContent()
			scheduleShow()
		} else {
			isModifierHeld = false
			cancelPendingShow()
			preparedContent = nil
			hide()
		}
	}

	/// Called when a normal key input (i.e. a shortcut operation) occurs
	/// Cancel the scheduled peek preview, and dismiss it immediately if it's currently showing.
	/// However, if Ctrl+Option is still held down, regather the content and schedule it to show again
	/// (While held down for continuous operation it stays hidden each time, and reappears once your hand stops)
	func cancelDueToKeyPress() {
		cancelPendingShow()
		hide()

		if isModifierHeld {
			// The operation may have changed the workspace or window layout, so gather it again.
			// Right after key handling the change may not have taken effect yet, so defer to the next loop
			DispatchQueue.main.async { [weak self] in
				guard let self = self, self.isModifierHeld else { return }
				self.prepareContent()
			}
			scheduleShow()
		}
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

	/// Gather and cache the display content (heavy work is consolidated here)
	private func prepareContent() {
		guard let screen = targetScreen() else {
			preparedContent = nil
			return
		}

		let currentWS = WorkspaceManager.shared.currentWorkspace(on: screen)
		let leftWS = currentWS - 1
		let rightWS = currentWS + 1

		// Only fetch the window list once
		let allWindows = AccessibilityManager.shared.getAllWindows()
		let windowsByID = Dictionary(allWindows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

		preparedContent = PeekContent(
			screen: screen,
			leftWorkspace: leftWS,
			leftItems: peekItems(inWorkspace: leftWS, on: screen, windowsByID: windowsByID),
			rightWorkspace: rightWS,
			rightItems: peekItems(inWorkspace: rightWS, on: screen, windowsByID: windowsByID)
		)
	}

	/// Show the gathered content centered on the monitor
	private func show() {
		// Do nothing if the modifier key was released before it got shown (a just-in-case double check)
		guard isModifierHeld else { return }
		guard let content = preparedContent, !content.isEmpty else { return }

		hide()

		let overlay = WorkspacePeekOverlayWindow()
		overlay.show(
			on: content.screen,
			leftWorkspace: content.leftWorkspace,
			leftItems: content.leftItems,
			rightWorkspace: content.rightWorkspace,
			rightItems: content.rightItems
		)
		overlayWindow = overlay
	}

	/// Decide which monitor to show the peek preview on
	/// Shown, as a rule, on the monitor the focused window is on.
	/// cursorScreen (remembering that we're on an empty monitor) can keep lingering, and
	/// Since preferring it as-is would make it show up on a different monitor,
	/// Only use it when the mouse is actually on that monitor right now
	private func targetScreen() -> NSScreen? {
		if let cursorScreen = TilingEngine.shared.cursorScreen {
			let mouseLocation = NSEvent.mouseLocation
			if cursorScreen.frame.contains(mouseLocation) {
				return cursorScreen
			}
		}
		return WorkspaceManager.shared.focusedScreen()
	}

	/// Hide the overlay
	private func hide() {
		overlayWindow?.hide()
		overlayWindow = nil
	}

	// MARK: - Fetching display items

	/// Return the windows belonging to the given monitor and workspace, one at a time, in tiling order
	/// Emit one entry per window, so it's clear how many windows are next to it
	/// (If the same app has multiple windows open, the same icon appears that many times)
	private func peekItems(inWorkspace workspace: Int, on screen: NSScreen, windowsByID: [CGWindowID: WindowInfo]) -> [PeekItem] {
		let orderedIDs = WorkspaceManager.shared.windowIDsInTilingOrder(workspace: workspace, on: screen)
		guard !orderedIDs.isEmpty else { return [] }

		var items: [PeekItem] = []
		for windowID in orderedIDs {
			guard let window = windowsByID[windowID] else { continue }
			items.append(PeekItem(
				icon: window.app.icon,
				appName: window.app.localizedName ?? "",
				windowTitle: window.title
			))
		}
		return items
	}
}

// MARK: - WorkspacePeekOverlayWindow

/// The overlay window responsible for the peek display
/// To never steal focus, it ignores mouse events and never becomes the key window
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

	/// Doesn't become the key window (doesn't steal focus)
	override var canBecomeKey: Bool { return false }
	override var canBecomeMain: Bool { return false }

	/// Show the peek preview centered on the given monitor
	func show(on screen: NSScreen, leftWorkspace: Int, leftItems: [WorkspacePeekManager.PeekItem], rightWorkspace: Int, rightItems: [WorkspacePeekManager.PeekItem]) {
		self.setFrame(screen.frame, display: true)
		peekView.update(
			leftWorkspace: leftWorkspace,
			leftItems: leftItems,
			rightWorkspace: rightWorkspace,
			rightItems: rightItems,
			screenSize: screen.frame.size
		)
		self.orderFront(nil)
	}

	/// Hide the overlay
	func hide() {
		self.orderOut(nil)
	}
}

// MARK: - WorkspacePeekView

/// A view that draws the two left/right cards at the center of the screen
private class WorkspacePeekView: NSView {

	// MARK: Layout constants

	/// The spacing between individual window cards
	private static let itemSpacing: CGFloat = 8
	/// The padding inside the panel
	private static let cardPadding: CGFloat = 14
	/// The spacing between the label and the card row
	private static let labelGap: CGFloat = 10
	/// The label's height
	private static let labelHeight: CGFloat = 16
	/// The panel's minimum width
	private static let cardMinWidth: CGFloat = 132
	/// The gap between the left and right panels (this space indicates the left/right direction)
	private static let centerGap: CGFloat = 72
	/// The panel's corner radius
	private static let cornerRadius: CGFloat = 16
	/// The minimum margin to leave at the screen's left and right edges
	private static let screenMargin: CGFloat = 24

	// MARK: Color scheme

	/// The card's background (black #262427)
	private static let cardBackgroundColor = NSColor(srgbRed: 0x26 / 255.0, green: 0x24 / 255.0, blue: 0x27 / 255.0, alpha: 0.55)
	/// The card's border (light black #545252)
	private static let cardBorderColor = NSColor(srgbRed: 0x54 / 255.0, green: 0x52 / 255.0, blue: 0x52 / 255.0, alpha: 0.9)
	/// Label text (white, #c4c4c4)
	private static let labelColor = NSColor(srgbRed: 0xc4 / 255.0, green: 0xc4 / 255.0, blue: 0xc4 / 255.0, alpha: 1.0)
	/// The direction arrow (cyan, #4AAEC8)
	private static let arrowColor = NSColor(srgbRed: 0x4A / 255.0, green: 0xAE / 255.0, blue: 0xC8 / 255.0, alpha: 1.0)

	private var leftCard: NSView?
	private var rightCard: NSView?

	/// Update the display content and reposition it
	func update(leftWorkspace: Int, leftItems: [WorkspacePeekManager.PeekItem], rightWorkspace: Int, rightItems: [WorkspacePeekManager.PeekItem], screenSize: CGSize) {
		subviews.forEach { $0.removeFromSuperview() }
		leftCard = nil
		rightCard = nil

		// The width available on one side (half the screen, minus the center gap and the screen-edge margin)
		let availableWidth = screenSize.width / 2 - Self.centerGap / 2 - Self.screenMargin

		if !leftItems.isEmpty {
			let card = Self.makeCard(workspace: leftWorkspace, items: leftItems, isLeft: true, maxWidth: availableWidth)
			addSubview(card)
			leftCard = card
		}
		if !rightItems.isEmpty {
			let card = Self.makeCard(workspace: rightWorkspace, items: rightItems, isLeft: false, maxWidth: availableWidth)
			addSubview(card)
			rightCard = card
		}

		layoutCards(screenSize: screenSize)
	}

	/// Build the panel for a single workspace
	/// Lay out cards inside identical to the window palette's (icon + app name + window title), side by side
	/// - Parameters:
	///   - workspace: the workspace number (shown in the label)
	///   - items: the windows to lay out (in tiling order)
	///   - isLeft: true for the panel on the left (changes the arrow direction and alignment)
	///   - maxWidth: the max width available to this panel. Cards beyond it aren't laid out
	private static func makeCard(workspace: Int, items: [WorkspacePeekManager.PeekItem], isLeft: Bool, maxWidth: CGFloat) -> NSView {
		let itemWidth = WindowPaletteItemView.cardWidth
		let itemHeight = WindowPaletteItemView.cardHeight

		// Lay out only as many as fit within the width (drop whatever doesn't fit)
		let usableWidth = max(itemWidth, maxWidth - cardPadding * 2)
		let maxCount = max(1, Int((usableWidth + itemSpacing) / (itemWidth + itemSpacing)))
		let shownItems = Array(items.prefix(maxCount))

		let count = shownItems.count
		let itemsWidth = CGFloat(count) * itemWidth + CGFloat(max(0, count - 1)) * itemSpacing
		let width = max(cardMinWidth, itemsWidth + cardPadding * 2)
		let height = cardPadding * 2 + labelHeight + labelGap + itemHeight

		let card = NSVisualEffectView(frame: CGRect(x: 0, y: 0, width: width, height: height))
		card.material = .hudWindow
		card.state = .active
		card.blendingMode = .behindWindow
		card.wantsLayer = true
		card.layer?.cornerRadius = cornerRadius
		card.layer?.masksToBounds = true
		card.layer?.backgroundColor = cardBackgroundColor.cgColor
		card.layer?.borderWidth = 1
		card.layer?.borderColor = cardBorderColor.cgColor

		// Label (left reads "‹ Space N", right reads "Space N ›").
		// If some cards didn't fit, append "+N" at the end
		let hiddenCount = items.count - count
		let label = NSTextField(labelWithAttributedString: makeLabelText(workspace: workspace, isLeft: isLeft, hiddenCount: hiddenCount))
		label.frame = CGRect(
			x: cardPadding,
			y: height - cardPadding - labelHeight,
			width: width - cardPadding * 2,
			height: labelHeight
		)
		label.alignment = isLeft ? .left : .right
		card.addSubview(label)

		// The row of window cards (centered within the panel)
		let itemsStartX = (width - itemsWidth) / 2
		for (index, item) in shownItems.enumerated() {
			let x = itemsStartX + CGFloat(index) * (itemWidth + itemSpacing)
			let itemView = WindowPaletteItemView(frame: CGRect(x: x, y: cardPadding, width: itemWidth, height: itemHeight))
			itemView.configure(icon: item.icon, appName: item.appName, windowTitle: item.windowTitle)
			card.addSubview(itemView)
		}

		return card
	}

	/// Build the label's decorated string. Color just the arrow cyan to make the direction stand out
	/// - Parameter hiddenCount: the number of windows that didn't fit and weren't laid out (nothing is appended if 0)
	private static func makeLabelText(workspace: Int, isLeft: Bool, hiddenCount: Int) -> NSAttributedString {
		let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
		let arrowFont = NSFont.systemFont(ofSize: 13, weight: .bold)

		let result = NSMutableAttributedString()
		let arrow = NSAttributedString(
			string: isLeft ? "\u{2039}  " : "  \u{203A}",
			attributes: [.font: arrowFont, .foregroundColor: arrowColor]
		)
		var nameText = "Space \(workspace)"
		if hiddenCount > 0 {
			nameText += "  +\(hiddenCount)"
		}
		let name = NSAttributedString(
			string: nameText,
			attributes: [.font: font, .foregroundColor: labelColor]
		)

		if isLeft {
			result.append(arrow)
			result.append(name)
		} else {
			result.append(name)
			result.append(arrow)
		}
		return result
	}

	/// Place the two cards at the center of the screen, spaced apart on either side
	/// Even when only one side exists, show it at that side's fixed position so the direction is still readable
	private func layoutCards(screenSize: CGSize) {
		let centerX = screenSize.width / 2
		let centerY = screenSize.height / 2

		if let card = leftCard {
			var frame = card.frame
			frame.origin = CGPoint(
				x: centerX - Self.centerGap / 2 - frame.width,
				y: centerY - frame.height / 2
			)
			card.frame = frame
		}
		if let card = rightCard {
			var frame = card.frame
			frame.origin = CGPoint(
				x: centerX + Self.centerGap / 2,
				y: centerY - frame.height / 2
			)
			card.frame = frame
		}
	}
}
