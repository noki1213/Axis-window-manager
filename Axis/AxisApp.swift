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
        // Since it's a menu bar app, the WindowGroup is for the settings screen
        Settings {
            SettingsView()
        }
    }
}
