//
//  ShortcutsSettingsView.swift
//  Axis
//
//  The shortcut-key settings screen
//

import SwiftUI

/// The overall view for the shortcut settings tab
struct ShortcutsSettingsView: View {
	@ObservedObject private var store = HotkeyStore.shared

	/// For showing a duplicate-error alert
	@State private var conflictAlert: ConflictAlertInfo?

	var body: some View {
		VStack(spacing: 0) {
			ScrollView {
				VStack(alignment: .leading, spacing: 16) {
					ForEach(HotkeySection.allCases, id: \.rawValue) { section in
						ShortcutSectionView(
							section: section,
							bindings: store.bindings.filter { $0.section == section },
							onUpdate: { action, keyCode, modifiers in
								handleUpdate(action: action, keyCode: keyCode, modifiers: modifiers)
							}
						)
					}
				}
				.padding()
			}

			Divider()

			// Reset-to-default button
			HStack {
				Spacer()
				Button("デフォルトに戻す") {
					store.resetToDefaults()
					HotkeyManager.shared.reloadBindings()
				}
				.padding()
			}
		}
		.alert(item: $conflictAlert) { info in
			Alert(
				title: Text("キーの重複"),
				message: Text("\(info.conflictingDisplayName) で既に使用されています。"),
				dismissButton: .default(Text("OK"))
			)
		}
	}

	/// Update a key setting (with a duplicate check)
	private func handleUpdate(action: HotkeyAction, keyCode: Int, modifiers: HotkeyModifiers) {
		// Duplicate check
		if let conflict = store.findConflict(keyCode: keyCode, modifiers: modifiers, excludeAction: action) {
			conflictAlert = ConflictAlertInfo(conflictingDisplayName: conflict.displayName)
			return
		}

		store.updateBinding(action: action, keyCode: keyCode, modifiers: modifiers)
		HotkeyManager.shared.reloadBindings()
	}
}

/// Data for the duplicate alert
struct ConflictAlertInfo: Identifiable {
	let id = UUID()
	let conflictingDisplayName: String
}

// MARK: - Section view

/// A single section (heading + list of keys)
struct ShortcutSectionView: View {
	let section: HotkeySection
	let bindings: [HotkeyBinding]
	let onUpdate: (HotkeyAction, Int, HotkeyModifiers) -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(section.rawValue)
				.font(.headline)
				.padding(.bottom, 4)

			ForEach(bindings) { binding in
				ShortcutRowView(
					binding: binding,
					onUpdate: { keyCode, modifiers in
						onUpdate(binding.action, keyCode, modifiers)
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
	let onUpdate: (Int, HotkeyModifiers) -> Void

	var body: some View {
		HStack {
			Text(binding.displayName)
				.frame(maxWidth: .infinity, alignment: .leading)

			KeyRecorderButton(
				currentKeyCode: binding.keyCode,
				currentModifiers: binding.modifiers,
				onRecorded: { keyCode, modifiers in
					onUpdate(keyCode, modifiers)
				}
			)
			.frame(width: 180, height: 28)
		}
		.padding(.vertical, 2)
	}
}
