//
//  KeyRecorderButton.swift
//  Axis
//
//  A button for recording a shortcut key
//

import SwiftUI
import AppKit
import Carbon

/// A button that records a key press (a SwiftUI wrapper)
struct KeyRecorderButton: NSViewRepresentable {
	let currentKeyCode: Int
	let currentModifiers: HotkeyModifiers
	let onRecorded: (Int, HotkeyModifiers) -> Void

	func makeNSView(context: Context) -> KeyRecorderNSView {
		let view = KeyRecorderNSView()
		view.currentKeyCode = currentKeyCode
		view.currentModifiers = currentModifiers
		view.onRecorded = onRecorded
		view.updateDisplayText()
		return view
	}

	func updateNSView(_ nsView: KeyRecorderNSView, context: Context) {
		nsView.currentKeyCode = currentKeyCode
		nsView.currentModifiers = currentModifiers
		nsView.onRecorded = onRecorded
		if !nsView.isRecording {
			nsView.updateDisplayText()
		}
	}
}

/// The NSView that receives key input
class KeyRecorderNSView: NSView {
	var currentKeyCode: Int = 0
	var currentModifiers: HotkeyModifiers = []
	var onRecorded: ((Int, HotkeyModifiers) -> Void)?

	/// Whether it's currently recording
	var isRecording = false

	/// The local event monitor
	private var localMonitor: Any?
	private var globalMonitor: Any?

	/// The text field used for display
	private let label: NSTextField = {
		let field = NSTextField(labelWithString: "")
		field.alignment = .center
		field.font = NSFont.systemFont(ofSize: 12, weight: .medium)
		field.isEditable = false
		field.isSelectable = false
		field.isBordered = false
		field.drawsBackground = false
		return field
	}()

	/// The background box
	private let backgroundBox: NSBox = {
		let box = NSBox()
		box.boxType = .custom
		box.cornerRadius = 6
		box.borderWidth = 1
		box.borderColor = NSColor.separatorColor
		box.fillColor = NSColor.controlBackgroundColor
		return box
	}()

	override init(frame: NSRect) {
		super.init(frame: frame)
		setupViews()
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
		setupViews()
	}

	private func setupViews() {
		addSubview(backgroundBox)
		addSubview(label)

		backgroundBox.translatesAutoresizingMaskIntoConstraints = false
		label.translatesAutoresizingMaskIntoConstraints = false

		NSLayoutConstraint.activate([
			backgroundBox.leadingAnchor.constraint(equalTo: leadingAnchor),
			backgroundBox.trailingAnchor.constraint(equalTo: trailingAnchor),
			backgroundBox.topAnchor.constraint(equalTo: topAnchor),
			backgroundBox.bottomAnchor.constraint(equalTo: bottomAnchor),

			label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
			label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
			label.centerYAnchor.constraint(equalTo: centerYAnchor),
		])
	}

	override var intrinsicContentSize: NSSize {
		return NSSize(width: 160, height: 28)
	}

	// MARK: - Entering record mode via click

	override func mouseDown(with event: NSEvent) {
		if isRecording {
			stopRecording()
		} else {
			startRecording()
		}
	}

	// MARK: - Record mode

	private func startRecording() {
		isRecording = true
		HotkeyManager.shared.isRecordingHotkey = true

		label.stringValue = "Press a key..."
		label.textColor = NSColor.systemOrange
		backgroundBox.borderColor = NSColor.systemOrange
		backgroundBox.fillColor = NSColor.systemOrange.withAlphaComponent(0.1)

		// Receive key input through a local event monitor
		localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			self?.handleRecordedKey(event)
			return nil // イベントを消費
		}

		// Also add a global event monitor (a fallback for when the app loses focus)
		globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
			self?.handleRecordedKey(event)
		}
	}

	private func stopRecording() {
		isRecording = false
		HotkeyManager.shared.isRecordingHotkey = false

		if let monitor = localMonitor {
			NSEvent.removeMonitor(monitor)
			localMonitor = nil
		}
		if let monitor = globalMonitor {
			NSEvent.removeMonitor(monitor)
			globalMonitor = nil
		}

		updateDisplayText()
	}

	private func handleRecordedKey(_ event: NSEvent) {
		// Cancel with Escape
		if event.keyCode == kVK_Escape {
			stopRecording()
			return
		}

		// Ignore input that's only a modifier key (a regular key is required)
		let keyCode = Int(event.keyCode)
		let modifiers = HotkeyModifiers.from(event.modifierFlags)

		// Record it as a key code
		currentKeyCode = keyCode
		currentModifiers = modifiers

		// Notify via the callback
		onRecorded?(keyCode, modifiers)

		stopRecording()
	}

	// MARK: - Display update

	func updateDisplayText() {
		let binding = HotkeyBinding(
			action: .focusLeft, // ダミー（表示名の生成には使わない）
			keyCode: currentKeyCode,
			modifiers: currentModifiers
		)
		label.stringValue = binding.shortcutDisplayString
		label.textColor = NSColor.labelColor
		backgroundBox.borderColor = NSColor.separatorColor
		backgroundBox.fillColor = NSColor.controlBackgroundColor
	}

	// MARK: - Cleanup

	deinit {
		if isRecording {
			HotkeyManager.shared.isRecordingHotkey = false
		}
		if let monitor = localMonitor {
			NSEvent.removeMonitor(monitor)
		}
		if let monitor = globalMonitor {
			NSEvent.removeMonitor(monitor)
		}
	}
}
