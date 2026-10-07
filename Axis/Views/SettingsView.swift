




//
//  SettingsView.swift
//  Axis
//
//  Created on 2026/01/27.
//

import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
            
            LayoutSettingsView()
                .tabItem {
                    Label("Layout", systemImage: "rectangle.split.3x1")
                }

            ShortcutsSettingsView()
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }

            FloatingAppsView()
                .tabItem {
                    Label("Floating", systemImage: "square.on.square")
                }
            
            AboutView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 500, height: 500)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @ObservedObject private var accessibilityManager = AccessibilityManager.shared
    @ObservedObject private var ffm = FocusFollowsMouseManager.shared
    @ObservedObject private var focusHistory = FocusHistoryManager.shared
    @State private var launchAtLogin = false

    var body: some View {
        VStack(spacing: 16) {
            GroupBox {
                HStack {
                    Text("Accessibility Permission")
                    Spacer()
                    if accessibilityManager.isAccessibilityEnabled {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Granted")
                            .foregroundColor(.secondary)
                    } else {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                        Button("Grant Permission") {
                            accessibilityManager.requestAccessibility()
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox {
                HStack {
                    Toggle("Launch at Login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, newValue in
                            updateLaunchAtLogin(newValue)
                        }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Focus follows mouse", isOn: $ffm.isEnabled)
                    Text("Automatically focus and raise the window under the mouse pointer.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if ffm.isEnabled {
                        HStack {
                            Text("Delay: \(Int(ffm.delayMs)) ms")
                            Slider(value: $ffm.delayMs, in: 0...500, step: 10)
                        }
                    }
                }
                .padding(8)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Focus Previous Window: remember after \(Int(focusHistory.settleSeconds)) s")
                        Slider(value: $focusHistory.settleSeconds, in: 1...30, step: 1)
                    }
                    Text("Windows you only pass through while moving focus are skipped. Windows you jump from or to are always remembered.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(8)
            }

            Spacer()
        }
        .padding()
        .onAppear {
            // Fetch the current registration state and reflect it in the toggle
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

// MARK: - Layout Settings

struct LayoutSettingsView: View {
    @ObservedObject private var tilingEngine = TilingEngine.shared

    var body: some View {
        VStack(spacing: 16) {
            GroupBox("Spacing") {
                VStack(spacing: 8) {
                    HStack {
                        Text("Window Gap")
                        Spacer()
                        TextField("", value: $tilingEngine.windowGap, formatter: NumberFormatter())
                            .frame(width: 60)
                            .textFieldStyle(.roundedBorder)
                        Text("px")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Screen Padding")
                        Spacer()
                        TextField("", value: $tilingEngine.screenPadding, formatter: NumberFormatter())
                            .frame(width: 60)
                            .textFieldStyle(.roundedBorder)
                        Text("px")
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 4)
            }

            Button("Re-tile All Windows") {
                tilingEngine.tileAllScreens()
            }

            Spacer()
        }
        .padding()
    }
}

// MARK: - Floating Apps

struct FloatingAppsView: View {
    @ObservedObject private var store = FloatingAppsStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Windows of these apps are never tiled. Like System Settings, they float above the tiles and stay on screen when you switch workspaces.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(store.apps) { app in
                    FloatingAppRow(app: app) {
                        withAnimation(listAnimation) {
                            store.remove(bundleID: app.bundleID)
                        }
                    }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .overlay {
                if store.apps.isEmpty {
                    Text("No apps")
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Button("Add App…") {
                    chooseApps()
                }
                Spacer()
            }
        }
        .padding()
    }

    /// Rows come and go with a spring that does not bounce, or a short fade with Reduce Motion
    private var listAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.3, bounce: 0)
    }

    /// Picks apps to add, starting in /Applications, as a sheet on the settings window
    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose apps whose windows always float."
        panel.prompt = "Add"
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            withAnimation(listAnimation) {
                store.add(appsAt: panel.urls)
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}

/// One app on the floating list: its icon and name, and a button that takes it off the list
private struct FloatingAppRow: View {
    let app: FloatingApp
    let onRemove: () -> Void
    @State private var isHoveringRemove = false

    /// The red of the color scheme
    private static let removeHoverColor = Color(red: 0xfc / 255, green: 0x9c / 255, blue: 0x9c / 255)

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
            .buttonStyle(.borderless)
            .foregroundColor(isHoveringRemove ? Self.removeHoverColor : .secondary)
            .onHover { isHoveringRemove = $0 }
            .help("Remove")
        }
        .padding(.vertical, 2)
    }
}

// MARK: - About

struct AboutView: View {
    /// The version in the app's Info.plist
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)
            
            Text("Axis")
                .font(.largeTitle)
                .bold()
            
            Text("Window Manager for macOS")
                .foregroundColor(.secondary)
            
            Text("Version \(version)")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            Link("GitHub", destination: URL(string: "https://github.com/noki1213/Axis-window-manager")!)
                .font(.caption)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    SettingsView()
}
