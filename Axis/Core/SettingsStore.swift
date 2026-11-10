//
//  SettingsStore.swift
//  Axis
//
//  The settings file: every setting except the shortcuts (hotkeys.json), kept in
//  ~/Library/Application Support/Axis/settings.json. The file may be a symlink; Axis reads and
//  writes the file it points to and picks up edits to it while running.
//

import Foundation
import Combine

/// A singleton that loads, watches and saves settings.json.
///
/// The file is a JSON object. Keys Axis doesn't know are kept when it saves; a value of the wrong
/// type or out of range is reported in `problems` and the default is used for that key only.
final class SettingsStore: ObservableObject {
	static let shared = SettingsStore()

	/// Posted after the file was changed by something other than Axis
	let externalChange = PassthroughSubject<Void, Never>()

	/// What is wrong with settings.json, one line each (empty when nothing is)
	@Published private(set) var problems: [String] = []

	private let saveURL: URL = {
		let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		let dir = appSupport.appendingPathComponent("Axis")
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir.appendingPathComponent("settings.json")
	}()

	/// The file actually read and written: the symlink's destination when settings.json is a link
	private var fileURL: URL { saveURL.resolvingSymlinksInPath() }

	/// Read from any thread (the measurement log asks from background queues), so access goes through the lock
	private let lock = NSLock()
	private var storedValues: [String: Any] = [:]
	private var values: [String: Any] {
		get { lock.lock(); defer { lock.unlock() }; return storedValues }
		set { lock.lock(); defer { lock.unlock() }; storedValues = newValue }
	}

	/// Set while the file exists but can't be read as a JSON object. Saving would wipe what the user wrote.
	private var fileIsUnreadable = false

	private var lastSeenStamp: FileStamp?
	private var watchTimer: Timer?
	private static let watchInterval: TimeInterval = 2.0

	private init() {
		loadFromDisk()
		importPreviousSettings()
		startWatching()
	}

	/// Settings that earlier versions kept in the app's preferences move into the file the first time it is missing
	private func importPreviousSettings() {
		guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
		let defaults = UserDefaults.standard
		var imported: [String: Any] = [:]
		for (old, new) in [("focusFollowsMouseEnabled", "focusFollowsMouse"),
		                   ("focusFollowsMouseDelayMs", "focusFollowsMouseDelayMs"),
		                   ("focusHistorySettleSeconds", "focusBackSettleSeconds"),
		                   ("perfLogEnabled", "perfLog")] {
			if let value = defaults.object(forKey: old) { imported[new] = value }
		}
		if let apps = defaults.array(forKey: "floatingApps") as? [[String: String]] {
			imported["floatingApps"] = apps.compactMap { $0["bundleID"] }
		}
		guard !imported.isEmpty else { return }
		values = imported
		saveToDisk()
	}

	// MARK: - Reading

	/// The value of a key as `Bool`, or `fallback` when the key is missing or not a boolean
	func bool(_ key: String, default fallback: Bool) -> Bool {
		guard let value = values[key] else { return fallback }
		guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
			report("\"\(key)\": expected true or false. Using the default.")
			return fallback
		}
		return number.boolValue
	}

	/// The value of a key as a number within `range`, or `fallback` when missing, not a number or out of range
	func number(_ key: String, default fallback: Double, in range: ClosedRange<Double>) -> Double {
		guard let value = values[key] else { return fallback }
		guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
			report("\"\(key)\": expected a number. Using the default.")
			return fallback
		}
		guard range.contains(number.doubleValue) else {
			report("\"\(key)\": must be between \(Self.format(range.lowerBound)) and \(Self.format(range.upperBound)). Using the default.")
			return fallback
		}
		return number.doubleValue
	}

	/// The value of a key as a list of strings, or `fallback` when missing or not a list of strings
	func strings(_ key: String, default fallback: [String]) -> [String] {
		guard let value = values[key] else { return fallback }
		guard let list = value as? [String] else {
			report("\"\(key)\": expected a list of strings. Using the default.")
			return fallback
		}
		return list
	}

	private static func format(_ value: Double) -> String {
		value == value.rounded() ? String(Int(value)) : String(value)
	}

	// MARK: - Writing

	/// Save one key, leaving every other entry in the file as it is
	func set(_ key: String, _ value: Any) {
		if let old = values[key] as? NSObject, old.isEqual(value) { return }
		values[key] = value
		saveToDisk()
	}

	private func saveToDisk() {
		if fileIsUnreadable {
			report("settings.json can't be read, so changes made here aren't saved to it. Fix the file to save again.")
			return
		}
		do {
			try write(values, to: fileURL)
		} catch {
			report("Couldn't save settings.json: \(error.localizedDescription)")
		}
	}

	private func write(_ object: [String: Any], to url: URL) throws {
		var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
		data.append(Data("\n".utf8))
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		try data.write(to: url, options: .atomic)
		lastSeenStamp = FileStamp(of: url)
	}

	// MARK: - Loading

	private func loadFromDisk() {
		let url = fileURL
		lastSeenStamp = FileStamp(of: url)
		problems = []

		guard FileManager.default.fileExists(atPath: url.path) else {
			fileIsUnreadable = false
			values = [:]
			return
		}
		do {
			let data = try Data(contentsOf: url)
			guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
				markUnreadable("settings.json is not a JSON object")
				return
			}
			fileIsUnreadable = false
			values = object
		} catch {
			let reason = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
			let trimmed = reason.hasSuffix(".") ? String(reason.dropLast()) : reason
			markUnreadable("settings.json can't be read: \(trimmed)")
		}
	}

	/// A file that can't be used at all: the settings in use stay as they are
	private func markUnreadable(_ reason: String) {
		fileIsUnreadable = true
		problems = ["\(reason). Keeping the settings in use."]
	}

	private func report(_ message: String) {
		DispatchQueue.main.async { [self] in
			if !problems.contains(message) {
				problems.append(message)
			}
		}
	}

	// MARK: - Watching for edits

	private func startWatching() {
		watchTimer = Timer.scheduledTimer(withTimeInterval: Self.watchInterval, repeats: true) { [weak self] _ in
			guard let self else { return }
			// Resolved on every check, so pointing the link somewhere else is picked up too
			guard FileStamp(of: self.fileURL) != self.lastSeenStamp else { return }
			self.loadFromDisk()
			if !self.fileIsUnreadable {
				self.externalChange.send()
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
}
