//
//  WindowSwitcherItemView.swift
//  Axis
//
//  Created on 2026/01/31.
//

import AppKit

/// The card-shaped view for the window switcher
/// A card stacking the app icon, app name, and window title vertically
class WindowSwitcherItemView: NSView {

	// MARK: - Properties

	/// Whether this card is selected (highlighted)
	var isSelected: Bool = false {
		didSet { needsDisplay = true }
	}

	private let iconImageView = NSImageView()
	private let appNameLabel = NSTextField(labelWithString: "")
	private let titleLabel = NSTextField(labelWithString: "")

	/// The card's width
	static let cardWidth: CGFloat = 120
	/// The card's height
	static let cardHeight: CGFloat = 84

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
		appNameLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
		appNameLabel.textColor = .white
		appNameLabel.alignment = .center
		appNameLabel.lineBreakMode = .byTruncatingTail
		appNameLabel.maximumNumberOfLines = 1
		addSubview(appNameLabel)

		// Window title (center-aligned, light color)
		titleLabel.translatesAutoresizingMaskIntoConstraints = false
		titleLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
		titleLabel.textColor = NSColor.white.withAlphaComponent(0.6)
		titleLabel.alignment = .center
		titleLabel.lineBreakMode = .byTruncatingTail
		titleLabel.maximumNumberOfLines = 1
		addSubview(titleLabel)

		// Auto Layout
		NSLayoutConstraint.activate([
			// Icon: top center
			iconImageView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
			iconImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
			iconImageView.widthAnchor.constraint(equalToConstant: 32),
			iconImageView.heightAnchor.constraint(equalToConstant: 32),

			// App name: below the icon
			appNameLabel.topAnchor.constraint(equalTo: iconImageView.bottomAnchor, constant: 4),
			appNameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
			appNameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),

			// Title: below the app name
			titleLabel.topAnchor.constraint(equalTo: appNameLabel.bottomAnchor, constant: 1),
			titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
			titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
		])
	}

	// MARK: - Configure

	/// Set the display content
	func configure(icon: NSImage?, appName: String, windowTitle: String) {
		iconImageView.image = icon
		appNameLabel.stringValue = appName
		titleLabel.stringValue = windowTitle.isEmpty ? "(タイトルなし)" : windowTitle
	}

	// MARK: - Drawing

	override func draw(_ dirtyRect: NSRect) {
		super.draw(dirtyRect)

		if isSelected {
			// While selected: a translucent white background
			let selectionColor = NSColor.white.withAlphaComponent(0.2)
			selectionColor.setFill()
			let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
			path.fill()
		}
	}
}
