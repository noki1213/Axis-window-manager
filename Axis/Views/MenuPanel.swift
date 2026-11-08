//
//  MenuPanel.swift
//  Axis
//
//  The menu bar icon's panel: the app's commands on a dark Liquid Glass sheet
//  under the status item.
//

import AppKit
import Combine
import SwiftUI

/// What the panel's rows do; supplied by the app delegate.
struct MenuPanelActions {
	let openHotkeyProblems: () -> Void
	let tileWindows: () -> Void
	let openSettings: () -> Void
	let quit: () -> Void
}

/// A row of the panel the pointer can rest on.
enum MenuPanelRow: Hashable {
	case hotkeyProblems, tileWindows, settings
}

/// State the controller drives and the sheet animates from.
final class MenuPanelState: ObservableObject {
	/// 0 = before appearing, 1 = fully materialized.
	@Published var materializeProgress: CGFloat = 0
	/// Where the status item sits along the panel's width (0 = left edge, 1 = right edge), so the
	/// open animation grows from the clicked icon even when the panel had to shift to stay on-screen.
	@Published var materializeAnchorX: CGFloat = 0.5
	/// The row under the pointer; cleared whenever the panel closes.
	@Published var hoveredRow: MenuPanelRow?
}

private struct PanelSizeKey: PreferenceKey {
	static var defaultValue: CGSize = .zero
	static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct MenuPanelView: View {
	@ObservedObject var state: MenuPanelState
	let actions: MenuPanelActions
	let onSizeChange: (CGSize) -> Void

	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

	/// Transparent room around the sheet for its shadow and the materialize blur.
	static let margin: CGFloat = 24

	var body: some View {
		MenuBarContentView(state: state, actions: actions)
			.fixedSize(horizontal: false, vertical: true)
			.background(GlassBackground(shape: shape))
			.clipShape(shape)
			.overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
			.shadow(color: Color.black.opacity(0.35), radius: 20, x: 0, y: 10)
			.offset(y: reduceMotion ? 0 : (1 - state.materializeProgress) * -8)
			.scaleEffect(reduceMotion ? 1 : 0.94 + 0.06 * state.materializeProgress,
						 anchor: UnitPoint(x: state.materializeAnchorX, y: 0))
			.blur(radius: reduceMotion ? 0 : (1 - state.materializeProgress) * 12)
			.opacity(Double(state.materializeProgress))
			.padding(Self.margin)
			.fixedSize()
			.background(GeometryReader { proxy in
				Color.clear.preference(key: PanelSizeKey.self, value: proxy.size)
			})
			.onPreferenceChange(PanelSizeKey.self) { onSizeChange($0) }
	}
}

private final class KeyablePanel: NSPanel {
	override var canBecomeKey: Bool { true }
}

/// Shows the panel under the status item without activating the app, and closes it on Esc, on a
/// click back on the icon, or on a click anywhere else.
final class MenuPanelController {
	let state = MenuPanelState()
	var onVisibilityChanged: ((Bool) -> Void)?

	private let actions: MenuPanelActions
	private let panel: NSPanel
	private var hostingView: NSHostingView<MenuPanelView>!
	private var keyMonitor: Any?
	private var clickMonitor: Any?
	/// The status item's screen rect while shown, so a click back on the icon is left for its own
	/// action to toggle instead of being closed here and immediately reopened.
	private var statusItemFrame: NSRect = .zero
	private var contentSize: CGSize = .zero

	var isVisible: Bool { panel.isVisible }

	init(actions: MenuPanelActions) {
		self.actions = actions
		panel = KeyablePanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
							 backing: .buffered, defer: false)
		panel.level = .popUpMenu
		panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
		panel.hidesOnDeactivate = false
		panel.backgroundColor = .clear
		panel.isOpaque = false
		panel.hasShadow = false
		// The sheet is always dark, so system text and controls take their dark-ground colours
		// whatever the system appearance is.
		panel.appearance = NSAppearance(named: .darkAqua)

		hostingView = NSHostingView(rootView: MenuPanelView(state: state, actions: actions, onSizeChange: { [weak self] size in
			self?.contentSizeChanged(size)
		}))
		// The hosting view doesn't resize the window itself, which would keep the bottom edge
		// fixed; the controller resizes it with the top edge pinned under the status item.
		hostingView.sizingOptions = []
		panel.contentView = hostingView
	}

