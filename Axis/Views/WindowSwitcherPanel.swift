//
//  WindowSwitcherPanel.swift
//  Axis
//
//  Created on 2026/01/31.
//

import AppKit

/// Display data for the window switcher (one entry per window)
struct WindowSwitcherItem {
	let windowID: CGWindowID
	let appName: String
	let windowTitle: String
	let appIcon: NSImage?
	let workspace: Int
	let screenID: ScreenIdentifier
}

/// A section for a single workspace (Space)
struct WindowSwitcherSection {
	let workspace: Int
	var items: [WindowSwitcherItem]
}

/// Data for a single monitor (Display)
struct WindowSwitcherDisplay {
	let displayNumber: Int
	let screenID: ScreenIdentifier
	var spaces: [WindowSwitcherSection]
}

/// A translucent panel that shows the window list
/// Display columns run left to right, with Spaces stacked vertically within each column
class WindowSwitcherPanel: NSPanel {

	// MARK: - Properties

	/// Data per Display
	private var displays: [WindowSwitcherDisplay] = []

	/// The selected Display index
	private var selectedDisplayIndex: Int = 0

	/// The selected Space index
	private var selectedSpaceIndex: Int = 0

	/// The selected window index
	private var selectedItemIndex: Int = 0

	/// A 3D array of card views
	/// cardViews[displayIndex][spaceIndex][itemIndex]
	private var cardViews: [[[WindowSwitcherItemView]]] = []

	/// The main horizontal stack (lays Display columns out side by side)
	private let mainHorizontalStack = NSStackView()

	/// Scroll view
	private let scrollView = NSScrollView()

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

		// Scroll view
		scrollView.documentView = mainHorizontalStack
		scrollView.hasVerticalScroller = false
		scrollView.hasHorizontalScroller = false
		scrollView.drawsBackground = false
		scrollView.translatesAutoresizingMaskIntoConstraints = false

		// Add the scroll view to the visual effect view
		visualEffectView.addSubview(scrollView)
		visualEffectView.translatesAutoresizingMaskIntoConstraints = false

		self.contentView = visualEffectView

		NSLayoutConstraint.activate([
			scrollView.topAnchor.constraint(equalTo: visualEffectView.topAnchor, constant: panelPadding),
			scrollView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor, constant: -panelPadding),
			scrollView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: panelPadding),
			scrollView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -panelPadding),
		])
	}

	// MARK: - Public Methods

	/// Set the Display data and show the panel
	func showWithDisplays(_ newDisplays: [WindowSwitcherDisplay], displayIndex: Int, spaceIndex: Int, itemIndex: Int) {
		self.displays = newDisplays
		self.selectedDisplayIndex = displayIndex
		self.selectedSpaceIndex = spaceIndex
		self.selectedItemIndex = itemIndex

		rebuildViews()
		updateSelection()
		positionOnScreen()

		self.orderFrontRegardless()
	}

	/// Update the selection position
	func updateSelection(displayIndex: Int, spaceIndex: Int, itemIndex: Int) {
		self.selectedDisplayIndex = displayIndex
		self.selectedSpaceIndex = spaceIndex
		self.selectedItemIndex = itemIndex
		updateSelection()
	}

	/// Close the panel
	func hidePanel() {
		self.orderOut(nil)
	}

	// MARK: - Private Methods

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

			var displayCardViews: [[WindowSwitcherItemView]] = []

			// Each Space section
			for space in display.spaces {
				// Space label
				let spaceLabel = NSTextField(labelWithString: "Space \(space.workspace)")
				spaceLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
				spaceLabel.textColor = NSColor.white.withAlphaComponent(0.4)
				spaceLabel.translatesAutoresizingMaskIntoConstraints = false

				// Stack that lays cards out horizontally
				let cardRow = NSStackView()
				cardRow.orientation = .horizontal
				cardRow.spacing = cardSpacing
				cardRow.translatesAutoresizingMaskIntoConstraints = false

				var spaceCardViews: [WindowSwitcherItemView] = []

				for item in space.items {
					let card = WindowSwitcherItemView()
					card.translatesAutoresizingMaskIntoConstraints = false
					card.configure(
						icon: item.appIcon,
						appName: item.appName,
						windowTitle: item.windowTitle
					)

					NSLayoutConstraint.activate([
						card.widthAnchor.constraint(equalToConstant: WindowSwitcherItemView.cardWidth),
						card.heightAnchor.constraint(equalToConstant: WindowSwitcherItemView.cardHeight),
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
			let columnWidth = CGFloat(maxCards) * (WindowSwitcherItemView.cardWidth + cardSpacing) - cardSpacing
			totalWidth += columnWidth
		}
		// Spacing and divider between Display columns
		if displays.count > 1 {
			totalWidth += CGFloat(displays.count - 1) * (displaySpacing + 1)
		}
		let panelWidth = min(totalWidth + panelPadding * 2, screen.frame.width * 0.9)

		// Panel height: match whichever Display has the most Spaces
		let maxSpaces = displays.map { $0.spaces.count }.max() ?? 1
		let spaceHeight = labelHeight + 4 + WindowSwitcherItemView.cardHeight
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
