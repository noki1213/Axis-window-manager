//
//  KeyRecorderButton.swift
//  Axis
//
//  A key cell: modifiers in fixed columns, then the key. Click it, then press the key to assign.
//

import SwiftUI
import AppKit
import Carbon
import Combine

/// The fixed layout of key cells: four modifier columns (⌘ ⌥ ⌃ ⇧) and a key column
enum KeyCellMetrics {
	static let modifierWidth: CGFloat = 18
	static let height: CGFloat = 26
	static let padding: CGFloat = 8
	static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)

	/// The key column width that fits the longest key name among the given keys
	static func keyColumnWidth(for keys: [HotkeyKey]) -> CGFloat {
		let widest = keys
			.map { ($0.keyName as NSString).size(withAttributes: [.font: font]).width }
			.max() ?? 0
		return ceil(max(widest, 16)) + 4
	}

	static func cellWidth(keyColumnWidth: CGFloat) -> CGFloat {
		modifierWidth * 4 + keyColumnWidth + padding * 2
	}
}

/// One key cell. Recording state is local to the cell; `onRecorded` gets nil when Delete clears the key.
struct KeyRecorderButton: View {
	/// The key shown; nil for an empty cell
	let key: HotkeyKey?
	let keyColumnWidth: CGFloat
	let onRecorded: (HotkeyKey?) -> Void

	@StateObject private var recorder = KeyRecorder()

	var body: some View {
		let width = KeyCellMetrics.cellWidth(keyColumnWidth: keyColumnWidth)
		ZStack {
			if recorder.isRecording {
				Text("Press keys…")
					.font(.system(size: 11))
					.foregroundColor(Palette.brightGreen)
			} else if let key {
				HStack(spacing: 0) {
					ForEach(KeyCellModifier.allCases, id: \.self) { modifier in
						Text(modifier.symbol)
							.opacity(key.modifiers.contains(modifier.flag) ? 1 : 0)
							.frame(width: KeyCellMetrics.modifierWidth)
					}
					Text(key.keyName)
						.lineLimit(1)
						.minimumScaleFactor(0.6)
						.frame(width: keyColumnWidth)
				}
				.font(.system(size: 13, weight: .semibold, design: .rounded))
				.foregroundColor(Palette.text)
			} else {
				Text("None")
					.font(.system(size: 11))
					.foregroundColor(Palette.secondaryText)
			}
		}
		.frame(width: width, height: KeyCellMetrics.height)
		.background(background)
		.overlay(border)
		.contentShape(Rectangle())
		.onTapGesture {
			if recorder.isRecording {
				recorder.stop()
			} else {
				recorder.start(onRecorded: onRecorded)
			}
		}
	}

	private var shape: RoundedRectangle {
		RoundedRectangle(cornerRadius: 7, style: .continuous)
	}

	@ViewBuilder private var background: some View {
		if recorder.isRecording {
			shape.fill(Palette.green.opacity(0.12))
		} else if key != nil {
			shape.fill(Palette.pureBlack.opacity(0.55))
		} else {
			Color.clear
		}
	}

	@ViewBuilder private var border: some View {
		if recorder.isRecording {
			shape.strokeBorder(Palette.green, lineWidth: 1)
		} else if key != nil {
			shape.strokeBorder(Palette.line, lineWidth: 1)
		} else {
			shape.strokeBorder(Palette.pureWhite.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
		}
	}
}

/// The modifier columns, in display order
enum KeyCellModifier: CaseIterable {
	case command, option, control, shift

	var symbol: String {
		switch self {
		case .command: return "⌘"
		case .option: return "⌥"
		case .control: return "⌃"
		case .shift: return "⇧"
		}
	}

	var flag: HotkeyModifiers {
		switch self {
		case .command: return .command
		case .option: return .option
		case .control: return .control
		case .shift: return .shift
		}
	}
}

/// Listens for the next key press while a cell is recording
final class KeyRecorder: ObservableObject {
	@Published private(set) var isRecording = false
	private var onRecorded: ((HotkeyKey?) -> Void)?
	private var localMonitor: Any?
	private var resignObserver: NSObjectProtocol?

	/// The recorder listening now. Starting another ends it, so a key press goes to one cell only
	private static weak var active: KeyRecorder?

	func start(onRecorded: @escaping (HotkeyKey?) -> Void) {
		if Self.active !== self {
			Self.active?.stop()
		}
		Self.active = self
		removeListeners()

		self.onRecorded = onRecorded
		isRecording = true
		HotkeyManager.shared.isRecordingHotkey = true

		localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			self?.handle(event)
			return nil
		}
		// Recording ends when the window is left: keys typed anywhere else aren't meant for the
		// cell, and the shortcuts are off for as long as it listens
		resignObserver = NotificationCenter.default.addObserver(
			forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
		) { [weak self] _ in
			self?.stop()
		}
	}

	func stop() {
		guard isRecording else { return }
		isRecording = false
		HotkeyManager.shared.isRecordingHotkey = false
		removeListeners()
		onRecorded = nil
	}

	private func removeListeners() {
		if let monitor = localMonitor { NSEvent.removeMonitor(monitor) }
		if let observer = resignObserver { NotificationCenter.default.removeObserver(observer) }
		localMonitor = nil
		resignObserver = nil
	}

	private func handle(_ event: NSEvent) {
		let modifiers = HotkeyModifiers.from(event.modifierFlags)
		let callback = onRecorded
		switch Int(event.keyCode) {
		case kVK_Escape:
			stop()
		case kVK_Delete where modifiers.isEmpty:
			stop()
			callback?(nil)
		default:
			stop()
			callback?(HotkeyKey(keyCode: Int(event.keyCode), modifiers: modifiers))
		}
	}

	deinit {
		if isRecording {
			HotkeyManager.shared.isRecordingHotkey = false
		}
		if let monitor = localMonitor { NSEvent.removeMonitor(monitor) }
		if let observer = resignObserver { NotificationCenter.default.removeObserver(observer) }
	}
}
