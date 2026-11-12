//
//  SettingsView.swift
//  Axis
//
//  The settings popup: a list of sections on the left, the chosen section on the right. Every change
//  is saved to settings.json (shortcuts to hotkeys.json) and takes effect at once.
//

import SwiftUI
import ServiceManagement
import Combine

/// The section on show, so other parts of the app can open the popup at a given section
final class SettingsNavigation: ObservableObject {
	static let shared = SettingsNavigation()

	enum Tab: String, CaseIterable, Hashable {
		case general = "General"
		case layout = "Layout"
		case shortcuts = "Shortcuts"
		case floating = "Floating"
		case about = "About"

		var symbol: String {
			switch self {
			case .general: return "gearshape"
			case .layout: return "rectangle.split.3x1"
			case .shortcuts: return "keyboard"
			case .floating: return "square.on.square"
			case .about: return "info.circle"
			}
		}
	}

	@Published var tab: Tab = .general
}

/// Opens and closes the settings popup.
final class SettingsPanelController {
	static let shared = SettingsPanelController()

	private lazy var popup = GlassPopupController(size: CGSize(width: 720, height: 520), closesOnDeactivate: true) { _ in
		SettingsView()
	}

	func show() { popup.show() }
	func hide() { popup.hide() }
}

struct SettingsView: View {
	@ObservedObject private var navigation = SettingsNavigation.shared
	@ObservedObject private var hotkeys = HotkeyStore.shared
	@ObservedObject private var settings = SettingsStore.shared
	@Namespace private var tabNamespace
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	var body: some View {
		HStack(spacing: 0) {
			VStack(alignment: .leading, spacing: 2) {
				ForEach(SettingsNavigation.Tab.allCases, id: \.self) { tab in
					sidebarRow(tab)
				}
				Spacer()
			}
			.padding(12)
			.frame(width: 180)

			Rectangle()
				.fill(Palette.line)
				.frame(width: 1)

			VStack(spacing: 0) {
				let problems = settings.problems + hotkeys.problems
				if !problems.isEmpty {
					ProblemsBanner(problems: problems)
				}
				content
					.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
			}
		}
	}

	/// One section; a single pill glides to the chosen one.
	private func sidebarRow(_ tab: SettingsNavigation.Tab) -> some View {
		let selected = navigation.tab == tab
		return HStack(spacing: 8) {
			Image(systemName: tab.symbol)
				.frame(width: 18)
			Text(tab.rawValue)
			Spacer()
		}
		.foregroundColor(selected ? Palette.text : Palette.secondaryText)
		.padding(.horizontal, 10)
		.frame(height: 30)
		.background {
			if selected {
				RoundedRectangle(cornerRadius: 9, style: .continuous)
					.fill(Palette.selection)
					.matchedGeometryEffect(id: "tabPill", in: tabNamespace)
			}
		}
		.contentShape(Rectangle())
		.onTapGesture {
			withAnimation(reduceMotion ? .easeOut(duration: 0.1) : .timingCurve(0.65, 0, 0.35, 1, duration: 0.4)) {
				navigation.tab = tab
			}
		}
	}

	@ViewBuilder private var content: some View {
		switch navigation.tab {
		case .general: GeneralSettingsView()
		case .layout: LayoutSettingsView()
		case .shortcuts: ShortcutsSettingsView()
		case .floating: FloatingAppsView()
		case .about: AboutView()
		}
	}
}

/// What is wrong with the settings files, above the section.
private struct ProblemsBanner: View {
	let problems: [String]

	var body: some View {
		HStack(alignment: .top, spacing: 8) {
			Image(systemName: "exclamationmark.triangle.fill")
				.foregroundColor(Palette.yellow)
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
		.background(Palette.pureWhite.opacity(0.06))
	}
}

/// A titled block of settings.
struct SettingsGroup<Content: View>: View {
	let title: String?
	@ViewBuilder let content: Content

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			if let title {
				Text(title)
					.font(.headline)
					.foregroundColor(Palette.text)
			}
			content
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

// MARK: - General

struct GeneralSettingsView: View {
	@ObservedObject private var accessibilityManager = AccessibilityManager.shared
	@ObservedObject private var ffm = FocusFollowsMouseManager.shared
	@ObservedObject private var focusHistory = FocusHistoryManager.shared
	@State private var launchAtLogin = false

