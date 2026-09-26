//
//  WindowPaletteItemView.swift
//  Axis
//
//  Created on 2026/01/31.
//

import AppKit

/// The card-style view for the window palette
/// A card stacking the app icon, app name, and window title vertically
class WindowPaletteItemView: NSView {

	// MARK: - Properties

	/// Whether this card is selected (highlighted)
	var isSelected: Bool = false

	private let iconImageView = NSImageView()
	private let appNameLabel = NSTextField(labelWithString: "")
	private let titleLabel = NSTextField(labelWithString: "")

	/// The card's width
	static let cardWidth: CGFloat = 120
	/// Padding above the icon, matched below the title
	private static let verticalPadding: CGFloat = 10
	private static let iconSize: CGFloat = 32
	private static let iconToNameSpacing: CGFloat = 4
	private static let nameToTitleSpacing: CGFloat = 1

	/// The card height that fits the longest of the given titles.
	/// Cards shown together share this height so their icons line up
	/// and the space below the tallest title matches the space above the icon.
	static func cardHeight(forTitles titles: [String]) -> CGFloat {
		let nameLabel = NSTextField(labelWithString: "")
		configureAppNameLabel(nameLabel)
		nameLabel.stringValue = "A"
		let nameHeight = ceil(nameLabel.fittingSize.height)

		let titleLabel = NSTextField(labelWithString: "")
		configureTitleLabel(titleLabel)
		var titleHeight: CGFloat = 0
		for title in titles.isEmpty ? [""] : titles {
			titleLabel.stringValue = displayTitle(title)
			titleHeight = max(titleHeight, ceil(titleLabel.fittingSize.height))
		}

		return verticalPadding + iconSize + iconToNameSpacing + nameHeight
			+ nameToTitleSpacing + titleHeight + verticalPadding
	}

	private static func displayTitle(_ title: String) -> String {
		title.isEmpty ? "No title" : title
	}

	private static func configureAppNameLabel(_ label: NSTextField) {
		label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
		label.textColor = .white
		label.alignment = .center
		label.lineBreakMode = .byTruncatingTail
		label.maximumNumberOfLines = 1
	}

	private static func configureTitleLabel(_ label: NSTextField) {
		label.font = NSFont.systemFont(ofSize: 10, weight: .regular)
		label.textColor = NSColor.white.withAlphaComponent(0.6)
		label.alignment = .center
		// Wrap long titles over up to two lines, truncating only the last
		label.lineBreakMode = .byWordWrapping
		label.maximumNumberOfLines = 2
		label.cell?.truncatesLastVisibleLine = true
		label.preferredMaxLayoutWidth = cardWidth - 8
	}

	// MARK: - Init

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		setupViews()
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	// MARK: - Setup

	private func setupViews() {
		wantsLayer = true
		layer?.cornerRadius = 8

		// App icon (32x32, top center)
		iconImageView.translatesAutoresizingMaskIntoConstraints = false
		iconImageView.imageScaling = .scaleProportionallyUpOrDown
		addSubview(iconImageView)

		// App name (center-aligned)
		appNameLabel.translatesAutoresizingMaskIntoConstraints = false
		Self.configureAppNameLabel(appNameLabel)
		addSubview(appNameLabel)

		// Window title (center-aligned, light color)
		titleLabel.translatesAutoresizingMaskIntoConstraints = false
		Self.configureTitleLabel(titleLabel)
		addSubview(titleLabel)

		// Auto Layout
		NSLayoutConstraint.activate([
			// Icon: top center
			iconImageView.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalPadding),
			iconImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
			iconImageView.widthAnchor.constraint(equalToConstant: Self.iconSize),
			iconImageView.heightAnchor.constraint(equalToConstant: Self.iconSize),

			// App name: below the icon
			appNameLabel.topAnchor.constraint(equalTo: iconImageView.bottomAnchor, constant: Self.iconToNameSpacing),
			appNameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
			appNameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),

			// Title: below the app name
			titleLabel.topAnchor.constraint(equalTo: appNameLabel.bottomAnchor, constant: Self.nameToTitleSpacing),
			titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
			titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
		])
	}

	// MARK: - Configure

	/// Set the display content
	func configure(icon: NSImage?, appName: String, windowTitle: String) {
		iconImageView.image = icon
		appNameLabel.stringValue = appName
		titleLabel.stringValue = Self.displayTitle(windowTitle)
	}
}
