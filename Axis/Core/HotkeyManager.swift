//
//  HotkeyManager.swift
//  Axis
//
//  Created on 2026/01/27.
//

import AppKit
import Carbon
import Combine

/// Handles global hotkey management
class HotkeyManager: ObservableObject {
	static let shared = HotkeyManager()

	// MARK: - Mode

	enum Mode: String {
		case normal = "Normal"
		case gapSelect = "Gap Select"
		case windowPalette = "Window Palette"
	}

	@Published var currentMode: Mode = .normal

	/// Whether a placement reservation (Ctrl+Opt+N) is being waited on. Since this is a transient state that only looks at the next single key to confirm/cancel,
	/// Kept as an independent flag rather than part of Mode (folding it into Mode would drag it into Escape's generic handling)
	private var isAwaitingPlacementReservationKey: Bool = false

	// MARK: - Lookup table (supports customization)

	/// A lookup table from (keyCode, modifiers) to HotkeyAction
	private var lookupTable: [HotkeyLookupKey: HotkeyAction] = [:]

	/// Flag for whether a key is being recorded (when true, the EventTap passes events through)
	var isRecordingHotkey: Bool = false

	// MARK: - Event Tap (low-level event monitoring)

	private var eventTap: CFMachPort?
	private var runLoopSource: CFRunLoopSource?

	// For periodic health checks
	private var heartbeatTimer: Timer?

	private let tilingEngine = TilingEngine.shared
	private let gapSelectManager = GapSelectManager.shared
	private let windowPaletteManager = WindowPaletteManager.shared

	private init() {
		// When the reservation expires from a timeout, also reset the waiting flag here
		PlacementReservationManager.shared.onAwaitingCanceled = { [weak self] in
			self?.isAwaitingPlacementReservationKey = false
		}
	}

	// MARK: - Public Methods

	/// Start hotkey monitoring
	func start() {
		reloadBindings()
		setupEventTap()
		startHeartbeat()
	}

	/// Stop hotkey monitoring
	func stop() {
		heartbeatTimer?.invalidate()
		heartbeatTimer = nil
		destroyEventTap()
	}

	/// Force a restart (for calling from the menu, etc.)
	func restart() {
		stop()
		start()
	}

	/// Rebuild the lookup table from HotkeyStore
	func reloadBindings() {
		lookupTable = HotkeyStore.shared.buildLookupTable()
	}

	// MARK: - Event Tap Setup

	private func setupEventTap() {
		// Do nothing if it already exists
		if eventTap != nil { return }

		// The event tap's callback
		let callback: CGEventTapCallBack = { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
			guard let refcon = refcon else {
				return Unmanaged.passUnretained(event)
			}

			let hotkeyManager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()

			// Try to re-enable the tap if it got disabled
			if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {

				// Re-enable it immediately
				if let tap = hotkeyManager.eventTap {
					CGEvent.tapEnable(tap: tap, enable: true)
				}
				return Unmanaged.passUnretained(event)
			}

			// Pass events through while recording a key (typing a key in the settings screen)
			if hotkeyManager.isRecordingHotkey {
				return Unmanaged.passUnretained(event)
			}

			// Modifier key change (for the adjacent-space peek). Never consume it, just pass it through
			if type == .flagsChanged {
				hotkeyManager.handleFlagsChanged(event)
				return Unmanaged.passUnretained(event)
			}

			// Only handle key-down events
			guard type == .keyDown else {
				return Unmanaged.passUnretained(event)
			}

			// Filtering while in normal mode:
			// Ignore it unless it includes one of the modifier keys registered in the lookup table
			// However, while waiting on a placement reservation, let every key through so the next single key can be evaluated
			if hotkeyManager.currentMode == .normal && !hotkeyManager.isAwaitingPlacementReservationKey {
				let flags = event.flags
				let eventModifiers = HotkeyModifiers.from(flags)
				// Check whether a modifier key matching a lookup table key is present
				let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
				let lookupKey = HotkeyLookupKey(keyCode: keyCode, modifiers: eventModifiers)
				if hotkeyManager.lookupTable[lookupKey] == nil {
					return Unmanaged.passUnretained(event)
				}
			}

			// Convert to NSEvent for a detailed check
			guard let nsEvent = NSEvent(cgEvent: event) else {
				return Unmanaged.passUnretained(event)
			}

			// Handle the event and return nil if it should be consumed
			if hotkeyManager.handleKeyEvent(nsEvent) {
				return nil // イベントを消費
			}

			return Unmanaged.passRetained(event)
		}

		// Create the event tap
		let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

		guard let tap = CGEvent.tapCreate(
			tap: .cgSessionEventTap,
			place: .headInsertEventTap,
			options: .defaultTap,
			eventsOfInterest: CGEventMask(eventMask),
			callback: callback,
			userInfo: Unmanaged.passUnretained(self).toOpaque()
		) else {
			return
		}

		eventTap = tap
		runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

		if let source = runLoopSource {
			CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
			CGEvent.tapEnable(tap: tap, enable: true)
		}
	}

