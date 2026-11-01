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
			if !store.problems.isEmpty {
				HotkeyProblemsView(problems: store.problems)
				Divider()
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

			Divider()

			// Reset-to-default button
			HStack {
				Spacer()
				Button("Reset to Defaults") {
					store.resetToDefaults()
				}
				.padding()
			}
		}
		.alert(item: $conflictAlert) { info in
			Alert(
				title: Text("Key Already Assigned"),
				message: Text("Already used by \(info.conflictingDisplayName)."),
				dismissButton: .default(Text("OK"))
			)
		}
	}

	/// Update a key setting (with a duplicate check)
	private func handleUpdate(action: HotkeyAction, key: HotkeyKey) {
		// Duplicate check
		if let conflict = store.findConflict(key: key, excludeAction: action) {
			conflictAlert = ConflictAlertInfo(conflictingDisplayName: conflict.displayName)
			return
		}

		store.updateBinding(action: action, key: key)
	}
}

/// Data for the duplicate alert
struct ConflictAlertInfo: Identifiable {
	let id = UUID()
	let conflictingDisplayName: String
}

// MARK: - Problems with hotkeys.json

/// Lists what's wrong with hotkeys.json above the shortcuts
struct HotkeyProblemsView: View {
	let problems: [String]

	var body: some View {
		HStack(alignment: .top, spacing: 8) {
			Image(systemName: "exclamationmark.triangle.fill")
				.foregroundColor(.orange)
			VStack(alignment: .leading, spacing: 4) {
				ForEach(problems, id: \.self) { problem in
					Text(problem)
						.font(.callout)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			Spacer(minLength: 0)
		}
		.padding(12)
		.background(Color.orange.opacity(0.1))
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
