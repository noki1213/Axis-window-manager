//
//  DisplayReader.swift
//  Axis
//
//  Turns the connected screens into display facts. A display is identified by its UUID, which
//  survives reconnects and display-ID changes (the numeric ID does not), and every frame is
//  converted to global top-left coordinates, the space the core and the Accessibility API share.
//

import Foundation
import AppKit
import CoreGraphics

/// What the display configuration looked like at one moment: UUIDs, frames and visible frames.
/// Two equal signatures a short time apart mean the configuration has settled.
nonisolated struct DisplaySignature: Equatable, Sendable {
	nonisolated struct Entry: Equatable, Sendable {
		var key: MonitorKey
		var frame: CGRect
		var visibleFrame: CGRect
	}

	var entries: [Entry]

	/// No screens, or a screen no wider or taller than 1 pt: macOS reports these while it rebuilds
	/// the configuration, so they never count as settled.
	var isDegenerate: Bool {
		entries.isEmpty || entries.contains { $0.frame.width <= 1 || $0.frame.height <= 1 }
	}

	init(entries: [Entry]) {
		self.entries = entries
	}

	init(_ displays: [DisplayFacts]) {
		self.init(entries: displays.map { Entry(key: $0.key, frame: $0.frame, visibleFrame: $0.visibleFrame) })
	}
}

enum DisplayReader {
	/// Every connected display in screen order (the primary display first).
	static func read() -> [DisplayFacts] {
		entries().map(\.facts)
	}

	static func signature() -> DisplaySignature {
		DisplaySignature(read())
	}

	/// The key of a screen, nil when the screen is no longer connected.
	static func monitorKey(for screen: NSScreen) -> MonitorKey? {
		entries().first { $0.screen == screen }?.facts.key
	}

	/// The screen of a key, nil when no connected screen has it.
	static func screen(for key: MonitorKey) -> NSScreen? {
		entries().first { $0.facts.key == key }?.screen
	}

	// MARK: - Reading

	private struct Entry {
		let screen: NSScreen
		let facts: DisplayFacts
	}

	private static func entries() -> [Entry] {
		let screens = NSScreen.screens
		// The first screen is the primary one, with the origin at (0, 0); its height is the
		// reference for flipping bottom-left screen coordinates to top-left global ones.
		guard let primaryHeight = screens.first?.frame.height else { return [] }

		let raw = screens.map { screen -> (screen: NSScreen, displayID: CGDirectDisplayID, baseKey: String) in
			let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
			return (screen, displayID, baseKey(forDisplayID: displayID))
		}

		let keys = uniqueKeys(baseKeys: raw.map(\.baseKey), displayIDs: raw.map(\.displayID))

		return raw.enumerated().map { index, entry in
			let facts = DisplayFacts(
				key: MonitorKey(raw: keys[index]),
				displayID: entry.displayID,
				name: entry.screen.localizedName,
				frame: flipped(entry.screen.frame, primaryHeight: primaryHeight),
				visibleFrame: flipped(entry.screen.visibleFrame, primaryHeight: primaryHeight),
				isPrimary: CGDisplayIsMain(entry.displayID) != 0)
			return Entry(screen: entry.screen, facts: facts)
		}
	}

	/// Displays that report the same UUID cannot be told apart by it: the one with the lowest
	/// display ID keeps the plain UUID and the others get "#2", "#3", ... in display-ID order, so
	/// connecting a second identical display never renames the first.
	static func uniqueKeys(baseKeys: [String], displayIDs: [UInt32]) -> [String] {
		var keys = baseKeys
		for indices in Dictionary(grouping: baseKeys.indices, by: { baseKeys[$0] }).values where indices.count > 1 {
			for (rank, index) in indices.sorted(by: { displayIDs[$0] < displayIDs[$1] }).enumerated() where rank > 0 {
				keys[index] = "\(baseKeys[index])#\(rank + 1)"
			}
		}
		return keys
	}

	/// The display's UUID, or "display-<id>" when the system has none.
	private static func baseKey(forDisplayID displayID: CGDirectDisplayID) -> String {
		if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
		   let string = CFUUIDCreateString(nil, uuid) as String? {
			return string
		}
		return "display-\(displayID)"
	}

	private static func flipped(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
		CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
	}
}
