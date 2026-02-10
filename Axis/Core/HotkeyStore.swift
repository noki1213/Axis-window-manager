//
//  HotkeyStore.swift
//  Axis
//
//  Manages saving/loading hotkey settings
//

import Foundation
import Combine

/// A singleton that manages saving and loading hotkey settings
class HotkeyStore: ObservableObject {
	static let shared = HotkeyStore()

	/// The current list of key bindings
	@Published var bindings: [HotkeyBinding] = []

	/// The path to the save destination file
	private let saveURL: URL = {
		let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		let axisDir = appSupport.appendingPathComponent("Axis")
		// Create the directory if it doesn't exist
		try? FileManager.default.createDirectory(at: axisDir, withIntermediateDirectories: true)
		return axisDir.appendingPathComponent("hotkeys.json")
	}()

	private init() {
		loadFromDisk()
	}

	// MARK: - Loading

	/// Load key settings from the JSON file. Falls back to default values if the file doesn't exist.
	/// If new actions have been added, fill them in with their default values.
	func loadFromDisk() {
		let defaults = HotkeyBinding.defaults()

		guard FileManager.default.fileExists(atPath: saveURL.path) else {
			bindings = defaults
			return
		}

		do {
			let data = try Data(contentsOf: saveURL)
			let decoded = try JSONDecoder().decode([HotkeyBinding].self, from: data)

			// The set of saved actions
			let savedActions = Set(decoded.map { $0.action })

			// Fill in any unsaved actions with their default values
			var merged = decoded
			for defaultBinding in defaults {
				if !savedActions.contains(defaultBinding.action) {
					merged.append(defaultBinding)
				}
			}

			bindings = merged
		} catch {
			print("[Axis] ホットキー設定の読み込みに失敗: \(error). デフォルト値を使用します。")
			bindings = defaults
		}
	}

	// MARK: - Saving

	/// Save the current key settings to a JSON file
	func saveToDisk() {
		do {
			let encoder = JSONEncoder()
			encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
			let data = try encoder.encode(bindings)
			try data.write(to: saveURL, options: .atomic)
		} catch {
			print("[Axis] ホットキー設定の保存に失敗: \(error)")
		}
	}

	// MARK: - Reset to defaults

	/// Reset every key binding to its default
	func resetToDefaults() {
		bindings = HotkeyBinding.defaults()
		saveToDisk()
	}

	// MARK: - Updating key settings

	/// Update the key setting for a specific action
	func updateBinding(action: HotkeyAction, keyCode: Int, modifiers: HotkeyModifiers) {
		if let index = bindings.firstIndex(where: { $0.action == action }) {
			bindings[index].keyCode = keyCode
			bindings[index].modifiers = modifiers
			saveToDisk()
		}
	}

	// MARK: - Duplicate check

	/// Check whether the given key code + modifier combination is already used by another action.
	/// Returns that action if it's already in use.
	func findConflict(keyCode: Int, modifiers: HotkeyModifiers, excludeAction: HotkeyAction) -> HotkeyBinding? {
		return bindings.first { binding in
			binding.action != excludeAction &&
			binding.keyCode == keyCode &&
			binding.modifiers == modifiers
		}
	}

	// MARK: - Lookup table

	/// Build the (keyCode, modifiers) -> HotkeyAction dictionary
	func buildLookupTable() -> [HotkeyLookupKey: HotkeyAction] {
		var table: [HotkeyLookupKey: HotkeyAction] = [:]
		for binding in bindings {
			let key = binding.lookupKey
			table[key] = binding.action
		}
		return table
	}

	/// Return every modifier-key combination used in the lookup table (used for the EventTap filter)
	func allUsedModifiers() -> Set<HotkeyModifiers> {
		return Set(bindings.map { $0.modifiers })
	}
}
