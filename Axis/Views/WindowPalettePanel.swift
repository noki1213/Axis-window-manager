//
//  WindowPalettePanel.swift
//  Axis
//
//  Created on 2026/01/31.
//

import AppKit

/// Data displayed in the window palette (for a single window)
struct WindowPaletteItem {
	let windowID: CGWindowID
	let appName: String
	let windowTitle: String
	let appIcon: NSImage?
	let workspace: Int
	let screenID: ScreenIdentifier
}

/// A section for a single workspace (Space)
struct WindowPaletteSection {
	let workspace: Int
	var items: [WindowPaletteItem]
}

/// Data for a single monitor (Display)
struct WindowPaletteDisplay {
	let displayNumber: Int
	let screenID: ScreenIdentifier
	var spaces: [WindowPaletteSection]
}

/// A translucent panel that shows the window list
/// Display columns run left to right, with Spaces stacked vertically within each column
class WindowPalettePanel: NSPanel {

	// MARK: - Properties

	/// Data per Display
	private var displays: [WindowPaletteDisplay] = []

	/// The selected Display index
	private var selectedDisplayIndex: Int = 0

	/// The selected Space index
	private var selectedSpaceIndex: Int = 0

	/// The selected window index
	private var selectedItemIndex: Int = 0

	/// A 3D array of card views
	/// cardViews[displayIndex][spaceIndex][itemIndex]
	private var cardViews: [[[WindowPaletteItemView]]] = []

	/// The main horizontal stack (lays Display columns out side by side)
	private let mainHorizontalStack = NSStackView()

	/// The visual effect view used for the background blur
	private let visualEffectView = NSVisualEffectView()

	/// The spacing between cards
	private let cardSpacing: CGFloat = 8

	/// The spacing between Space sections
	private let sectionSpacing: CGFloat = 10

	/// Spacing between Display columns
	private let displaySpacing: CGFloat = 20

	/// The margin around the panel
	private let panelPadding: CGFloat = 16

	/// The height of the Space label
	private let labelHeight: CGFloat = 18

	/// The height of the Display title
	private let displayTitleHeight: CGFloat = 22

	/// Animation token (for handling re-entrancy)
	private var animationToken: Int = 0

	/// Whether a hide animation is currently in progress
	private var isHiding: Bool = false

	// MARK: - Init

	init() {
		super.init(
			contentRect: .zero,
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)

		// Basic panel setup (same pattern as GapOverlayWindow)
		self.isOpaque = false
		self.backgroundColor = .clear
		self.level = .floating
		self.isFloatingPanel = true
		self.hidesOnDeactivate = false
		self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
		self.hasShadow = true

		setupViews()
	}

	// MARK: - Setup

