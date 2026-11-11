//
//  HotkeyStore.swift
//  Axis
//
//  Manages saving/loading hotkey settings
//

import Foundation
import Combine

/// A singleton that manages saving and loading hotkey settings.
///
/// hotkeys.json is a JSON object from action name to key string, holding only the keys that differ from the defaults:
/// `{"zenToggle": "ctrl+opt+shift+z", "focusLeft": ["ctrl+opt+j", "ctrl+opt+left"], "hideWindow": ""}`.
/// The file may be a symlink; Axis reads and writes the file it points to and picks up edits to it while running.
class HotkeyStore: ObservableObject {
	static let shared = HotkeyStore()

	/// The current list of key bindings
	@Published private(set) var bindings: [HotkeyBinding] = []

	/// What is wrong with hotkeys.json, one line each (empty when nothing is)
	@Published private(set) var problems: [String] = []

	/// The path to the save destination file (may be a symlink)
	private let saveURL: URL = {
		let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		let axisDir = appSupport.appendingPathComponent("Axis")
		// Create the directory if it doesn't exist
		try? FileManager.default.createDirectory(at: axisDir, withIntermediateDirectories: true)
		return axisDir.appendingPathComponent("hotkeys.json")
	}()

	/// The file actually read and written: the symlink's destination when hotkeys.json is a link
	private var fileURL: URL {
		return saveURL.resolvingSymlinksInPath()
	}

	/// Set while the file exists but can't be read as a JSON object. Saving would wipe what the user wrote, so it's held back.
	private var fileIsUnreadable = false

	/// The file's state when Axis last read or wrote it. A different state on the next check means someone else edited it.
	private var lastSeenStamp: FileStamp?

	/// How often the file is checked for edits
	private static let watchInterval: TimeInterval = 2.0
	private var watchTimer: Timer?

	/// The default keys of every action
	private static let defaultKeys: [HotkeyAction: [HotkeyKey]] = Dictionary(
		uniqueKeysWithValues: HotkeyBinding.defaults().map { ($0.action, $0.keys) }
	)

	private init() {
		loadFromDisk(atLaunch: true)
		startWatching()
	}

	// MARK: - Loading

	/// Load key settings from the file. Actions the file doesn't mention keep their default keys.
	/// A value that can't be read falls back to the default for that action only.
	/// A file that can't be read at all leaves the defaults at launch, and the keys in use when it breaks later.
	private func loadFromDisk(atLaunch: Bool) {
		let url = fileURL
		lastSeenStamp = FileStamp(of: url)

		guard FileManager.default.fileExists(atPath: url.path) else {
			fileIsUnreadable = false
			bindings = HotkeyBinding.defaults()
			problems = []
			return
		}

		let json: Any
		do {
			let data = try Data(contentsOf: url)
			json = try JSONSerialization.jsonObject(with: data)
		} catch {
			// The debug description names the line and column of a syntax error
			let reason = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
			let trimmed = reason.hasSuffix(".") ? String(reason.dropLast()) : reason
			markUnreadable("hotkeys.json can't be read: \(trimmed)", atLaunch: atLaunch)
			return
		}

		switch json {
		case let object as [String: Any]:
			fileIsUnreadable = false
			apply(object)
		case let array as [Any]:
			migrate(array, at: url)
		default:
			markUnreadable("hotkeys.json is not a JSON object", atLaunch: atLaunch)
		}
	}

	/// Record a file that can't be used at all
	private func markUnreadable(_ reason: String, atLaunch: Bool) {
		fileIsUnreadable = true
		if atLaunch {
			bindings = HotkeyBinding.defaults()
			problems = ["\(reason). Using the default shortcuts."]
		} else {
			problems = ["\(reason). Keeping the shortcuts in use."]
		}
	}

	/// Apply the file's object on top of the defaults
	private func apply(_ object: [String: Any]) {
		var found: [String] = []
		var overrides: [HotkeyAction: [HotkeyKey]] = [:]

		for (name, value) in object.sorted(by: { $0.key < $1.key }) {
			guard let action = HotkeyAction(rawValue: name) else {
				found.append("\"\(name)\": unknown action, ignored.")
				continue
			}
			let strings: [String]
			if let string = value as? String {
				strings = [string]
			} else if let list = value as? [String] {
				strings = list
			} else {
				found.append("\"\(name)\": expected a key string or a list of them. Using the default.")
				continue
			}
			// An empty string leaves the action without a key
			let written = strings.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
			let unreadable = written.filter { HotkeyKey(string: $0) == nil }
			if !unreadable.isEmpty {
				let list = unreadable.map { "\"\($0)\"" }.joined(separator: ", ")
				found.append("\"\(name)\": can't read \(list). Using the default.")
				continue
			}
			overrides[action] = written.compactMap { HotkeyKey(string: $0) }
		}

		let merged = HotkeyBinding.defaults().map { binding -> HotkeyBinding in
			guard let keys = overrides[binding.action] else { return binding }
			return HotkeyBinding(action: binding.action, keys: keys)
		}
		bindings = merged
		problems = found + Self.resolve(merged).conflicts
	}