	var body: some View {
		VStack(alignment: .leading, spacing: 24) {
			SettingsGroup(title: nil) {
				HStack {
					Text("Accessibility Permission")
					Spacer()
					if accessibilityManager.isAccessibilityEnabled {
						Text("Granted")
							.foregroundColor(Palette.accent)
					} else {
						OutlineButton(title: "Grant Permission", isPrimary: true) {
							accessibilityManager.requestAccessibility()
						}
					}
				}
				Toggle("Launch at Login", isOn: $launchAtLogin)
					.onChange(of: launchAtLogin) { _, newValue in
						updateLaunchAtLogin(newValue)
					}
			}

			SettingsGroup(title: "Focus follows mouse") {
				Toggle("Focus the window under the mouse pointer", isOn: $ffm.isEnabled)
				if ffm.isEnabled {
					HStack {
						Text("Delay: \(Int(ffm.delayMs)) ms")
							.frame(width: 110, alignment: .leading)
						Slider(value: $ffm.delayMs, in: 0...500, step: 10)
					}
				}
			}

			SettingsGroup(title: "Focus Previous Window") {
				HStack {
					Text("Remember after \(Int(focusHistory.settleSeconds)) s")
						.frame(width: 130, alignment: .leading)
					Slider(value: $focusHistory.settleSeconds, in: 1...30, step: 1)
				}
				Text("Windows you only pass through while moving focus are skipped. Windows you jump from or to are always remembered.")
					.font(.caption)
					.foregroundColor(Palette.secondaryText)
					.fixedSize(horizontal: false, vertical: true)
			}

			Spacer()
		}
		.padding(20)
		.tint(Palette.accent)
		.onAppear {
			launchAtLogin = (SMAppService.mainApp.status == .enabled)
		}
	}

	/// Register or unregister launch-at-login
	private func updateLaunchAtLogin(_ enabled: Bool) {
		do {
			if enabled {
				try SMAppService.mainApp.register()
			} else {
				try SMAppService.mainApp.unregister()
			}
		} catch {
			// Revert the toggle to its original state on failure
			launchAtLogin = !enabled
		}
	}
}

// MARK: - Layout

struct LayoutSettingsView: View {
	@ObservedObject private var tilingEngine = TilingEngine.shared

	var body: some View {
		VStack(alignment: .leading, spacing: 24) {
			SettingsGroup(title: "Spacing") {
				HStack {
					Text("Window Gap: \(Int(tilingEngine.windowGap)) px")
						.frame(width: 150, alignment: .leading)
					Slider(value: gapBinding(\.windowGap), in: 0...100, step: 1)
				}
				HStack {
					Text("Screen Padding: \(Int(tilingEngine.screenPadding)) px")
						.frame(width: 150, alignment: .leading)
					Slider(value: gapBinding(\.screenPadding), in: 0...100, step: 1)
				}
			}

			OutlineButton(title: "Re-tile All Windows") {
				tilingEngine.tileAllScreens()
			}

			Spacer()
		}
		.padding(20)
		.tint(Palette.accent)
	}

	private func gapBinding(_ keyPath: ReferenceWritableKeyPath<TilingEngine, CGFloat>) -> Binding<Double> {
		Binding(get: { Double(tilingEngine[keyPath: keyPath]) },
				set: { tilingEngine[keyPath: keyPath] = CGFloat($0) })
	}
}

// MARK: - Floating apps

struct FloatingAppsView: View {
	@ObservedObject private var store = FloatingAppsStore.shared
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var isPicking = false

	var body: some View {
		if isPicking {
			AppPickerView(isPicking: $isPicking)
		} else {
			list
		}
	}

	private var list: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Windows of these apps are never tiled. Like System Settings, they float above the tiles and stay on screen when you switch workspaces.")
				.font(.caption)
				.foregroundColor(Palette.secondaryText)
				.fixedSize(horizontal: false, vertical: true)

			ScrollView {
				VStack(spacing: 0) {
					ForEach(store.apps) { app in
						FloatingAppRow(app: app) {
							withAnimation(listAnimation) {
								store.remove(bundleID: app.bundleID)
							}
						}
					}
				}
			}
			.overlay {
				if store.apps.isEmpty {
					Text("No apps")
						.foregroundColor(Palette.secondaryText)
				}
			}

			HStack {
				OutlineButton(title: "Add App…", isPrimary: true) {
					isPicking = true
				}
				Spacer()
			}
		}
		.padding(20)
	}

