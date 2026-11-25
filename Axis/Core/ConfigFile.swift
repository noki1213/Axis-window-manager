//
//  ConfigFile.swift
//  Axis
//
//  What the hand-editable files in Application Support (settings.json, hotkeys.json) share:
//  finding the file behind a symlink and noticing when it changed.
//

import Foundation

enum ConfigFile {
	/// The file a path stands for: the destination when it is a symlink (or a chain of them), else
	/// the path itself. A link whose destination doesn't exist yet still gives the destination, so a
	/// write creates the file there instead of replacing the link.
	static func resolved(_ url: URL) -> URL {
		var current = url
		// Bounded, so links that point at each other end
		for _ in 0..<16 {
			guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) else { break }
			current = URL(fileURLWithPath: destination, relativeTo: current.deletingLastPathComponent()).standardizedFileURL
		}
		return current.resolvingSymlinksInPath()
	}

	/// The path, modification date and size of the file; nil when it doesn't exist
	struct Stamp: Equatable {
		let path: String
		let modified: Date
		let size: Int

		init?(of url: URL) {
			guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
			      let modified = attributes[.modificationDate] as? Date
			else { return nil }
			self.path = url.path
			self.modified = modified
			self.size = (attributes[.size] as? Int) ?? 0
		}
	}
}
