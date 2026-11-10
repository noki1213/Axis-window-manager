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
					.foregroundColor(Color(red: 0xfc / 255, green: 0x9c / 255, blue: 0x9c / 255))
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
							onUpdate: { action, key in
								handleUpdate(action: action, key: key)
							}
						)
					}
				}
				.padding()
			}

			Rectangle()
				.fill(Color.white.opacity(0.12))
				.frame(height: 1)

			// Reset-to-default button
			HStack {
				Spacer()
				TextButton(title: "Reset to Defaults") {
					store.resetToDefaults()
				}
				.padding(12)
			}
		}
	}

	/// Update a key setting (with a duplicate check)
	private func handleUpdate(action: HotkeyAction, key: HotkeyKey) {
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
	let onUpdate: (HotkeyAction, HotkeyKey) -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(section.rawValue)
				.font(.headline)
				.foregroundColor(PanelPalette.selectedText)
				.padding(.bottom, 4)

			ForEach(bindings) { binding in
				ShortcutRowView(
					binding: binding,
					onUpdate: { key in
						onUpdate(binding.action, key)
					}
				)
			}
		}
	}
}

// MARK: - Single-row shortcut display

/// A single key assignment (action name + record button)
struct ShortcutRowView: View {
	let binding: HotkeyBinding
	let onUpdate: (HotkeyKey) -> Void

	var body: some View {
		HStack {
			Text(binding.displayName)
				.frame(maxWidth: .infinity, alignment: .leading)

			KeyRecorderButton(
				currentKeys: binding.keys,
				onRecorded: { key in
					onUpdate(key)
				}
			)
			.frame(width: 180, height: 28)
		}
		.padding(.vertical, 2)
	}
}