	private func destroyEventTap() {
		if let eventTap = eventTap {
			CGEvent.tapEnable(tap: eventTap, enable: false)
		}
		if let runLoopSource = runLoopSource {
			CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
		}
		eventTap = nil
		runLoopSource = nil
	}

	// MARK: - Heartbeat (Self-Healing)

	/// Periodically check whether the Event Tap is alive, and revive it if it's dead
	private func startHeartbeat() {
		heartbeatTimer?.invalidate()
		heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
			self?.checkEventTapHealth()
		}
	}

	private func checkEventTapHealth() {
		guard let tap = eventTap else {
			// Recreate it if nil
			setupEventTap()
			return
		}

		// Check whether the tap is enabled
		if !CGEvent.tapIsEnabled(tap: tap) {
			CGEvent.tapEnable(tap: tap, enable: true)

			// Recreate it if that still doesn't work
			if !CGEvent.tapIsEnabled(tap: tap) {
				stop()
				start()
			}
		}
	}

	// MARK: - Modifier Event Handling (for the adjacent-space peek)

	/// Handle a flagsChanged event. Whether exactly Ctrl+Option is held
	/// Notify WorkspacePeekManager. Since this is called directly from the CGEventTap callback,
	/// This method itself never consumes the event (the caller passes it through as-is)
	private func handleFlagsChanged(_ event: CGEvent) {
		let modifiers = HotkeyModifiers.from(event.flags)
		let isExactlyCtrlOption = modifiers == [.control, .option]
		DispatchQueue.main.async {
			WorkspacePeekManager.shared.handleModifiersChanged(isExactlyCtrlOption: isExactlyCtrlOption)
		}
	}

	// MARK: - Key Event Handling

	@discardableResult
	private func handleKeyEvent(_ event: NSEvent) -> Bool {
		// Another key was pressed, i.e. a normal shortcut, so don't show/hide the peek preview
		DispatchQueue.main.async {
			WorkspacePeekManager.shared.cancelDueToKeyPress()
		}

		// While waiting on a placement reservation, only look at the next single key to confirm or cancel.
		// Since Mode wasn't changed (currentMode stays normal), the Escape handling below and
		// Don't fall through to lookup table handling; finish it here
		if isAwaitingPlacementReservationKey {
			return handlePlacementReserveAwaitingKeyEvent(event)
		}

		// Return to normal mode with Escape
		if event.keyCode == kVK_Escape {
			if currentMode == .windowPalette {
				DispatchQueue.main.async { [weak self] in
					self?.windowPaletteManager.endPalette()
					self?.currentMode = .normal
					NotificationCenter.default.post(name: .modeChanged, object: self?.currentMode)
				}
				return true
			} else if currentMode == .gapSelect {
				DispatchQueue.main.async { [weak self] in
					self?.gapSelectManager.endGapSelectMode()
					self?.currentMode = .normal
					NotificationCenter.default.post(name: .modeChanged, object: self?.currentMode)
				}
				return true
			} else if currentMode != .normal {
				DispatchQueue.main.async { [weak self] in
					self?.currentMode = .normal
					NotificationCenter.default.post(name: .modeChanged, object: self?.currentMode)
				}
				return true
			}
			return false
		}

		// Special key handling while in gap selection mode
		if currentMode == .gapSelect {
			return handleGapSelectModeKeyEvent(event)
		}

		// Special key handling while in window palette mode
		if currentMode == .windowPalette {
			return handleWindowPaletteModeKeyEvent(event)
		}

		// Look up the action in the lookup table
		let eventModifiers = HotkeyModifiers.from(event.modifierFlags)
		let lookupKey = HotkeyLookupKey(keyCode: Int(event.keyCode), modifiers: eventModifiers)

		guard let action = lookupTable[lookupKey] else {
			return false
		}

		// Execute the action
		executeAction(action)
		return true
	}

	// MARK: - Action execution

	/// Execute the action found in the lookup table
	private func executeAction(_ action: HotkeyAction) {
		switch action {
		// MARK: Focus movement
		case .focusLeft:
			PerfLog.markKeyPressStart("focusLeft")
			DispatchQueue.main.async { [weak self] in
				PerfLog.reportKeyPressHandlerStart()
				if let targetID = PerfLog.measure("moveFocus", { self?.tilingEngine.moveFocus(direction: .left) }) {
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
						BorderManager.shared.updateBorderExpecting(windowID: targetID)
					}
				}
			}
		case .focusRight:
			PerfLog.markKeyPressStart("focusRight")
			DispatchQueue.main.async { [weak self] in
				PerfLog.reportKeyPressHandlerStart()
				if let targetID = PerfLog.measure("moveFocus", { self?.tilingEngine.moveFocus(direction: .right) }) {
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
						BorderManager.shared.updateBorderExpecting(windowID: targetID)
					}
				}
			}
		case .focusUp:
			PerfLog.markKeyPressStart("focusUp")
			DispatchQueue.main.async { [weak self] in
				PerfLog.reportKeyPressHandlerStart()
				if let targetID = PerfLog.measure("moveFocus", { self?.tilingEngine.moveFocus(direction: .up) }) {
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
						BorderManager.shared.updateBorderExpecting(windowID: targetID)
					}
				}
			}
		case .focusDown:
			PerfLog.markKeyPressStart("focusDown")
			DispatchQueue.main.async { [weak self] in
				PerfLog.reportKeyPressHandlerStart()
				if let targetID = PerfLog.measure("moveFocus", { self?.tilingEngine.moveFocus(direction: .down) }) {
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
						BorderManager.shared.updateBorderExpecting(windowID: targetID)
					}
				}
			}

		// MARK: Window movement
		case .moveWindowLeft:
			DispatchQueue.main.async { [weak self] in
				self?.tilingEngine.moveWindow(direction: .left)
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
					BorderManager.shared.updateBorder()
				}
			}
		case .moveWindowRight:
			DispatchQueue.main.async { [weak self] in
				self?.tilingEngine.moveWindow(direction: .right)
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
					BorderManager.shared.updateBorder()
				}
			}
		case .moveWindowUp:
			DispatchQueue.main.async { [weak self] in
				self?.tilingEngine.moveWindow(direction: .up)
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
					BorderManager.shared.updateBorder()
				}
			}
		case .moveWindowDown:
			DispatchQueue.main.async { [weak self] in
				self?.tilingEngine.moveWindow(direction: .down)
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
					BorderManager.shared.updateBorder()
				}
			}

		// MARK: Merge/split (step move)
		case .stepMoveLeft:
			DispatchQueue.main.async { [weak self] in
				self?.tilingEngine.stepMoveWindow(direction: .left)
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
					BorderManager.shared.updateBorder()
				}
			}
		case .stepMoveRight:
			DispatchQueue.main.async { [weak self] in
				self?.tilingEngine.stepMoveWindow(direction: .right)
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
					BorderManager.shared.updateBorder()
				}
			}

		// MARK: Float (floating)
		case .floatToggle:
			DispatchQueue.main.async { [weak self] in
				guard let focusedWindow = AccessibilityManager.shared.getFocusedWindow() else { return }
				let wasFloating = WorkspaceManager.shared.isFloating(focusedWindow.id)
				WorkspaceManager.shared.toggleFloat(windowID: focusedWindow.id)

				// When turning Float on, move the window to the center of the monitor
				if !wasFloating, let screen = WorkspaceManager.shared.focusedScreen() {
					let visibleFrame = screen.visibleFrame
					let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
					let centerX = visibleFrame.midX - focusedWindow.frame.width / 2
					let centerY = mainScreenHeight - visibleFrame.midY - focusedWindow.frame.height / 2
					focusedWindow.setPosition(CGPoint(x: centerX, y: centerY))
				}

				self?.tilingEngine.tileAllScreens()
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
					BorderManager.shared.updateBorder()
				}
			}

		case .floatFocusCycle:
			DispatchQueue.main.async {
				let floatIDs = WorkspaceManager.shared.floatWindowIDs
				guard !floatIDs.isEmpty else { return }
				let allWindows = AccessibilityManager.shared.getAllWindows()
				let floatWindows = allWindows.filter { floatIDs.contains($0.id) }
					.sorted { $0.frame.midX < $1.frame.midX }
				guard !floatWindows.isEmpty else { return }

				if let focused = AccessibilityManager.shared.getFocusedWindow(),
				   let currentIdx = floatWindows.firstIndex(where: { $0.id == focused.id }) {
					let nextIdx = (currentIdx + 1) % floatWindows.count
					floatWindows[nextIdx].focus()
				} else {
					floatWindows[0].focus()
				}
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
					BorderManager.shared.updateBorder()
				}
			}

		case .raiseFloatingWindows:
			DispatchQueue.main.async {
				// Bring floating windows on every screen to the front (without stealing focus)
				for screen in NSScreen.screens {
					TilingEngine.shared.raiseFloatingWindows(on: screen)
				}
			}

		// MARK: Hide/restore
		case .hideWindow:
			DispatchQueue.main.async {
				HiddenWindowManager.shared.hideFocusedWindow()
			}

		case .unhideLastWindow:
			DispatchQueue.main.async {
				HiddenWindowManager.shared.unhideLast()
			}

		// MARK: Zen mode
		case .zenToggle:
			DispatchQueue.main.async {
				ZenModeManager.shared.toggle()
			}

		// MARK: Mode switching
		case .gapSelectMode:
			DispatchQueue.main.async { [weak self] in
				guard !ZenModeManager.shared.isActive else { return }
				self?.currentMode = .gapSelect
				self?.gapSelectManager.startGapSelectMode()
				NotificationCenter.default.post(name: .modeChanged, object: self?.currentMode)
			}

		case .windowPaletteMode:
			DispatchQueue.main.async { [weak self] in
				var zenFrames: [CGWindowID: CGRect] = [:]
				if ZenModeManager.shared.isActive {
					zenFrames = ZenModeManager.shared.exitAndHandOffHiddenFrames()
				}
				self?.currentMode = .windowPalette
				self?.windowPaletteManager.startPalette(inheritedHiddenFrames: zenFrames)
				NotificationCenter.default.post(name: .modeChanged, object: self?.currentMode)
			}

		// MARK: Layout
		case .resetLayout:
			DispatchQueue.main.async { [weak self] in
				self?.tilingEngine.resetToSingleWindowColumns()
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
					BorderManager.shared.updateBorder()
				}
			}

		case .resizeIncrease:
			DispatchQueue.main.async { [weak self] in
				if ZenModeManager.shared.isActive {
					// Widen the width while in zen mode
					ZenModeManager.shared.adjustWidth(increase: true)
				} else {
					self?.tilingEngine.resizeCurrentWindow(increase: true)
				}
			}

		case .resizeDecrease:
			DispatchQueue.main.async { [weak self] in
				if ZenModeManager.shared.isActive {
					// Narrow the width while in zen mode
					ZenModeManager.shared.adjustWidth(increase: false)
				} else {
					self?.tilingEngine.resizeCurrentWindow(increase: false)
				}
			}

		// MARK: Workspace
		case .workspaceNext:
			DispatchQueue.main.async {
				// If cursorScreen is set (we're on an empty monitor), prefer that
				guard let screen = TilingEngine.shared.cursorScreen ?? WorkspaceManager.shared.focusedScreen() else { return }
				WorkspaceManager.shared.switchToNextWorkspace(on: screen)
			}

		case .workspacePrev:
			DispatchQueue.main.async {
				guard let screen = TilingEngine.shared.cursorScreen ?? WorkspaceManager.shared.focusedScreen() else { return }
				WorkspaceManager.shared.switchToPreviousWorkspace(on: screen)
			}

		case .moveWindowToNextWorkspace:
			DispatchQueue.main.async {
				guard let screen = WorkspaceManager.shared.focusedScreen() else { return }
				WorkspaceManager.shared.moveWindowToNextWorkspace(on: screen)
			}

		case .moveWindowToPrevWorkspace:
			DispatchQueue.main.async {
				guard let screen = WorkspaceManager.shared.focusedScreen() else { return }
				WorkspaceManager.shared.moveWindowToPreviousWorkspace(on: screen)
			}

		// MARK: Placement reservation
		case .placementReserve:
			DispatchQueue.main.async { [weak self] in
				guard let self = self else { return }
				if self.isAwaitingPlacementReservationKey || PlacementReservationManager.shared.hasActiveReservation {
					// If pressed again while waiting or while a placement is already confirmed, cancel it
					self.isAwaitingPlacementReservationKey = false
					PlacementReservationManager.shared.cancel()
				} else {
					self.isAwaitingPlacementReservationKey = true
					PlacementReservationManager.shared.beginAwaiting()
				}
			}
		}
	}

	// MARK: - Gap Select Mode Key Handling

	/// Key handling while in the new gap mode
	/// Each key is responsible for one edge, directly moving that edge of the focused window.
	/// There's no select-then-confirm step; the edge moves the instant the key is pressed.
	private func handleGapSelectModeKeyEvent(_ event: NSEvent) -> Bool {
		// Enter: exit the mode (same as Escape)
		if event.keyCode == kVK_Return {
			DispatchQueue.main.async { [weak self] in
				guard let self = self else { return }
				self.gapSelectManager.endGapSelectMode()
				self.currentMode = .normal
				NotificationCenter.default.post(name: .modeChanged, object: self.currentMode)
			}
			return true
		}

		let hasShift = event.modifierFlags.contains(.shift)

		// Specify the edge directly with JKLI (plain = grow, Shift = shrink)
		switch Int(event.keyCode) {
		case kVK_ANSI_J: // 左辺
			DispatchQueue.main.async { [weak self] in
				self?.gapSelectManager.resizeFocusedEdge(.left, widen: !hasShift)
			}
			return true

		case kVK_ANSI_L: // 右辺
			DispatchQueue.main.async { [weak self] in
				self?.gapSelectManager.resizeFocusedEdge(.right, widen: !hasShift)
			}
			return true

		case kVK_ANSI_I: // 上辺
			DispatchQueue.main.async { [weak self] in
				self?.gapSelectManager.resizeFocusedEdge(.up, widen: !hasShift)
			}
			return true

		case kVK_ANSI_K: // 下辺
			DispatchQueue.main.async { [weak self] in
				self?.gapSelectManager.resizeFocusedEdge(.down, widen: !hasShift)
			}
			return true

		default:
			// Block every key while in this mode (don't pass them to the app)
			return true
		}
	}

	// MARK: - Placement Reservation Awaiting Key Handling

	/// Handle the next single key pressed while waiting on a placement reservation.
	/// The wait is always cleared the moment this is called (since it's one-shot).
	/// If a key other than I/K/J/L/F (with no modifiers) is pressed, don't confirm the reservation, and
	/// Don't consume that key; pass it straight through to the app (return false)
	private func handlePlacementReserveAwaitingKeyEvent(_ event: NSEvent) -> Bool {
		isAwaitingPlacementReservationKey = false

		// Excluded if a modifier key is held (also hides the candidate display)
		guard HotkeyModifiers.from(event.modifierFlags).isEmpty else {
			DispatchQueue.main.async {
				PlacementReservationManager.shared.cancel()
			}
			return false
		}

		let kind: PlacementReservationKind?
		switch Int(event.keyCode) {
		case kVK_ANSI_I: kind = .aboveInColumn
		case kVK_ANSI_K: kind = .belowInColumn
		case kVK_ANSI_J: kind = .newColumnLeft
		case kVK_ANSI_L: kind = .newColumnRight
		case kVK_ANSI_F: kind = .float
		default: kind = nil
		}

		guard let kind = kind else {
			// Cancel the reservation if a non-target key is pressed (also hide the candidate display)
			DispatchQueue.main.async {
				PlacementReservationManager.shared.cancel()
			}
			return false
		}

		DispatchQueue.main.async {
			PlacementReservationManager.shared.confirm(kind: kind)
		}
		return true
	}

	// MARK: - Window Palette Mode Key Handling

	/// Key handling while in window palette mode
	private func handleWindowPaletteModeKeyEvent(_ event: NSEvent) -> Bool {
		// Enter: confirm the selection (automatically returns to normal mode afterward)
		if event.keyCode == kVK_Return {
			DispatchQueue.main.async { [weak self] in
				self?.windowPaletteManager.confirmSelection()
			}
			return true
		}

		switch Int(event.keyCode) {
		case kVK_ANSI_I: // 上に移動（前のワークスペースへ）
			DispatchQueue.main.async { [weak self] in
				self?.windowPaletteManager.moveUp()
			}
			return true

		case kVK_ANSI_K: // 下に移動（次のワークスペースへ）
			DispatchQueue.main.async { [weak self] in
				self?.windowPaletteManager.moveDown()
			}
			return true

		case kVK_ANSI_J: // 左に移動（前のウィンドウへ）
			DispatchQueue.main.async { [weak self] in
				self?.windowPaletteManager.moveLeft()
			}
			return true

		case kVK_ANSI_L: // 右に移動（次のウィンドウへ）
			DispatchQueue.main.async { [weak self] in
				self?.windowPaletteManager.moveRight()
			}
			return true

		default:
			// Block every key while in this mode (don't pass them to the app)
			return true
		}
	}
}

// MARK: - Notification Names

extension Notification.Name {
	static let modeChanged = Notification.Name("modeChanged")
}
