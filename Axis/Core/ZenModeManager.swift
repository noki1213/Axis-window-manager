//
//  ZenModeManager.swift
//  Axis
//
//  Created on 2026/01/29.
//

import AppKit

/// Zen Mode: the focused window centred on its monitor, the other windows of that workspace out
/// of sight. The session lives in the tracking state, whose plans centre the window, park the
/// others and put everything back when it ends (by the key, or on its own when its window closes,
/// the workspace switches, the palette opens, ...); this class turns the keys into commands and
/// moves the border along.
class ZenModeManager {
    static let shared = ZenModeManager()

    private var coordinator: TrackingCoordinator { TrackingCoordinator.shared }

    /// Whether Zen mode is on (it runs on one monitor at a time)
    var isActive: Bool {
        coordinator.state.zen != nil
    }

    private init() {}

    func toggle() {
        if isActive {
            exit()
        } else {
            enter()
        }
    }

    /// Centre the focused window; the other windows of its workspace leave the screen
    private func enter() {
        guard let focusedWindow = AccessibilityManager.shared.getFocusedWindow() else { return }
        let id = focusedWindow.id
        guard coordinator.state.visibility(id) == .visible else {
            let state = coordinator.state.visibility(id)?.logName ?? "not tracked"
            PerfLog.event("zen: not entered (\(PerfLog.describe(focusedWindow)) is \(state))")
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        coordinator.perform("zen") { state in
            state.zenEnter(id, now: now)
        }
        guard coordinator.state.zen?.focus == id else { return }

        focusedWindow.focus()

        // The border slides out to the centred frame, then follows the window once it settled
        if let target = coordinator.state.expectedFrame(id) {
            BorderManager.shared.updateBorder(withExplicitTarget: target)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            BorderManager.shared.updateBorder()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            BorderManager.shared.updateBorder()
        }
    }

    func exit(reason: ZenExitReason = .user) {
        guard isActive else { return }
        coordinator.perform("zen") { state in
            state.zenExit(reason: reason)
        }
    }

    /// Zen mode ended, by the key or on its own: the border follows the windows coming back
    func noteEnded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            BorderManager.shared.updateBorder()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            BorderManager.shared.updateBorder()
        }
    }

    /// Adjusts the window width in 5% steps while in Zen mode
    func adjustWidth(increase: Bool) {
        guard let focus = coordinator.state.zen?.focus else { return }
        coordinator.perform("zen width") { state in
            state.zenAdjustWidth(increase: increase)
        }
        if let target = coordinator.state.expectedFrame(focus) {
            BorderManager.shared.updateBorder(withExplicitTarget: target)
        }
    }
}
