//
//  ShortcutsSettingsView.swift
//  Axis
//
//  The shortcut-key settings screen
//

import SwiftUI
import Combine

/// The overall view for the shortcut settings tab
struct ShortcutsSettingsView: View {
	@ObservedObject private var store = HotkeyStore.shared

	/// The name of the action that already uses the key just recorded
	@State private var conflictName: String?
	@State private var conflictClearTask: DispatchWorkItem?

	var body: some View {
		VStack(spacing: 0) {
			if let conflictName {
				Text("Key already used by \(conflictName).")
					.foregroundColor(Palette.red)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(.horizontal, 20)
					.padding(.top, 12)
			}

			ScrollView {
				VStack(alignment: .leading, spacing: 16) {
					ForEach(HotkeySection.allCases, id: \.rawValue) { section in
						ShortcutSectionView(
							section: section,
							bindings: store.bindings.filter { $0.section == section },
							keyColumnWidth: keyColumnWidth,
							onUpdate: { action, key in
								handleUpdate(action: action, key: key)
							}
						)
					}
				}
				.padding()
			}

			Rectangle()
				.fill(Palette.line)
				.frame(height: 1)

			// Reset-to-default button
			HStack {
				Spacer()
				OutlineButton(title: "Reset to Defaults") {
					store.resetToDefaults()
				}
				.padding(12)
			}
		}
	}

	/// One key column width for every cell, fitted to the longest key name in the list
	private var keyColumnWidth: CGFloat {
		KeyCellMetrics.keyColumnWidth(for: store.bindings.flatMap(\.keys))
	}

	/// Update a key setting (with a duplicate check); nil clears it
	private func handleUpdate(action: HotkeyAction, key: HotkeyKey?) {
		guard let key else {
			store.clearBinding(action: action)
			return
		}
		// Duplicate check
		if let conflict = store.findConflict(key: key, excludeAction: action) {
			conflictName = conflict.displayName
			conflictClearTask?.cancel()
			let task = DispatchWorkItem { conflictName = nil }
			conflictClearTask = task
			DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: task)
			return
		}

		conflictName = nil
		store.updateBinding(action: action, key: key)
	}
}

// MARK: - Section view

/// A single section (heading + list of keys)
struct ShortcutSectionView: View {
	let section: HotkeySection
	let bindings: [HotkeyBinding]
	let keyColumnWidth: CGFloat
	let onUpdate: (HotkeyAction, HotkeyKey?) -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(section.rawValue)
				.font(.headline)
				.foregroundColor(Palette.text)
				.padding(.bottom, 4)

			ForEach(bindings) { binding in
				ShortcutRowView(
					binding: binding,
					keyColumnWidth: keyColumnWidth,
					onUpdate: { key in
						onUpdate(binding.action, key)
					}
				)
			}
		}
	}
}

// MARK: - Single-row shortcut display

/// A single key assignment (action name + one key cell per key)
struct ShortcutRowView: View {
	let binding: HotkeyBinding
	let keyColumnWidth: CGFloat
	let onUpdate: (HotkeyKey?) -> Void

	var body: some View {
		HStack {
			Text(binding.displayName)
				.frame(maxWidth: .infinity, alignment: .leading)

			VStack(spacing: 4) {
				if binding.keys.isEmpty {
					KeyRecorderButton(key: nil, keyColumnWidth: keyColumnWidth, onRecorded: onUpdate)
				} else {
					ForEach(binding.keys, id: \.self) { key in
						KeyRecorderButton(key: key, keyColumnWidth: keyColumnWidth, onRecorded: onUpdate)
					}
				}
			}
		}
		.padding(.vertical, 2)
	}
}