	/// Opens the panel with its top edge just under `anchor` (the status item, in screen coordinates).
	/// Without `takesKey` it only comes to the front, so typing in the frontmost app carries on.
	func show(below anchor: NSRect, takesKey: Bool = true) {
		statusItemFrame = anchor
		// Not animated: the reveal must start from zero, not from wherever a previous one stopped.
		state.materializeProgress = 0
		layout()
		if takesKey {
			panel.makeKeyAndOrderFront(nil)
		} else {
			panel.orderFrontRegardless()
		}

		installMonitors()
		onVisibilityChanged?(true)
		DispatchQueue.main.async { [weak self] in
			guard let self, self.panel.isVisible else { return }
			let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
			withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.30, dampingFraction: 1)) {
				self.state.materializeProgress = 1
			}
		}
	}

	/// Disappears at once, so whatever the click outside was meant for isn't kept waiting.
	func hide() {
		guard panel.isVisible else { return }
		removeMonitors()
		panel.orderOut(nil)
		state.hoveredRow = nil
		onVisibilityChanged?(false)
	}

	/// Follows the content's height as the problems row comes and goes.
	private func contentSizeChanged(_ size: CGSize) {
		guard size.width > 0, size.height > 0 else { return }
		contentSize = size
		guard panel.isVisible else { return }
		layout()
	}

	private func layout() {
		var measured = contentSize
		if measured.width <= 0 || measured.height <= 0 {
			// The hosting view reports no fitting size (its sizing options are off), and the content
			// only reports its own size once it is laid out in a window of real size. Until then,
			// measure a copy of the view so the panel opens at a real size; the content's own report
			// then corrects the height.
			let unbounded = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
			measured = NSHostingController(rootView: MenuPanelView(state: state, actions: actions, onSizeChange: { _ in }))
				.sizeThatFits(in: unbounded)
		}
		let size = NSSize(width: ceil(measured.width), height: ceil(measured.height))
		guard size.width > 0, size.height > 0 else { return }
		let anchor = statusItemFrame
		let margin = MenuPanelView.margin
		let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
		let visible = screen?.visibleFrame ?? anchor
		var x = anchor.midX - size.width / 2
		x = min(max(x, visible.minX + 8 - margin), visible.maxX - 8 + margin - size.width)
		let y = anchor.minY - 6 + margin - size.height
		let anchorX = min(max((anchor.midX - x) / size.width, 0), 1)
		if state.materializeAnchorX != anchorX { state.materializeAnchorX = anchorX }
		let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
		guard frame != panel.frame else { return }
		panel.setFrame(frame, display: true)
		// Settle the layout at the new size first; otherwise a size change since the last opening
		// gets swept into the reveal and the sheet appears to grow out of its top-left corner.
		hostingView.layoutSubtreeIfNeeded()
	}

	// MARK: - Input

	private func installMonitors() {
		removeMonitors()
		keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			guard let self, self.panel.isKeyWindow else { return event }
			if event.keyCode == 53 { // Esc
				self.hide()
				return nil
			}
			if let action = self.action(forKeyEquivalent: event) {
				self.hide()
				action()
				return nil
			}
			return event
		}
		clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
			guard let self else { return }
			if self.statusItemFrame.contains(NSEvent.mouseLocation) { return }
			// A modal dialog opened from the panel is still using it.
			if NSApp.modalWindow != nil { return }
			Task { @MainActor in self.hide() }
		}
	}

	/// The commands' shortcuts (Control-Option plus a key), shown beside their rows.
	private func action(forKeyEquivalent event: NSEvent) -> (() -> Void)? {
		let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
			.subtracting([.capsLock, .numericPad, .function])
		guard modifiers == [.control, .option] else { return nil }
		switch event.charactersIgnoringModifiers?.lowercased() {
		case "t": return actions.tileWindows
		case ",": return actions.openSettings
		case "q": return actions.quit
		default: return nil
		}
	}

	private func removeMonitors() {
		if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
		if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
		keyMonitor = nil
		clickMonitor = nil
	}
}

// MARK: - Content

