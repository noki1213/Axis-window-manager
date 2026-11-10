//
//  AxisApp.swift
//  Axis
//
//  Created by noki1213 on 2026/01/27.
//

import SwiftUI

@main
struct AxisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // A menu bar app has no window of its own; the settings are a popup (SettingsView)
        Settings {
            EmptyView()
        }
    }
}
