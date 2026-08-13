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
/// Display rows are stacked from top to bottom, with Spaces laid out horizontally within each row
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

	/// The sliding selection highlight view
	private let highlightView = NSView()

	/// The main vertical stack (lays out Display rows vertically)
	private let mainVerticalStack = NSStackView()

	/// The visual effect view used for the background blur
	private let visualEffectView = NSVisualEffectView()

	/// The spacing between cards
	private let cardSpacing: CGFloat = 8

	/// The spacing between Space sections
	private let sectionSpacing: CGFloat = 10

	/// The spacing between Display rows
	private let displaySpacing: CGFloat = 16

	/// The margin around the panel
	private let panelPadding: CGFloat = 16

	/// The height of the Space label
	private let labelHeight: CGFloat = 18

	/// The spacing between the Space label and the card row
	private let labelSpacing: CGFloat = 4

	/// The height of the Display title
	private let displayTitleHeight: CGFloat = 22

	/// The spacing between the Display title and the Space row
	private let displayTitleSpacing: CGFloat = 6

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
		PopupAppearance.styleBackground(visualEffectView)

		// The sliding selection highlight view
		highlightView.wantsLayer = true
		highlightView.layer?.cornerRadius = 9
		highlightView.layer?.cornerCurve = .continuous
		highlightView.layer?.backgroundColor = NSColor(srgbRed: 0x33 / 255.0, green: 0xA5 / 255.0, blue: 0xA5 / 255.0, alpha: 0.30).cgColor
		highlightView.isHidden = true

		// The main stack (stacked vertically: Display rows)
		mainVerticalStack.orientation = .vertical
		mainVerticalStack.alignment = .leading
		mainVerticalStack.spacing = displaySpacing
		mainVerticalStack.translatesAutoresizingMaskIntoConstraints = false

		// Add the main stack and highlight view to the visual effect view
		visualEffectView.addSubview(mainVerticalStack)
		visualEffectView.addSubview(highlightView, positioned: .below, relativeTo: mainVerticalStack)
		visualEffectView.translatesAutoresizingMaskIntoConstraints = false

		self.contentView = visualEffectView

		NSLayoutConstraint.activate([
			mainVerticalStack.topAnchor.constraint(equalTo: visualEffectView.topAnchor, constant: panelPadding),
			mainVerticalStack.bottomAnchor.constraint(lessThanOrEqualTo: visualEffectView.bottomAnchor, constant: -panelPadding),
			mainVerticalStack.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: panelPadding),
			mainVerticalStack.trailingAnchor.constraint(lessThanOrEqualTo: visualEffectView.trailingAnchor, constant: -panelPadding),
		])
	}

	// MARK: - Public Methods

	/// Set the Display data and show the panel (with an appearance animation)
	func showWithDisplays(_ newDisplays: [WindowPaletteDisplay], displayIndex: Int, spaceIndex: Int, itemIndex: Int) {
		self.displays = newDisplays
		self.selectedDisplayIndex = displayIndex
		self.selectedSpaceIndex = spaceIndex
		self.selectedItemIndex = itemIndex

		rebuildViews()
		positionOnScreen()
		visualEffectView.layoutSubtreeIfNeeded()
		updateSelection(animated: false)

		PopupAppearance.show(self) { [weak self] in
			self?.orderFrontRegardless()
		}
	}

	/// Update the selection position
	func updateSelection(displayIndex: Int, spaceIndex: Int, itemIndex: Int) {
		self.selectedDisplayIndex = displayIndex
		self.selectedSpaceIndex = spaceIndex
		self.selectedItemIndex = itemIndex
		updateSelection(animated: true)
	}

	/// Close the panel (dismiss it immediately, without animation)
	func hidePanel() {
		highlightView.isHidden = true
		highlightView.layer?.removeAllAnimations()
		PopupAppearance.hide(self)
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

		for view in mainVerticalStack.arrangedSubviews {
			mainVerticalStack.removeArrangedSubview(view)
			view.removeFromSuperview()
		}

		// Build each Display row
		for display in displays {
			// Add a separator between Display rows if present (a horizontal 1px line)
			if !mainVerticalStack.arrangedSubviews.isEmpty {
				let separator = NSView()
				separator.wantsLayer = true
				separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
				separator.translatesAutoresizingMaskIntoConstraints = false
				NSLayoutConstraint.activate([
					separator.heightAnchor.constraint(equalToConstant: 1),
				])
				mainVerticalStack.addArrangedSubview(separator)
				separator.widthAnchor.constraint(equalTo: mainVerticalStack.widthAnchor).isActive = true
			}

			// Container for the whole Display row (stacked vertically: title + Space row)
			let displayRow = NSStackView()
			displayRow.orientation = .vertical
			displayRow.alignment = .leading
			displayRow.spacing = displayTitleSpacing
			displayRow.translatesAutoresizingMaskIntoConstraints = false

			// Display title (top-left)
			let displayTitle = NSTextField(labelWithString: "Display \(display.displayNumber)")
			displayTitle.font = NSFont.systemFont(ofSize: 13, weight: .bold)
			displayTitle.textColor = NSColor.white.withAlphaComponent(0.7)
			displayTitle.translatesAutoresizingMaskIntoConstraints = false
			displayRow.addArrangedSubview(displayTitle)

			// Stack that lays Space sections out horizontally
			let spacesRow = NSStackView()
			spacesRow.orientation = .horizontal
			spacesRow.alignment = .top
			spacesRow.spacing = sectionSpacing
			spacesRow.translatesAutoresizingMaskIntoConstraints = false

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
				spaceSection.spacing = labelSpacing
				spaceSection.translatesAutoresizingMaskIntoConstraints = false

				spaceSection.addArrangedSubview(spaceLabel)
				spaceSection.addArrangedSubview(cardRow)

				spacesRow.addArrangedSubview(spaceSection)
			}

			cardViews.append(displayCardViews)
			displayRow.addArrangedSubview(spacesRow)
			mainVerticalStack.addArrangedSubview(displayRow)
		}
	}

	/// Update the selection state and highlight position
	private func updateSelection(animated: Bool = true) {
		var selectedCardView: WindowPaletteItemView?

		for (dIndex, displayCards) in cardViews.enumerated() {
			for (sIndex, spaceCards) in displayCards.enumerated() {
				for (iIndex, card) in spaceCards.enumerated() {
					let isSel = (dIndex == selectedDisplayIndex
						&& sIndex == selectedSpaceIndex
						&& iIndex == selectedItemIndex)
					card.isSelected = isSel
					if isSel {
						selectedCardView = card
					}
				}
			}
		}

		guard let card = selectedCardView, let contentView = self.contentView else {
			highlightView.isHidden = true
			return
		}

		highlightView.isHidden = false
		let targetFrame = card.convert(card.bounds, to: contentView)
		PopupAppearance.animateFrame(of: highlightView, to: targetFrame, animated: animated)
	}

	/// Center the panel on screen
	private func positionOnScreen() {
		guard let screen = NSScreen.main else { return }

		// Compute each Display row's width and take the widest one (width = the widest Display row)
		var maxDisplayRowWidth: CGFloat = 0
		for display in displays {
			var rowWidth: CGFloat = 0
			for (index, space) in display.spaces.enumerated() {
				let cardCount = space.items.count
				let spaceWidth = CGFloat(cardCount) * WindowPaletteItemView.cardWidth + CGFloat(max(cardCount - 1, 0)) * cardSpacing
				rowWidth += spaceWidth
				if index > 0 {
					rowWidth += sectionSpacing
				}
			}
			maxDisplayRowWidth = max(maxDisplayRowWidth, rowWidth)
		}
		if maxDisplayRowWidth == 0 {
			maxDisplayRowWidth = WindowPaletteItemView.cardWidth
		}
		let panelWidth = min(maxDisplayRowWidth + panelPadding * 2, screen.frame.width)

		// Panel height: the sum of the heights of all Display rows (height = total of all Display rows)
		let singleRowHeight = displayTitleHeight + displayTitleSpacing + labelHeight + labelSpacing + WindowPaletteItemView.cardHeight
		var totalContentHeight = CGFloat(displays.count) * singleRowHeight
		if displays.count > 1 {
			// Since the stack spacing appears both above and below the 1px separator, count the spacing twice
			totalContentHeight += CGFloat(displays.count - 1) * (displaySpacing * 2 + 1)
		}
		let panelHeight = min(totalContentHeight + panelPadding * 2, screen.frame.height * 0.85)

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