private enum PanelPalette {
	static let black = Color(.sRGB, red: 0x26 / 255, green: 0x24 / 255, blue: 0x27 / 255, opacity: 1)
	static let selection = Color(red: 0x33 / 255, green: 0xA5 / 255, blue: 0xA5 / 255).opacity(0.3)
	static let selectedText = Color(red: 0xfc / 255, green: 0xfc / 255, blue: 0xfa / 255)
}

struct MenuBarContentView: View {
	@ObservedObject var state: MenuPanelState
	let actions: MenuPanelActions

	@ObservedObject private var hotkeyStore = HotkeyStore.shared
	@Namespace private var rowNamespace
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			if !hotkeyStore.problems.isEmpty {
				VStack(alignment: .leading, spacing: 4) {
					row(.hotkeyProblems, title: "Problems in hotkeys.json…",
						symbol: "exclamationmark.triangle", symbolColor: .orange, shortcut: nil,
						action: actions.openHotkeyProblems)
					VStack(alignment: .leading, spacing: 2) {
						ForEach(hotkeyStore.problems, id: \.self) { problem in
							Text(problem)
								.font(.caption)
								.foregroundColor(.secondary)
								.fixedSize(horizontal: false, vertical: true)
						}
					}
					.padding(.horizontal, 6)
				}

				Divider()
			}

			VStack(alignment: .leading, spacing: 2) {
				row(.tileWindows, title: "Tile Windows", symbol: "rectangle.split.3x1",
					symbolColor: nil, shortcut: "⌃⌥T", action: actions.tileWindows)
				row(.settings, title: "Settings…", symbol: "gearshape",
					symbolColor: nil, shortcut: "⌃⌥,", action: actions.openSettings)
			}

			Divider()

			HStack {
				Button("Quit Axis", action: actions.quit)
				Spacer()
				Text("⌃⌥Q")
					.foregroundColor(.secondary)
			}
		}
		.padding(12)
		.frame(width: 280)
	}

	/// One command: the pointer moves the single highlight onto it, a click runs it.
	private func row(_ id: MenuPanelRow, title: String, symbol: String, symbolColor: Color?,
					 shortcut: String?, action: @escaping () -> Void) -> some View {
		let isHovered = state.hoveredRow == id
		return HStack(spacing: 6) {
			Image(systemName: symbol)
				.foregroundColor(symbolColor ?? (isHovered ? PanelPalette.selectedText : .secondary))
				.frame(width: 16)
			Text(title)
				.lineLimit(1)
				.foregroundColor(isHovered ? PanelPalette.selectedText : .primary)
			Spacer()
			if let shortcut {
				Text(shortcut)
					.foregroundColor(.secondary)
			}
		}
		.padding(.horizontal, 6)
		.frame(height: 26)
		.background {
			if isHovered {
				RoundedRectangle(cornerRadius: 9, style: .continuous)
					.fill(PanelPalette.selection)
					.matchedGeometryEffect(id: "menuRowHighlight", in: rowNamespace)
			}
		}
		.contentShape(Rectangle())
		.onHover { inside in
			withAnimation(reduceMotion ? .easeOut(duration: 0.1) : .spring(duration: 0.28, bounce: 0)) {
				if inside {
					state.hoveredRow = id
				} else if state.hoveredRow == id {
					state.hoveredRow = nil
				}
			}
		}
		.onTapGesture(perform: action)
	}
}

// MARK: - Material

private struct VisualEffectView: NSViewRepresentable {
	let material: NSVisualEffectView.Material
	let blendingMode: NSVisualEffectView.BlendingMode

	func makeNSView(context: Context) -> NSVisualEffectView {
		let view = NSVisualEffectView()
		view.material = material
		view.blendingMode = blendingMode
		view.state = .active
		return view
	}

	func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
		nsView.material = material
		nsView.blendingMode = blendingMode
	}
}

/// Liquid Glass tinted dark where the system has it, frosted blur under the same tint before that.
/// The tint fixes how bright the ground is, so light text stays readable over any window behind.
private struct GlassBackground<S: Shape>: View {
	let shape: S

	var body: some View {
		if #available(macOS 26.0, *) {
			GlassEffectContainer {
				shape
					.fill(Color.clear)
					.glassEffect(.regular.tint(PanelPalette.black.opacity(0.60)), in: shape)
			}
		} else {
			ZStack {
				VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
				PanelPalette.black.opacity(0.60)
			}
		}
	}
}
