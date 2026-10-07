//
//  FloatingAppsStore.swift
//  Axis
//
//  The apps whose windows always float (Settings > Floating), saved in UserDefaults. Their
//  windows are never tiled: they float in no workspace, like System Settings.
//

import AppKit
import Combine
import UniformTypeIdentifiers

/// An app on the floating list, with the name and icon the Floating tab shows
struct FloatingApp: Identifiable, Equatable {
	let bundleID: String
	/// As Finder shows it; the name saved when it was added if the app cannot be found
	let name: String
	let icon: NSImage

	var id: String { bundleID }
}

/// A singleton that keeps the floating list and hands it to the tracking state
final class FloatingAppsStore: ObservableObject {
	static let shared = FloatingAppsStore()

	/// In the order they were added
	@Published private(set) var apps: [FloatingApp]

	/// The bundle identifiers the tracking state goes by
	var bundleIDs: Set<String> {
		Set(apps.map(\.bundleID))
	}

	/// Saved as [["bundleID": ..., "name": ...]]
	private static let defaultsKey = "floatingApps"

	private init() {
		if let saved = UserDefaults.standard.array(forKey: Self.defaultsKey) as? [[String: String]] {
			apps = saved.compactMap { entry in
				guard let bundleID = entry["bundleID"] else { return nil }
				return Self.app(bundleID: bundleID, savedName: entry["name"] ?? bundleID)
			}
		} else {
			// System Settings shows fixed-size panes that do not tile
			apps = [Self.app(bundleID: "com.apple.systempreferences", savedName: "System Settings")]
		}
	}

	// MARK: - Editing

	/// Adds the apps at `urls` that are not on the list yet
	func add(appsAt urls: [URL]) {
		var updated = apps
		for url in urls {
			// Axis's own windows are never tracked
			guard let bundleID = Bundle(url: url)?.bundleIdentifier,
			      bundleID != Bundle.main.bundleIdentifier,
			      !updated.contains(where: { $0.bundleID == bundleID })
			else { continue }
			updated.append(Self.app(at: url, bundleID: bundleID))
		}
		guard updated != apps else { return }
		apps = updated
		listChanged()
	}

	func remove(bundleID: String) {
		guard apps.contains(where: { $0.bundleID == bundleID }) else { return }
		apps.removeAll { $0.bundleID == bundleID }
		listChanged()
	}

	/// Saves the list. The windows already open follow it once the list on screen has updated
	private func listChanged() {
		let entries = apps.map { ["bundleID": $0.bundleID, "name": $0.name] }
		UserDefaults.standard.set(entries, forKey: Self.defaultsKey)
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			WorkspaceManager.shared.setFloatingApps(self.bundleIDs)
		}
	}

	// MARK: - Names and icons

	/// The installed app with this bundle identifier, else `savedName` with a generic icon (the app
	/// was deleted, or is on a disk that is not connected)
	private static func app(bundleID: String, savedName: String) -> FloatingApp {
		guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
			return FloatingApp(bundleID: bundleID, name: savedName, icon: NSWorkspace.shared.icon(for: .applicationBundle))
		}
		return app(at: url, bundleID: bundleID)
	}

	private static func app(at url: URL, bundleID: String) -> FloatingApp {
		var name = FileManager.default.displayName(atPath: url.path)
		// The extension shows when Finder is set to show all filename extensions
		if name.hasSuffix(".app") {
			name = String(name.dropLast(4))
		}
		return FloatingApp(bundleID: bundleID, name: name, icon: NSWorkspace.shared.icon(forFile: url.path))
	}
}
