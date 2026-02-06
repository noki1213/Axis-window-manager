//
//  StartupGuideView.swift
//  Axis
//
//  Created on 2026/02/06.
//

import SwiftUI

/// The guide popup shown at launch
/// Guides the user to move all windows onto a single desktop
struct StartupGuideView: View {
	var onContinue: () -> Void

	var body: some View {
		VStack(spacing: 24) {
			// Icon
			Image(systemName: "rectangle.on.rectangle")
				.font(.system(size: 48))
				.foregroundColor(.accentColor)

			// Title
			Text("Axis を開始する前に")
				.font(.title2)
				.fontWeight(.bold)

			// Description text
			VStack(alignment: .center, spacing: 16) {
				Text("Axis は macOS の仮想デスクトップを\nまたいでウィンドウを管理できません。")
					.foregroundColor(.secondary)
					.multilineTextAlignment(.center)
					.lineLimit(nil)
					.fixedSize(horizontal: false, vertical: true)

				Text("すべてのウィンドウを1つのデスクトップに\n移動してから続行してください。")
					.multilineTextAlignment(.center)
					.lineLimit(nil)
					.fixedSize(horizontal: false, vertical: true)
			}

			Spacer()

			// Continue button
			Button(action: onContinue) {
				HStack {
					Text("準備できました")
					Text("(Enter)")
						.foregroundColor(.secondary)
				}
				.frame(maxWidth: .infinity)
				.padding(.vertical, 8)
			}
			.buttonStyle(.borderedProminent)
			.keyboardShortcut(.return, modifiers: [])
		}
		.padding(24)
		.frame(width: 400, height: 340)
	}
}

/// The controller that manages the startup guide window
class StartupGuideWindowController: NSObject {
	private var window: NSWindow?
	private var onComplete: (() -> Void)?

	/// Show the guide window
	func show(onComplete: @escaping () -> Void) {
		self.onComplete = onComplete

		let contentView = StartupGuideView(onContinue: { [weak self] in
			self?.close()
		})

		let hostingController = NSHostingController(rootView: contentView)

		window = NSWindow(contentViewController: hostingController)
		window?.title = "Axis"
		window?.styleMask = [.titled, .closable]
		window?.level = .floating
		window?.center()
		window?.isReleasedWhenClosed = false

		// Show and activate the window
		window?.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
	}

	/// Close the window and continue
	private func close() {
		window?.close()
		window = nil
		onComplete?()
		onComplete = nil
	}
}

#Preview {
	StartupGuideView(onContinue: {})
}