	/// Rows come and go with a spring that does not bounce, or a short fade with Reduce Motion
	private var listAnimation: Animation {
		reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.3, bounce: 0)
	}
}

/// One app on the floating list: its icon and name, and a button that takes it off the list
private struct FloatingAppRow: View {
	let app: FloatingApp
	let onRemove: () -> Void
	@State private var isHoveringRemove = false

	/// The red of the color scheme
	private static let removeHoverColor = Palette.red

	var body: some View {
		HStack(spacing: 10) {
			Image(nsImage: app.icon)
				.resizable()
				.frame(width: 24, height: 24)
			Text(app.name)
			Spacer()
			Button(action: onRemove) {
				Image(systemName: "minus.circle")
			}
			.buttonStyle(.plain)
			.foregroundColor(isHoveringRemove ? Self.removeHoverColor : Palette.secondaryText)
			.onHover { isHoveringRemove = $0 }
			.help("Remove")
		}
		.padding(.vertical, 5)
	}
}

/// The installed apps, to pick the ones to add. Choosing a row adds it at once.
private struct AppPickerView: View {
	@Binding var isPicking: Bool
	@ObservedObject private var store = FloatingAppsStore.shared
	@State private var installed: [InstalledApp] = []
	@State private var query = ""
	@State private var hovered: String?

	struct InstalledApp: Identifiable {
		let bundleID: String
		let name: String
		let url: URL
		var id: String { bundleID }
	}

	private var matches: [InstalledApp] {
		let added = store.bundleIDs
		return installed.filter { app in
			!added.contains(app.bundleID)
				&& (query.isEmpty || app.name.localizedCaseInsensitiveContains(query))
		}
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack {
				Text("Choose apps whose windows always float.")
					.font(.caption)
					.foregroundColor(Palette.secondaryText)
				Spacer()
				OutlineButton(title: "Done", isPrimary: true) { isPicking = false }
			}

			TextField("Search", text: $query)
				.textFieldStyle(.plain)
				.padding(.horizontal, 10)
				.frame(height: 28)
				.background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.pureWhite.opacity(0.08)))

			ScrollView {
				LazyVStack(spacing: 0) {
					ForEach(matches) { app in
						HStack(spacing: 10) {
							Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
								.resizable()
								.frame(width: 24, height: 24)
							Text(app.name)
								.foregroundColor(Palette.text)
							Spacer()
						}
						.padding(.horizontal, 8)
						.frame(height: 34)
						.background(RoundedRectangle(cornerRadius: 9, style: .continuous)
							.fill(hovered == app.id ? Palette.selection : .clear))
						.contentShape(Rectangle())
						.onHover { inside in
							if inside { hovered = app.id } else if hovered == app.id { hovered = nil }
						}
						.onTapGesture { store.add(appsAt: [app.url]) }
					}
				}
			}
		}
		.padding(20)
		.onAppear { installed = Self.scanInstalledApps() }
	}

	/// The apps directly inside the Applications folders
	private static func scanInstalledApps() -> [InstalledApp] {
		let folders = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
		var found: [String: InstalledApp] = [:]
		for folder in folders {
			let urls = (try? FileManager.default.contentsOfDirectory(
				at: URL(fileURLWithPath: folder, isDirectory: true),
				includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
			for url in urls where url.pathExtension == "app" {
				guard let bundleID = Bundle(url: url)?.bundleIdentifier,
					  bundleID != Bundle.main.bundleIdentifier else { continue }
				found[bundleID] = InstalledApp(bundleID: bundleID, name: url.deletingPathExtension().lastPathComponent, url: url)
			}
		}
		return found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
	}
}

// MARK: - About

struct AboutView: View {
	/// The version in the app's Info.plist
	private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

	var body: some View {
		VStack(spacing: 12) {
			Image(systemName: "rectangle.split.3x1")
				.font(.system(size: 56))
				.foregroundColor(Palette.accent)

			Text("Axis")
				.font(.largeTitle)
				.bold()
				.foregroundColor(Palette.text)

			Text("Window Manager for macOS")
				.foregroundColor(Palette.secondaryText)

			Text("Version \(version)")
				.font(.caption)
				.foregroundColor(Palette.secondaryText)

			Link("GitHub", destination: URL(string: "https://github.com/noki1213/Axis-window-manager")!)
				.font(.caption)
				.tint(Palette.accent)
		}
		.padding(20)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}
