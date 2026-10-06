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
	/// nil for windows that don't belong to any workspace (the System section)
	let workspace: WorkspaceID?
	let monitor: MonitorKey
}

/// A section of the palette: one workspace (Space), or one of the special groups
struct WindowPaletteSection {
	enum Kind: Equatable {
		/// A workspace, by the number it shows (0 = home, negatives to the left)
		case space(Int)
		/// Windows the user deliberately floated
		case float
		/// System-originated floating windows not registered to any workspace
		case system
		/// Windows hidden with Ctrl+Opt+X (minimized)
		case hidden
	}

	let kind: Kind
	var items: [WindowPaletteItem]
}

/// Data for a single monitor (Display)
struct WindowPaletteDisplay {
	let displayNumber: Int
	let monitor: MonitorKey
	var spaces: [WindowPaletteSection]
}

/// A translucent panel that shows the window list
/// Display rows are stacked from top to bottom, with Spaces laid out horizontally within each row
class WindowPalettePanel: NSPanel {

	// MARK: - Properties

	/// Data per Display
	private var displays: [WindowPaletteDisplay] = []
	/// Shared height for every card, fitted to the longest title
	private var cardHeight: CGFloat = 0

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

	/// Scrolls the content vertically when it is taller than the screen allows
	private let scrollView = NSScrollView()

	/// The scrolled document holding the stack and the highlight
	private let documentView = FlippedView()

	/// The widest the card area may grow before cards wrap onto the next line
	private var maxContentWidth: CGFloat = 0

	/// The visual effect view used for the background blur
	private let visualEffectView = NSVisualEffectView()

	/// The spacing between cards
	private let cardSpacing: CGFloat = 8

	/// The spacing between Space sections
	private let sectionSpacing: CGFloat = 10

	/// The spacing between Display rows
	private let displaySpacing: CGFloat = 16

	/// The spacing between wrapped lines within a Display
	private let lineSpacing: CGFloat = 12

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

		// The highlight lives in the scrolled document so it moves with the cards
		documentView.translatesAutoresizingMaskIntoConstraints = false
		documentView.addSubview(mainVerticalStack)
		documentView.addSubview(highlightView, positioned: .below, relativeTo: mainVerticalStack)

		scrollView.drawsBackground = false
		scrollView.hasVerticalScroller = true
		scrollView.autohidesScrollers = true
		scrollView.scrollerStyle = .overlay
		scrollView.translatesAutoresizingMaskIntoConstraints = false
		scrollView.documentView = documentView

		visualEffectView.addSubview(scrollView)
		visualEffectView.translatesAutoresizingMaskIntoConstraints = false

		self.contentView = visualEffectView