	private func setupViews() {
		// The background blur view
		visualEffectView.material = .hudWindow
		visualEffectView.blendingMode = .behindWindow
		visualEffectView.state = .active
		visualEffectView.wantsLayer = true
		visualEffectView.layer?.cornerRadius = 12
		visualEffectView.layer?.masksToBounds = true

		// Main stack (horizontal: Display columns)
		mainHorizontalStack.orientation = .horizontal
		mainHorizontalStack.alignment = .top
		mainHorizontalStack.spacing = displaySpacing
		mainHorizontalStack.translatesAutoresizingMaskIntoConstraints = false

		// Add the main stack directly to the visual effect view
		visualEffectView.addSubview(mainHorizontalStack)
		visualEffectView.translatesAutoresizingMaskIntoConstraints = false

		self.contentView = visualEffectView

		NSLayoutConstraint.activate([
			mainHorizontalStack.topAnchor.constraint(equalTo: visualEffectView.topAnchor, constant: panelPadding),
			mainHorizontalStack.bottomAnchor.constraint(lessThanOrEqualTo: visualEffectView.bottomAnchor, constant: -panelPadding),
			mainHorizontalStack.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: panelPadding),
			mainHorizontalStack.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -panelPadding),
		])
	}

	/// Set the contentView's layer.anchorPoint to the center (0.5, 0.5) and correct the position accordingly
	private func setupContentViewLayer() {
		guard let contentView = self.contentView else { return }
		contentView.wantsLayer = true
		guard let layer = contentView.layer else { return }
		let bounds = layer.bounds
		layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
		layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
	}

	// MARK: - Public Methods

	/// Set the Display data and show the panel (with a fade-in and scale-up animation)
	func showWithDisplays(_ newDisplays: [WindowPaletteDisplay], displayIndex: Int, spaceIndex: Int, itemIndex: Int) {
		self.displays = newDisplays
		self.selectedDisplayIndex = displayIndex
		self.selectedSpaceIndex = spaceIndex
		self.selectedItemIndex = itemIndex

		rebuildViews()
		updateSelection()
		positionOnScreen()

		animationToken += 1
		isHiding = false

		setupContentViewLayer()

		// If currently hidden or at alpha 0, start from the initial state (alpha: 0, scale: 0.96)
		let isCurrentlyInvisible = !self.isVisible || self.alphaValue == 0
		if isCurrentlyInvisible {
			self.alphaValue = 0.0
			self.contentView?.layer?.transform = CATransform3DMakeScale(0.96, 0.96, 1.0)
		}

		self.orderFrontRegardless()

		NSAnimationContext.runAnimationGroup { context in
			context.duration = 0.12
			context.timingFunction = CAMediaTimingFunction(name: .easeOut)
			context.allowsImplicitAnimation = true
			self.animator().alphaValue = 1.0
			self.contentView?.animator().layer?.transform = CATransform3DIdentity
		}
	}

	/// Update the selection position
	func updateSelection(displayIndex: Int, spaceIndex: Int, itemIndex: Int) {
		self.selectedDisplayIndex = displayIndex
		self.selectedSpaceIndex = spaceIndex
		self.selectedItemIndex = itemIndex
		updateSelection()
	}

	/// Close the panel (with a fade-out and scale-down animation)
	func hidePanel() {
		guard self.isVisible && self.alphaValue > 0 else {
			self.orderOut(nil)
			return
		}

		animationToken += 1
		let currentToken = animationToken
		isHiding = true

		setupContentViewLayer()

		NSAnimationContext.runAnimationGroup({ context in
			context.duration = 0.09
			context.timingFunction = CAMediaTimingFunction(name: .easeIn)
			context.allowsImplicitAnimation = true
			self.animator().alphaValue = 0.0
			self.contentView?.animator().layer?.transform = CATransform3DMakeScale(0.98, 0.98, 1.0)
		}, completionHandler: { [weak self] in
			guard let self = self else { return }
			if self.animationToken == currentToken && self.isHiding {
				self.orderOut(nil)
				self.isHiding = false
				self.contentView?.layer?.transform = CATransform3DIdentity
			}
		})
	}

	// MARK: - Private Methods

	/// Return the label string for a Space section
	/// workspace == -3: Hidden (windows hidden with Ctrl+Opt+X, i.e. minimized)
	/// workspace == -2: Float (windows the user deliberately floated)
	/// workspace == -1: System (system-originated floating windows)
	/// Otherwise: a normal workspace number
	private static func sectionLabel(for workspace: Int) -> String {
		switch workspace {
		case -3: return "Hidden"
		case -2: return "Float"
		case -1: return "System"
		default: return "Space \(workspace)"
		}
	}

	/// Rebuild the whole view
	private func rebuildViews() {
		// Remove all existing views
		for displayCards in cardViews {
			for spaceCards in displayCards {
				for card in spaceCards {
					card.removeFromSuperview()
				}
			}
		}
		cardViews.removeAll()

		for view in mainHorizontalStack.arrangedSubviews {
			mainHorizontalStack.removeArrangedSubview(view)
			view.removeFromSuperview()
		}

		// Build each Display column
		for display in displays {
			// Container for the whole Display column (stacked vertically)
			let displayColumn = NSStackView()
			displayColumn.orientation = .vertical
			displayColumn.alignment = .leading
			displayColumn.spacing = sectionSpacing
			displayColumn.translatesAutoresizingMaskIntoConstraints = false

			// Display title
			let displayTitle = NSTextField(labelWithString: "Display \(display.displayNumber)")
			displayTitle.font = NSFont.systemFont(ofSize: 13, weight: .bold)
			displayTitle.textColor = NSColor.white.withAlphaComponent(0.7)
			displayTitle.translatesAutoresizingMaskIntoConstraints = false
			displayColumn.addArrangedSubview(displayTitle)

			var displayCardViews: [[WindowPaletteItemView]] = []

			// Each Space section
			for space in display.spaces {
				// Space label
				// The Float section (workspace == -2, windows the user has floated) is labeled "Float",
				// The System section (workspace == -1, system-originated floating windows) is displayed as "System"
				let spaceLabel = NSTextField(labelWithString: WindowPalettePanel.sectionLabel(for: space.workspace))
				spaceLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
				spaceLabel.textColor = NSColor.white.withAlphaComponent(0.4)
				spaceLabel.translatesAutoresizingMaskIntoConstraints = false

				// Stack that lays cards out horizontally
				let cardRow = NSStackView()
				cardRow.orientation = .horizontal
				cardRow.spacing = cardSpacing
				cardRow.translatesAutoresizingMaskIntoConstraints = false

				var spaceCardViews: [WindowPaletteItemView] = []

				for item in space.items {
					let card = WindowPaletteItemView()
					card.translatesAutoresizingMaskIntoConstraints = false
					card.configure(
						icon: item.appIcon,
						appName: item.appName,
						windowTitle: item.windowTitle
					)

					NSLayoutConstraint.activate([
						card.widthAnchor.constraint(equalToConstant: WindowPaletteItemView.cardWidth),
						card.heightAnchor.constraint(equalToConstant: WindowPaletteItemView.cardHeight),
					])

					cardRow.addArrangedSubview(card)
					spaceCardViews.append(card)
				}

				displayCardViews.append(spaceCardViews)

				// Space section (label + card row)
				let spaceSection = NSStackView()
				spaceSection.orientation = .vertical
				spaceSection.alignment = .leading
				spaceSection.spacing = 4
				spaceSection.translatesAutoresizingMaskIntoConstraints = false

				spaceSection.addArrangedSubview(spaceLabel)
				spaceSection.addArrangedSubview(cardRow)

				displayColumn.addArrangedSubview(spaceSection)
			}

			cardViews.append(displayCardViews)

			// Set a minimum width for the Display column so the card doesn't shrink
			let maxCards = display.spaces.map { $0.items.count }.max() ?? 1
			let columnWidth = CGFloat(maxCards) * (WindowPaletteItemView.cardWidth + cardSpacing) - cardSpacing
			displayColumn.widthAnchor.constraint(greaterThanOrEqualToConstant: columnWidth).isActive = true
			displayColumn.setContentCompressionResistancePriority(.required, for: .horizontal)

			// Add a divider between Display columns if there is one
			if !mainHorizontalStack.arrangedSubviews.isEmpty {
				let separator = NSView()
				separator.wantsLayer = true
				separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
				separator.translatesAutoresizingMaskIntoConstraints = false
				NSLayoutConstraint.activate([
					separator.widthAnchor.constraint(equalToConstant: 1),
				])
				mainHorizontalStack.addArrangedSubview(separator)
			}

			mainHorizontalStack.addArrangedSubview(displayColumn)
		}
	}

	/// Update the selection state
	private func updateSelection() {
		for (dIndex, displayCards) in cardViews.enumerated() {
			for (sIndex, spaceCards) in displayCards.enumerated() {
				for (iIndex, card) in spaceCards.enumerated() {
					card.isSelected = (dIndex == selectedDisplayIndex
						&& sIndex == selectedSpaceIndex
						&& iIndex == selectedItemIndex)
				}
			}
		}
	}

	/// Center the panel on screen
	private func positionOnScreen() {
		guard let screen = NSScreen.main else { return }

		// Calculate the width of each Display column
		var totalWidth: CGFloat = 0
		for display in displays {
			let maxCards = display.spaces.map { $0.items.count }.max() ?? 1
			let columnWidth = CGFloat(maxCards) * (WindowPaletteItemView.cardWidth + cardSpacing) - cardSpacing
			totalWidth += columnWidth
		}
		// Spacing and divider between Display columns
		if displays.count > 1 {
			totalWidth += CGFloat(displays.count - 1) * (displaySpacing + 1)
		}
		let panelWidth = min(totalWidth + panelPadding * 2, screen.frame.width)

		// Panel height: match whichever Display has the most Spaces
		let maxSpaces = displays.map { $0.spaces.count }.max() ?? 1
		let spaceHeight = labelHeight + 4 + WindowPaletteItemView.cardHeight
		let contentHeight = displayTitleHeight + sectionSpacing
			+ CGFloat(maxSpaces) * spaceHeight
			+ CGFloat(max(maxSpaces - 1, 0)) * sectionSpacing
		let panelHeight = min(contentHeight + panelPadding * 2, screen.frame.height * 0.7)

		let panelFrame = NSRect(
			x: screen.frame.midX - panelWidth / 2,
			y: screen.frame.midY - panelHeight / 2,
			width: panelWidth,
			height: panelHeight
		)

		self.setFrame(panelFrame, display: true)
	}

	// MARK: - NSPanel Override

	override var canBecomeKey: Bool { false }
	override var canBecomeMain: Bool { false }
}