	/// Convert the older format (a list of {action, keyCode, modifiers}) into the current one.
	/// The old file is kept next to it as hotkeys.json.bak-array before it's replaced.
	private func migrate(_ array: [Any], at url: URL) {
		var object: [String: Any] = [:]
		for case let entry as [String: Any] in array {
			// Entries for actions that no longer exist are dropped, so those actions get their defaults
			guard let name = entry["action"] as? String,
			      let action = HotkeyAction(rawValue: name),
			      let keyCode = entry["keyCode"] as? Int,
			      let rawModifiers = entry["modifiers"] as? UInt
			else { continue }
			let keys = [HotkeyKey(keyCode: keyCode, modifiers: HotkeyModifiers(rawValue: rawModifiers))]
			if keys != Self.defaultKeys[action] {
				object[name] = HotkeyKey.fileValue(keys)
			}
		}

		do {
			let backupURL = url.appendingPathExtension("bak-array")
			if !FileManager.default.fileExists(atPath: backupURL.path) {
				try FileManager.default.copyItem(at: url, to: backupURL)
			}
			try write(object, to: url)
			fileIsUnreadable = false
			apply(object)
		} catch {
			// Use the converted keys, but leave the old file alone until it can be backed up
			apply(object)
			fileIsUnreadable = true
			problems.insert("hotkeys.json is in the old format and couldn't be converted: \(error.localizedDescription)", at: 0)
		}
	}

	// MARK: - Watching for edits

	/// Check the file every few seconds and reload it when it was changed by something other than Axis
	private func startWatching() {
		watchTimer = Timer.scheduledTimer(withTimeInterval: Self.watchInterval, repeats: true) { [weak self] _ in
			guard let self else { return }
			// Resolved on every check, so pointing the link somewhere else is picked up too
			if FileStamp(of: self.fileURL) != self.lastSeenStamp {
				self.loadFromDisk(atLaunch: false)
			}
		}
	}

	/// The path, modification date and size of the file; nil when it doesn't exist
	private struct FileStamp: Equatable {
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

	// MARK: - Saving

	/// Write the given actions' keys into the file, leaving every other entry in it as it is.
	/// Keys equal to the default are removed from the file rather than written.
	private func saveToDisk(_ actions: [HotkeyAction]) {
		let url = fileURL
		var object: [String: Any] = [:]

		if fileIsUnreadable {
			reportNotSaved()
			return
		}
		if FileManager.default.fileExists(atPath: url.path) {
			guard let data = try? Data(contentsOf: url),
			      let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
			else {
				fileIsUnreadable = true
				reportNotSaved()
				return
			}
			object = existing
		}

		for action in actions {
			guard let binding = bindings.first(where: { $0.action == action }) else { continue }
			if binding.keys == Self.defaultKeys[action] {
				object.removeValue(forKey: action.rawValue)
			} else {
				object[action.rawValue] = HotkeyKey.fileValue(binding.keys)
			}
		}

		do {
			try write(object, to: url)
		} catch {
			problems.append("Couldn't save hotkeys.json: \(error.localizedDescription)")
		}
	}

	private func reportNotSaved() {
		let message = "hotkeys.json can't be read, so changes made here aren't saved to it. Fix the file to save again."
		if !problems.contains(message) {
			problems.append(message)
		}
	}

	/// Write the object atomically to the resolved file and remember its state so the watcher doesn't reload it
	private func write(_ object: [String: Any], to url: URL) throws {
		var data = object.isEmpty
			? Data("{}".utf8)
			: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
		data.append(Data("\n".utf8))
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		try data.write(to: url, options: .atomic)
		lastSeenStamp = FileStamp(of: url)
	}

	// MARK: - Reset to defaults

	/// Reset every key binding to its default
	func resetToDefaults() {
		bindings = HotkeyBinding.defaults()
		saveToDisk(HotkeyAction.allCases)
	}

	// MARK: - Updating key settings

	/// Replace the keys of a specific action with a single key
	func updateBinding(action: HotkeyAction, key: HotkeyKey) {
		if let index = bindings.firstIndex(where: { $0.action == action }) {
			bindings[index].keys = [key]
			saveToDisk([action])
		}
	}

	/// Leave an action without a key; hotkeys.json holds "" for it
	func clearBinding(action: HotkeyAction) {
		if let index = bindings.firstIndex(where: { $0.action == action }) {
			bindings[index].keys = []
			saveToDisk([action])
		}
	}

	// MARK: - Duplicate check

	/// Check whether the given key combination is already used by another action.
	/// Returns that action if it's already in use.
	func findConflict(key: HotkeyKey, excludeAction: HotkeyAction) -> HotkeyBinding? {
		return bindings.first { binding in
			binding.action != excludeAction && binding.keys.contains(key)
		}
	}

	// MARK: - Lookup table

	/// Build the key -> HotkeyAction dictionary.
	/// When two actions share a key, the one changed from its default gets it (the change is the newer intent).
	static func resolve(_ bindings: [HotkeyBinding]) -> (table: [HotkeyKey: HotkeyAction], conflicts: [String]) {
		let isChanged = { (binding: HotkeyBinding) in binding.keys != defaultKeys[binding.action] }
		var table: [HotkeyKey: HotkeyAction] = [:]
		var conflicts: [String] = []
		for binding in bindings.filter({ !isChanged($0) }) + bindings.filter(isChanged) {
			for key in binding.keys {
				if let other = table[key], other != binding.action {
					conflicts.append("\(key.string) is set for both \"\(other.rawValue)\" and \"\(binding.action.rawValue)\". Only \"\(binding.action.rawValue)\" gets it.")
				}
				table[key] = binding.action
			}
		}
		return (table, conflicts)
	}

}
