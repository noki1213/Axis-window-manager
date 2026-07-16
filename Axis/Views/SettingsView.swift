




//
//  SettingsView.swift
//  Axis
//
//  Created on 2026/01/27.
//

import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject private var tilingEngine = TilingEngine.shared
    @ObservedObject private var accessibilityManager = AccessibilityManager.shared
    
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
    @State private var floatingApps: [String] = [
        "com.apple.systempreferences"
    ]
    
    var body: some View {
        VStack(alignment: .leading) {
            Text("These apps will always float (not tiled)")
                .foregroundColor(.secondary)
                .padding(.bottom, 8)
            
            List {
                ForEach(floatingApps, id: \.self) { bundleId in
                    HStack {
                        Text(bundleId)
                        Spacer()
                        Button(action: {
                            floatingApps.removeAll { $0 == bundleId }
                        }) {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 150)
            
            HStack {
                Button("Add App...") {
                    // App picker dialog (to be implemented later)
                }
                Spacer()
            }
        }
        .padding()
    }
}

// MARK: - About

struct AboutView: View {
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
            
            Text("Version 0.1.0")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Link("GitHub", destination: URL(string: "https://github.com")!)
                .font(.caption)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    SettingsView()
}