		let clipView = scrollView.contentView
		NSLayoutConstraint.activate([
			scrollView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
			scrollView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
			scrollView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
			scrollView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),

			documentView.topAnchor.constraint(equalTo: clipView.topAnchor),
			documentView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
			documentView.widthAnchor.constraint(equalTo: clipView.widthAnchor),

			mainVerticalStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: panelPadding),
			mainVerticalStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -panelPadding),
			mainVerticalStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: panelPadding),
			mainVerticalStack.trailingAnchor.constraint(lessThanOrEqualTo: documentView.trailingAnchor, constant: -panelPadding),
		])
	}

	// MARK: - Public Methods

	/// Set the Display data and show the panel (with an appearance animation)
	func showWithDisplays(_ newDisplays: [WindowPaletteDisplay], displayIndex: Int, spaceIndex: Int, itemIndex: Int) {
		self.displays = newDisplays
		self.cardHeight = WindowPaletteItemView.cardHeight(
			forTitles: newDisplays.flatMap { $0.spaces.flatMap { $0.items.map(\.windowTitle) } }
		)
		self.selectedDisplayIndex = displayIndex
		self.selectedSpaceIndex = spaceIndex
		self.selectedItemIndex = itemIndex

		let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
		maxContentWidth = max(visible.width * 0.9 - panelPadding * 2, WindowPaletteItemView.cardWidth)

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

	/// Return the label string for a section
	private static func sectionLabel(for kind: WindowPaletteSection.Kind) -> String {
		switch kind {
		case .hidden: return "Hidden"
		case .float: return "Float"
		case .system: return "System"
		case .space(let workspace): return "Space \(workspace)"
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

			// Space sections flow left to right and wrap onto a new line when the screen is full
			let linesStack = NSStackView()
			linesStack.orientation = .vertical
			linesStack.alignment = .leading
			linesStack.spacing = lineSpacing
			linesStack.translatesAutoresizingMaskIntoConstraints = false

			let cardStride = WindowPaletteItemView.cardWidth + cardSpacing
			let maxColumns = max(Int((maxContentWidth + cardSpacing) / cardStride), 1)

			var currentLine: NSStackView?
			var currentLineWidth: CGFloat = 0

			var displayCardViews: [[WindowPaletteItemView]] = []

			// Each Space section
			for space in display.spaces {
				// Space label
				let spaceLabel = NSTextField(labelWithString: WindowPalettePanel.sectionLabel(for: space.kind))
				spaceLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
				spaceLabel.textColor = NSColor.white.withAlphaComponent(0.4)
				spaceLabel.translatesAutoresizingMaskIntoConstraints = false

				// A section with more windows than fit on one line wraps its cards over several rows
				let columns = min(space.items.count, maxColumns)
				let cardRows = NSStackView()
				cardRows.orientation = .vertical
				cardRows.alignment = .leading
				cardRows.spacing = cardSpacing
				cardRows.translatesAutoresizingMaskIntoConstraints = false

				var spaceCardViews: [WindowPaletteItemView] = []
				var cardRow: NSStackView?

				for (index, item) in space.items.enumerated() {
					if index % max(columns, 1) == 0 {
						let row = NSStackView()
						row.orientation = .horizontal
						row.spacing = cardSpacing
						row.translatesAutoresizingMaskIntoConstraints = false
						cardRows.addArrangedSubview(row)
						cardRow = row
					}

					let card = WindowPaletteItemView()
					card.translatesAutoresizingMaskIntoConstraints = false
					card.configure(
						icon: item.appIcon,
						appName: item.appName,
						windowTitle: item.windowTitle
					)

					NSLayoutConstraint.activate([
						card.widthAnchor.constraint(equalToConstant: WindowPaletteItemView.cardWidth),
						card.heightAnchor.constraint(equalToConstant: cardHeight),
					])

					cardRow?.addArrangedSubview(card)
					spaceCardViews.append(card)
				}

				displayCardViews.append(spaceCardViews)

				// Space section (label + card rows)
				let spaceSection = NSStackView()
				spaceSection.orientation = .vertical
				spaceSection.alignment = .leading
				spaceSection.spacing = labelSpacing
				spaceSection.translatesAutoresizingMaskIntoConstraints = false

				spaceSection.addArrangedSubview(spaceLabel)
				spaceSection.addArrangedSubview(cardRows)

				let sectionWidth = columns > 0
					? CGFloat(columns) * cardStride - cardSpacing
					: spaceLabel.fittingSize.width

				// Start a new line when this section would run past the screen
				if let line = currentLine, currentLineWidth + sectionSpacing + sectionWidth <= maxContentWidth {
					line.addArrangedSubview(spaceSection)
					currentLineWidth += sectionSpacing + sectionWidth
				} else {
					let line = NSStackView()
					line.orientation = .horizontal
					line.alignment = .top
					line.spacing = sectionSpacing
					line.translatesAutoresizingMaskIntoConstraints = false
					line.addArrangedSubview(spaceSection)
					linesStack.addArrangedSubview(line)
					currentLine = line
					currentLineWidth = sectionWidth
				}
			}

			cardViews.append(displayCardViews)
			displayRow.addArrangedSubview(linesStack)
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

		guard let card = selectedCardView else {
			highlightView.isHidden = true
			return
		}

		highlightView.isHidden = false
		let targetFrame = card.convert(card.bounds, to: documentView)
		PopupAppearance.animateFrame(of: highlightView, to: targetFrame, animated: animated)
		documentView.scrollToVisible(targetFrame.insetBy(dx: 0, dy: -panelPadding))
	}

	/// The card directly above or below the given one, wrapping to the far edge.
	/// Rows are matched by position, so this crosses wrapped lines and Displays alike.
	func verticalNeighbor(displayIndex: Int, spaceIndex: Int, itemIndex: Int, up: Bool) -> (display: Int, space: Int, item: Int)? {
		guard cardViews.indices.contains(displayIndex),
		      cardViews[displayIndex].indices.contains(spaceIndex),
		      cardViews[displayIndex][spaceIndex].indices.contains(itemIndex) else { return nil }

		visualEffectView.layoutSubtreeIfNeeded()
		let current = cardViews[displayIndex][spaceIndex][itemIndex].convert(
			cardViews[displayIndex][spaceIndex][itemIndex].bounds, to: documentView
		)

		var candidates: [(index: (display: Int, space: Int, item: Int), frame: NSRect)] = []
		for (d, displayCards) in cardViews.enumerated() {
			for (sIdx, spaceCards) in displayCards.enumerated() {
				for (i, card) in spaceCards.enumerated() {
					candidates.append(((d, sIdx, i), card.convert(card.bounds, to: documentView)))
				}
			}
		}

		// The document is flipped, so "up" means a smaller y
		let tolerance: CGFloat = 1
		let inDirection = candidates.filter {
			up ? $0.frame.midY < current.midY - tolerance : $0.frame.midY > current.midY + tolerance
		}
		let pool = inDirection.isEmpty
			? candidates.filter { abs($0.frame.midY - current.midY) > tolerance }
			: inDirection
		guard !pool.isEmpty else { return nil }

		// Nearest row in the direction of travel; when wrapping, the pool is every other row,
		// so the same rule picks the far edge
		let rowY = up ? pool.map(\.frame.midY).max()! : pool.map(\.frame.midY).min()!
		let row = pool.filter { abs($0.frame.midY - rowY) <= tolerance }
		return row.min(by: { abs($0.frame.midX - current.midX) < abs($1.frame.midX - current.midX) })?.index
	}

	/// Size the panel to its content and center it on screen
	private func positionOnScreen() {
		guard let screen = NSScreen.main else { return }

		visualEffectView.layoutSubtreeIfNeeded()
		let contentSize = mainVerticalStack.fittingSize
		let visible = screen.visibleFrame

		let panelWidth = min(max(contentSize.width, WindowPaletteItemView.cardWidth) + panelPadding * 2, visible.width)
		let panelHeight = min(contentSize.height + panelPadding * 2, visible.height * 0.85)

		let panelFrame = NSRect(
			x: visible.midX - panelWidth / 2,
			y: visible.midY - panelHeight / 2,
			width: panelWidth,
			height: panelHeight
		)

		self.setFrame(panelFrame, display: true)
		visualEffectView.layoutSubtreeIfNeeded()
		documentView.scroll(.zero)
	}

	// MARK: - NSPanel Override

	override var canBecomeKey: Bool { false }
	override var canBecomeMain: Bool { false }
}

/// A top-down coordinate space, so scrolled content starts at the top
private final class FlippedView: NSView {
	override var isFlipped: Bool { true }
}
