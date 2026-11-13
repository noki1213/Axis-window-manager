//
//  GlassPopup.swift
//  Axis
//
//  A popup on a dark Liquid Glass sheet, centered on the screen with the mouse. Settings and
//  dialogs use it. It takes the keyboard while open and hands the focus back to the app that was
//  in front when it closes.
//

import AppKit
import Combine
import SwiftUI

/// Drives the sheet's appearance: 0 = before appearing, 1 = fully materialized.
final class GlassPopupState: ObservableObject {
	@Published var progress: CGFloat = 0
}

/// The glass sheet around a popup's content, with the materialize animation.
struct GlassPopupSheet<Content: View>: View {
	@ObservedObject var state: GlassPopupState
	let size: CGSize
	let content: Content

	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

	var body: some View {
		content
			.foregroundColor(Palette.text)
			.frame(width: size.width, height: size.height)
			.background(GlassBackground(shape: shape))
			.clipShape(shape)
			.overlay(shape.strokeBorder(Palette.line, lineWidth: 1))
			.scaleEffect(reduceMotion ? 1 : 0.94 + 0.06 * state.progress)
			.blur(radius: reduceMotion ? 0 : (1 - state.progress) * 12)
			.opacity(Double(state.progress))
	}
}

/// A panel that takes the keyboard and can be dragged by its outer edge.
private final class GlassPopupPanel: NSPanel {
	private static let dragEdge: CGFloat = 10

	override var canBecomeKey: Bool { true }

	/// AppKit asks the window for these two values when it decides how to draw glass; answering
	/// the same in every focus state keeps the glass dense instead of washing out when unfocused.
	@objc func hasKeyAppearance() -> Bool { true }
	@objc func hasMainAppearance() -> Bool { true }

	/// Dragging the whole background would fight with text selection and drag and drop, so only
	/// a press on the outer edge moves the window.
	override func sendEvent(_ event: NSEvent) {
		if event.type == .leftMouseDown {
			let point = event.locationInWindow
			let bounds = contentView?.bounds ?? .zero
			let inner = bounds.insetBy(dx: Self.dragEdge, dy: Self.dragEdge)
			if bounds.contains(point), !inner.contains(point) {
				performDrag(with: event)
				return
			}
		}
		super.sendEvent(event)
	}
}

/// Shows one popup at a time and closes it on Esc.
final class GlassPopupController<Content: View> {
	let state = GlassPopupState()
	var isVisible: Bool { panel.isVisible }
	/// Called with a key press while the popup is key; return true when it was used.
	var keyHandler: ((NSEvent) -> Bool)?
	var onHide: (() -> Void)?

	private let panel: GlassPopupPanel
	private let size: CGSize
	private var keyMonitor: Any?
	private var previousApp: NSRunningApplication?
	private let closesOnEscape: Bool
	private let closesOnDeactivate: Bool
	private var deactivateObserver: NSObjectProtocol?

	init(size: CGSize, closesOnEscape: Bool = true, closesOnDeactivate: Bool = false,
		 content: @escaping (GlassPopupState) -> Content) {
		self.size = size
		self.closesOnEscape = closesOnEscape
		self.closesOnDeactivate = closesOnDeactivate
		panel = GlassPopupPanel(contentRect: NSRect(origin: .zero, size: size),
								styleMask: [.nonactivatingPanel, .borderless],
								backing: .buffered, defer: false)
		panel.level = .floating
		panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
		panel.hidesOnDeactivate = false
		panel.backgroundColor = .clear
		panel.isOpaque = false
		panel.hasShadow = false
		panel.isReleasedWhenClosed = false
		// The sheet is always dark, so system text and controls take their dark-ground colours.
		panel.appearance = NSAppearance(named: .darkAqua)
		let hosting = NSHostingView(rootView: GlassPopupSheet(state: state, size: size, content: content(state)))
		hosting.sizingOptions = []
		panel.contentView = hosting
	}

