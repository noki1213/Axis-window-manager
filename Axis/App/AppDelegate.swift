

//
//  AppDelegate.swift
//  Axis
//
//  Created on 2026/01/27.
//

import AppKit
import SwiftUI
import Combine

/// Manages the application's lifecycle
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    
    private let accessibilityManager = AccessibilityManager.shared
    private let hotkeyManager = HotkeyManager.shared
    private let tilingEngine = TilingEngine.shared
    private let borderManager = BorderManager.shared
    private let workspaceManager = WorkspaceManager.shared
    
    /// Follows focus into other workspaces and hands it on when the focused window closes
    private let focusFollower = FocusFollower()

    // The popups shown at launch
    private let startupGuide = GlassDialog()
    private let accessibilityDialog = GlassDialog()

    // The panel the menu bar icon opens
    private lazy var menuPanel = MenuPanelController(actions: MenuPanelActions(
        openFileProblems: { [weak self] in self?.runFromPanel { $0.openFileProblems() } },
        tileWindows: { [weak self] in self?.runFromPanel { $0.tileWindows() } },
        openSettings: { [weak self] in self?.runFromPanel { $0.openSettings() } },
        quit: { [weak self] in self?.runFromPanel { $0.quitApp() } }
    ))

    // Problems with the settings files: a row in the panel while they last, and the panel opened once for each new set of them
    private var hotkeyProblemsObserver: AnyCancellable?
    private var shownFileProblems: [String] = []
    /// Counts the panel's openings, so the timer that closes a problems notice leaves a later opening alone
    private var panelOpenings = 0

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Registered before launch finishes, so a URL that launched Axis is not missed
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    /// axis://launch-aside?path=/Applications/Some.app
    ///     launch the app with its windows on an empty workspace, out of sight
    /// axis://focus-back
    ///     jump back to the previously focused window
    /// axis://settings
    ///     open the settings popup
    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let components = URLComponents(string: string)
        else { return }
        let path = components.queryItems?.first(where: { $0.name == "path" })?.value

        switch components.host {
        case "launch-aside":
            guard let path, !path.isEmpty else { return }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            LaunchAsideManager.shared.launch(appAt: url, on: workspaceManager.focusedScreen())
        case "focus-back":
            FocusHistoryManager.shared.jumpBack()
        case "settings":
            openSettings()
        default:
            break
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Configure it as a menu bar app (hide the Dock icon)
        NSApp.setActivationPolicy(.accessory)
        
        // Create the status bar item
        setupStatusItem()

        hotkeyProblemsObserver = HotkeyStore.shared.$problems
            .combineLatest(SettingsStore.shared.$problems)
            .sink { [weak self] hotkeyProblems, settingsProblems in
                // Published before the value changes, so handled on the next turn of the run loop
                DispatchQueue.main.async { self?.showFileProblems(settingsProblems + hotkeyProblems) }
            }
        
        // Check the Accessibility permission
        if !accessibilityManager.checkAccessibility() {
            showAccessibilityAlert()
        } else {
            showStartupGuide()
        }
        
        // Watch for the permission-granted notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onAccessibilityPermissionGranted),
            name: .accessibilityPermissionGranted,
            object: nil
        )
        
        // Watch for mode-change notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onModeChanged),
            name: .modeChanged,
            object: nil
        )

        // Watch for workspace-change notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onWorkspaceChanged),
            name: .workspaceChanged,
            object: nil
        )
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Save the layout, then bring every window Axis moved out of sight back on screen
        workspaceManager.prepareForQuit()
        hotkeyManager.stop()
    }
    
    // MARK: - Status Bar
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            updateStatusItemIcon(mode: .normal)
            button.action = #selector(statusItemClicked)
            button.target = self
        }
        
        menuPanel.onVisibilityChanged = { [weak self] visible in
            self?.statusItem?.button?.highlight(visible)
        }
    }
    
    private func updateStatusItemIcon(mode: HotkeyManager.Mode) {
        guard let button = statusItem?.button else { return }
        
        let iconName: String
        switch mode {
        case .normal:
            iconName = "rectangle.split.3x1" // Normal tiling icon
        case .gapSelect:
            iconName = "arrow.left.and.right" // Gap selection
        case .windowPalette:
            iconName = "rectangle.grid.2x2" // Window palette
        }
        
        button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: mode.rawValue)
    }
    
    // MARK: - Settings file problems

    /// Point at a new set of problems by opening the panel, where they are listed under their row
    private func showFileProblems(_ problems: [String]) {
        if problems.isEmpty {
            shownFileProblems = []
            return
        }
        guard problems != shownFileProblems else { return }
        shownFileProblems = problems
        guard !menuPanel.isVisible, let anchor = statusItemFrame() else { return }

        // Not made key: the problems usually come from editing the file, and that typing carries on
        menuPanel.show(below: anchor, takesKey: false)
        panelOpenings += 1
        let opening = panelOpenings

        // Gets out of the way on its own; the panel's row and the Shortcuts tab keep the details
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.panelOpenings == opening else { return }
            self.menuPanel.hide()
        }
    }

    /// Open Settings, where the problems are listed at the top
    private func openFileProblems() {
        SettingsNavigation.shared.tab = HotkeyStore.shared.problems.isEmpty ? .general : .shortcuts
        openSettings()
    }

    // MARK: - Actions
    
    @objc private func statusItemClicked() {
        if menuPanel.isVisible {
            menuPanel.hide()
        } else if let anchor = statusItemFrame() {
            menuPanel.show(below: anchor)
            panelOpenings += 1
        }
    }

    /// The status item's rect in screen coordinates
    private func statusItemFrame() -> NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// Close the panel first, so the command's own windows and focus changes aren't covered by it
    private func runFromPanel(_ command: (AppDelegate) -> Void) {
        menuPanel.hide()
        command(self)
    }
    
    private func tileWindows() {
        tilingEngine.tileAllScreens()
    }
    
    private func openSettings() {
        SettingsPanelController.shared.show()
    }
    
    private func quitApp() {
        // Runs the window-restore logic from applicationWillTerminate
        NSApp.terminate(nil)
    }

    // MARK: - Accessibility
    
    private func showAccessibilityAlert() {
        accessibilityDialog.show(
            title: "Accessibility Permission Required",
            message: "Axis needs Accessibility permission to manage windows. Open System Settings to grant it.",
            cancelTitle: "Quit",
            confirmTitle: "Open System Settings",
            onConfirm: { [weak self] in self?.accessibilityManager.requestAccessibility() },
            onCancel: { NSApp.terminate(nil) }
        )
    }
    
    @objc private func onAccessibilityPermissionGranted() {
        DispatchQueue.main.async { [weak self] in
            self?.showStartupGuide()
        }
    }

    /// Show the startup guide, and begin window management once the user signals they're ready
    private func showStartupGuide() {
        startupGuide.show(
            title: "Before You Start Axis",
            message: "Axis cannot manage windows across multiple macOS virtual desktops. Move all windows to a single desktop before continuing.",
            confirmTitle: "Ready",
            onConfirm: { [weak self] in self?.startWindowManagement() }
        )
    }

    private func startWindowManagement() {

        // Start hotkey monitoring
        hotkeyManager.start()

        // Start watching for Focus Follows Mouse (auto-focus the window under the cursor)
        FocusFollowsMouseManager.shared.start()
        // A startup marker to confirm the measurement logging is running
        PerfLog.log("=== Axis launched / FFM enabled=\(FocusFollowsMouseManager.shared.isEnabled) ===")

        // Periodic system load line, so misbehavior can be checked against CPU pressure at that moment
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            PerfLog.event("load: \(PerfLog.loadAverage())")
        }

        // Track the windows of every app: the saved workspaces and columns come back for the windows
        // that still exist, the others join the shown workspace of their monitor, and focus goes to
        // the first window once they are laid out
        focusFollower.start()
        workspaceManager.start { [weak self] in
            self?.focusFirstWindow()
        }
    }

    /// Focus the first tile, preferring the main screen
    private func focusFirstWindow() {
        let screens = [NSScreen.main].compactMap { $0 } + NSScreen.screens.filter { $0 != NSScreen.main }
        for screen in screens {
            if let firstWindow = tilingEngine.tiledColumns(on: screen).compactMap({ $0.first }).first {
                firstWindow.focus()
                borderManager.updateBorderExpecting(windowID: firstWindow.id)
                return
            }
        }
        borderManager.updateBorder()
    }

    @objc private func onModeChanged(_ notification: Notification) {
        if let mode = notification.object as? HotkeyManager.Mode {
            DispatchQueue.main.async { [weak self] in
                self?.updateStatusItemIcon(mode: mode)
            }
        }
    }

    @objc private func onWorkspaceChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.updateWorkspaceDisplay()
        }
    }

    /// Show the workspace number in the menu bar
    private func updateWorkspaceDisplay() {
        guard let button = statusItem?.button else { return }
        let ws = workspaceManager.currentWorkspaceForFocusedScreen()
        button.title = " \(ws)"
    }
}
