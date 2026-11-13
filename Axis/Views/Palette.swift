//
//  Palette.swift
//  Axis
//

import AppKit
import SwiftUI

/// The app's color scheme. Every color drawn on screen comes from here:
/// the 16 scheme colors, pure black and white, and alpha variants of them
/// for lines, fills, and tints. Text is always opaque.
enum NSPalette {

	// MARK: - The 16 scheme colors

	static let black = rgb(0x252525)
	static let brightBlack = rgb(0x888888)
	static let red = rgb(0xCC8275)
	static let brightRed = rgb(0xD8A79E)
	static let green = rgb(0x5EB5B5)
	static let brightGreen = rgb(0x99CCCB)
	static let yellow = rgb(0xD6B67B)
	static let brightYellow = rgb(0xE6D2AD)
	static let blue = rgb(0x76ABD6)
	static let brightBlue = rgb(0xA5C5E1)
	static let magenta = rgb(0xBE93C4)
	static let brightMagenta = rgb(0xD2B6D6)
	static let cyan = rgb(0x72C1DA)
	static let brightCyan = rgb(0xA5D3E3)
	static let white = rgb(0xcccccc)
	static let brightWhite = rgb(0xfcfcfc)

	static let pureBlack = rgb(0x000000)
	static let pureWhite = rgb(0xffffff)

	// MARK: - Roles

	/// Body text and highlighted text on glass
	static let text = brightWhite
	/// Secondary text on glass (hints, shortcuts, labels)
	static let secondaryText = white
	/// The 1px line around panels and between their sections
	static let line = pureWhite.withAlphaComponent(0.20)
	/// The single selection highlight in lists
	static let selection = green.withAlphaComponent(0.30)
	/// The tint laid over the glass material, fixing the panel's brightness
	static let glassTint = pureBlack.withAlphaComponent(0.50)
	/// The tint laid over the blur behind popups
	static let popupTint = black.withAlphaComponent(0.55)

	private static func rgb(_ hex: UInt32) -> NSColor {
		NSColor(
			srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
			green: CGFloat((hex >> 8) & 0xff) / 255,
			blue: CGFloat(hex & 0xff) / 255,
			alpha: 1
		)
	}
}

/// SwiftUI colors, taken from `NSPalette`
enum Palette {
	static let black = Color(nsColor: NSPalette.black)
	static let red = Color(nsColor: NSPalette.red)
	static let green = Color(nsColor: NSPalette.green)
	static let brightGreen = Color(nsColor: NSPalette.brightGreen)
	static let yellow = Color(nsColor: NSPalette.yellow)
	static let white = Color(nsColor: NSPalette.white)
	static let brightWhite = Color(nsColor: NSPalette.brightWhite)
	static let pureBlack = Color(nsColor: NSPalette.pureBlack)
	static let pureWhite = Color(nsColor: NSPalette.pureWhite)

	static let text = Color(nsColor: NSPalette.text)
	static let secondaryText = Color(nsColor: NSPalette.secondaryText)
	static let line = Color(nsColor: NSPalette.line)
	static let selection = Color(nsColor: NSPalette.selection)
	static let glassTint = Color(nsColor: NSPalette.glassTint)
	static let accent = green
}