	func show() {
		if !panel.isVisible {
			let front = NSWorkspace.shared.frontmostApplication
			previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
			// Not animated: the reveal must start from zero, not from wherever a previous one stopped.
			state.progress = 0
			place()
		}
		NSApp.activate(ignoringOtherApps: true)
		panel.makeKeyAndOrderFront(nil)
		installMonitors()

		DispatchQueue.main.async { [weak self] in
			guard let self, self.panel.isVisible, self.state.progress == 0 else { return }
			let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
			withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.30, dampingFraction: 1)) {
				self.state.progress = 1
			}
		}
	}

	/// Disappears at once, then returns the focus to the app that was in front.
	func hide() {
		guard panel.isVisible else { return }
		removeMonitors()
		panel.orderOut(nil)
		state.progress = 0
		if let previousApp {
			NSApp.yieldActivation(to: previousApp)
			previousApp.activate()
		}
		previousApp = nil
		onHide?()
	}

	/// The center of the screen the mouse is on.
	private func place() {
		let mouse = NSEvent.mouseLocation
		let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
		let area = screen?.visibleFrame ?? .zero
		panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
							  width: size.width, height: size.height), display: true)
	}

	private func installMonitors() {
		removeMonitors()
		keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			guard let self, self.panel.isKeyWindow else { return event }
			// A shortcut being recorded takes every key, Esc included.
			if HotkeyManager.shared.isRecordingHotkey { return event }
			if let handler = self.keyHandler, handler(event) { return nil }
			if self.closesOnEscape, event.keyCode == 53 {
				self.hide()
				return nil
			}
			return event
		}
		if closesOnDeactivate {
			deactivateObserver = NotificationCenter.default.addObserver(
				forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
			) { [weak self] _ in
				guard let self, self.panel.isVisible else { return }
				// Closed without handing focus back: the app that took it is already in front.
				self.previousApp = nil
				self.hide()
			}
		}
	}

	private func removeMonitors() {
		if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
		keyMonitor = nil
		if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
		deactivateObserver = nil
	}
}

// MARK: - Text buttons

/// A button drawn as a thin outline that fills under the pointer. `isPrimary` marks the verb of a dialog in green.
struct OutlineButton: View {
	let title: String
	var isPrimary = false
	let action: () -> Void

	@State private var isHovered = false

	private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 8, style: .continuous) }

	var body: some View {
		Button(action: action) {
			Text(title)
				.foregroundColor(isHovered ? Palette.text : (isPrimary ? Palette.brightGreen : Palette.secondaryText))
				.padding(.horizontal, 14)
				.padding(.vertical, 5)
				.background(shape.fill(isHovered ? (isPrimary ? Palette.green.opacity(0.40) : Palette.pureWhite.opacity(0.14)) : .clear))
				.overlay(shape.strokeBorder(isHovered ? .clear : (isPrimary ? Palette.green.opacity(0.70) : Palette.line), lineWidth: 1))
				.contentShape(shape)
		}
		.buttonStyle(.plain)
		.onHover { hovering in
			withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
		}
	}
}

// MARK: - Dialog

/// A question or notice in the same sheet: Cancel on the left, the verb on the right.
struct GlassDialogView: View {
	let title: String
	let message: String
	let cancelTitle: String?
	let confirmTitle: String
	let onCancel: () -> Void
	let onConfirm: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text(title)
				.font(.title3.weight(.semibold))
				.foregroundColor(Palette.text)
			Text(message)
				.foregroundColor(Palette.secondaryText)
				.fixedSize(horizontal: false, vertical: true)
			Spacer(minLength: 0)
			HStack {
				if let cancelTitle {
					OutlineButton(title: cancelTitle, action: onCancel)
						.keyboardShortcut(.cancelAction)
				}
				Spacer()
				OutlineButton(title: confirmTitle, isPrimary: true, action: onConfirm)
					.keyboardShortcut(.defaultAction)
			}
		}
		.padding(24)
	}
}

/// Shows a dialog on the glass sheet. The choice runs once, and the popup closes first.
final class GlassDialog {
	private var controller: GlassPopupController<GlassDialogView>?

	/// `onCancel` also runs for Esc. Without `cancelTitle` the dialog only has its verb.
	func show(title: String, message: String, cancelTitle: String? = nil, confirmTitle: String,
			  onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void = {}) {
		var finished = false
		let finish: (@escaping () -> Void) -> () -> Void = { action in
			{ [weak self] in
				guard !finished else { return }
				finished = true
				self?.controller?.hide()
				self?.controller = nil
				action()
			}
		}
		let popup = GlassPopupController(size: CGSize(width: 420, height: 220)) { _ in
			GlassDialogView(title: title, message: message, cancelTitle: cancelTitle, confirmTitle: confirmTitle,
							onCancel: finish(onCancel), onConfirm: finish(onConfirm))
		}
		popup.keyHandler = { event in
			switch event.keyCode {
			case 36, 76: // Return, Enter
				finish(onConfirm)()
				return true
			case 53: // Esc
				finish(cancelTitle == nil ? onConfirm : onCancel)()
				return true
			default:
				return false
			}
		}
		controller = popup
		popup.show()
	}
}
