//
//  HotkeyBinding.swift
//  Axis
//
//  The hotkey data model
//

import Carbon
import AppKit

// MARK: - HotkeyAction (the full list of actions)

/// Actions that can be run via a hotkey
enum HotkeyAction: String, Codable, CaseIterable {
	// Focus movement
	case focusLeft
	case focusRight
	case focusUp
	case focusDown
	// Window movement
	case moveWindowLeft
	case moveWindowRight
	case moveWindowUp
	case moveWindowDown
	// Float (floating)
	case floatToggle
	case floatFocusCycle
	case raiseFloatingWindows
	// Zen mode
	case zenToggle
	// Mode switching
	case windowSelectMode
	case gapSelectMode
	case windowPaletteMode
	// Layout
	case resetLayout
	case resizeIncrease
	case resizeDecrease
	// Monitor
	case monitorCursorCycle
	// Workspace
	case workspaceNext
	case workspacePrev
	case moveWindowToNextWorkspace
	case moveWindowToPrevWorkspace
}

// MARK: - HotkeySection (UI section grouping)

/// The section grouping in the settings screen
enum HotkeySection: String, CaseIterable {
	case focusAndMove = "フォーカス / ウィンドウ移動"
	case float = "Float"
	case modeSwitching = "モード切り替え"
	case layout = "レイアウト"
	case monitor = "モニター"
	case workspace = "ワークスペース"
}

// MARK: - HotkeyModifiers (a combination of modifier keys)

/// A struct representing a combination of modifier keys
struct HotkeyModifiers: OptionSet, Codable, Hashable {
	let rawValue: UInt

	static let control = HotkeyModifiers(rawValue: 1 << 0)
	static let option  = HotkeyModifiers(rawValue: 1 << 1)
	static let shift   = HotkeyModifiers(rawValue: 1 << 2)
	static let command = HotkeyModifiers(rawValue: 1 << 3)

	/// Convert from NSEvent.ModifierFlags
	static func from(_ flags: NSEvent.ModifierFlags) -> HotkeyModifiers {
		var result: HotkeyModifiers = []
		if flags.contains(.control) { result.insert(.control) }
		if flags.contains(.option)  { result.insert(.option) }
		if flags.contains(.shift)   { result.insert(.shift) }
		if flags.contains(.command) { result.insert(.command) }
		return result
	}

	/// Convert from CGEventFlags
	static func from(_ flags: CGEventFlags) -> HotkeyModifiers {
		var result: HotkeyModifiers = []
		if flags.contains(.maskControl)   { result.insert(.control) }
		if flags.contains(.maskAlternate) { result.insert(.option) }
		if flags.contains(.maskShift)     { result.insert(.shift) }
		if flags.contains(.maskCommand)   { result.insert(.command) }
		return result
	}

	/// Convert to CGEventFlags
	func toCGEventFlags() -> CGEventFlags {
		var flags: CGEventFlags = []
		if contains(.control) { flags.insert(.maskControl) }
		if contains(.option)  { flags.insert(.maskAlternate) }
		if contains(.shift)   { flags.insert(.maskShift) }
		if contains(.command) { flags.insert(.maskCommand) }
		return flags
	}

	/// The display string (e.g. Ctrl+Option+Shift)
	var displayString: String {
		var parts: [String] = []
		if contains(.control) { parts.append("Ctrl") }
		if contains(.option)  { parts.append("Option") }
		if contains(.shift)   { parts.append("Shift") }
		if contains(.command) { parts.append("Cmd") }
		return parts.joined(separator: "+")
	}
}

// MARK: - HotkeyLookupKey (a key for lookups)

/// The key used to look up an action by its (keyCode, modifiers) combination
struct HotkeyLookupKey: Hashable {
	let keyCode: Int
	let modifiers: HotkeyModifiers
}

// MARK: - HotkeyBinding (a single key assignment)

/// Represents a single hotkey assignment
struct HotkeyBinding: Codable, Identifiable {
	var id: String { action.rawValue }
	let action: HotkeyAction
	var keyCode: Int
	var modifiers: HotkeyModifiers

	/// The action name (for UI display)
	var displayName: String {
		return HotkeyBinding.actionDisplayNames[action] ?? action.rawValue
	}

	/// Section
	var section: HotkeySection {
		return HotkeyBinding.actionSections[action] ?? .focusAndMove
	}

	/// The shortcut's display string (e.g. Ctrl+Option+J)
	var shortcutDisplayString: String {
		let modStr = modifiers.displayString
		let keyStr = HotkeyBinding.keyCodeToDisplayName(keyCode)
		if modStr.isEmpty {
			return keyStr
		}
		return "\(modStr)+\(keyStr)"
	}

	/// Generate the lookup key
	var lookupKey: HotkeyLookupKey {
		return HotkeyLookupKey(keyCode: keyCode, modifiers: modifiers)
	}

	// MARK: - Action name dictionary

	static let actionDisplayNames: [HotkeyAction: String] = [
		.focusLeft: "左にフォーカス移動",
		.focusRight: "右にフォーカス移動",
		.focusUp: "上にフォーカス移動",
		.focusDown: "下にフォーカス移動",
		.moveWindowLeft: "左にウィンドウ移動",
		.moveWindowRight: "右にウィンドウ移動",
		.moveWindowUp: "上にウィンドウ移動",
		.moveWindowDown: "下にウィンドウ移動",
		.floatToggle: "Float ON/OFF",
		.floatFocusCycle: "Floatウィンドウにフォーカス",
		.raiseFloatingWindows: "浮遊ウィンドウを最前面へ",
		.zenToggle: "Zen モード ON/OFF",
		.windowSelectMode: "Window Select モード",
		.gapSelectMode: "Gap Select モード",
		.windowPaletteMode: "Window Palette モード",
		.resetLayout: "レイアウトをリセット",
		.resizeIncrease: "ウィンドウを拡大",
		.resizeDecrease: "ウィンドウを縮小",
		.monitorCursorCycle: "カーソルを次のモニターへ",
		.workspaceNext: "次のワークスペース",
		.workspacePrev: "前のワークスペース",
		.moveWindowToNextWorkspace: "ウィンドウを次のワークスペースへ",
		.moveWindowToPrevWorkspace: "ウィンドウを前のワークスペースへ",
	]

	// MARK: - Section classification dictionary

	static let actionSections: [HotkeyAction: HotkeySection] = [
		.focusLeft: .focusAndMove,
		.focusRight: .focusAndMove,
		.focusUp: .focusAndMove,
		.focusDown: .focusAndMove,
		.moveWindowLeft: .focusAndMove,
		.moveWindowRight: .focusAndMove,
		.moveWindowUp: .focusAndMove,
		.moveWindowDown: .focusAndMove,
		.floatToggle: .float,
		.floatFocusCycle: .float,
		.raiseFloatingWindows: .float,
		.zenToggle: .modeSwitching,
		.windowSelectMode: .modeSwitching,
		.gapSelectMode: .modeSwitching,
		.windowPaletteMode: .modeSwitching,
		.resetLayout: .layout,
		.resizeIncrease: .layout,
		.resizeDecrease: .layout,
		.monitorCursorCycle: .monitor,
		.workspaceNext: .workspace,
		.workspacePrev: .workspace,
		.moveWindowToNextWorkspace: .workspace,
		.moveWindowToPrevWorkspace: .workspace,
	]

	// MARK: - Key code -> display name

	/// Convert a Carbon key code into a display string
	static func keyCodeToDisplayName(_ keyCode: Int) -> String {
		let names: [Int: String] = [
			kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
			kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
			kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
			kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
			kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
			kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
			kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
			kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
			kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
			kVK_ANSI_8: "8", kVK_ANSI_9: "9",
			kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
			kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
			kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
			kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
			kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\",
			kVK_ANSI_Grave: "`",
			kVK_Return: "Return", kVK_Tab: "Tab", kVK_Space: "Space",
			kVK_Delete: "Delete", kVK_ForwardDelete: "Forward Delete",
			kVK_Escape: "Escape",
			kVK_LeftArrow: "\u{2190}", kVK_RightArrow: "\u{2192}",
			kVK_UpArrow: "\u{2191}", kVK_DownArrow: "\u{2193}",
			kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
			kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
			kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
			kVK_Home: "Home", kVK_End: "End",
			kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
		]
		return names[keyCode] ?? "Key(\(keyCode))"
	}

	// MARK: - Default values

	/// The list of default settings matching the current hardcoded values
	static func defaults() -> [HotkeyBinding] {
		let ctrlOpt: HotkeyModifiers = [.control, .option]
		let ctrlOptShift: HotkeyModifiers = [.control, .option, .shift]

		return [
			// Focus movement
			HotkeyBinding(action: .focusLeft,  keyCode: kVK_ANSI_J, modifiers: ctrlOpt),
			HotkeyBinding(action: .focusRight, keyCode: kVK_ANSI_L, modifiers: ctrlOpt),
			HotkeyBinding(action: .focusUp,    keyCode: kVK_ANSI_I, modifiers: ctrlOpt),
			HotkeyBinding(action: .focusDown,  keyCode: kVK_ANSI_K, modifiers: ctrlOpt),
			// Window movement
			HotkeyBinding(action: .moveWindowLeft,  keyCode: kVK_ANSI_J, modifiers: ctrlOptShift),
			HotkeyBinding(action: .moveWindowRight, keyCode: kVK_ANSI_L, modifiers: ctrlOptShift),
			HotkeyBinding(action: .moveWindowUp,    keyCode: kVK_ANSI_I, modifiers: ctrlOptShift),
			HotkeyBinding(action: .moveWindowDown,  keyCode: kVK_ANSI_K, modifiers: ctrlOptShift),
			// Float
			HotkeyBinding(action: .floatToggle,     keyCode: kVK_ANSI_F, modifiers: ctrlOpt),
			HotkeyBinding(action: .floatFocusCycle, keyCode: kVK_ANSI_F, modifiers: ctrlOptShift),
			HotkeyBinding(action: .raiseFloatingWindows, keyCode: kVK_ANSI_B, modifiers: ctrlOpt),
			// Zen mode
			HotkeyBinding(action: .zenToggle, keyCode: kVK_ANSI_Z, modifiers: ctrlOpt),
			// Mode switching
			HotkeyBinding(action: .windowSelectMode,  keyCode: kVK_ANSI_W, modifiers: ctrlOpt),
			HotkeyBinding(action: .gapSelectMode,     keyCode: kVK_ANSI_G, modifiers: ctrlOpt),
			HotkeyBinding(action: .windowPaletteMode, keyCode: kVK_ANSI_P, modifiers: ctrlOpt),
			// Layout
			HotkeyBinding(action: .resetLayout,     keyCode: kVK_ANSI_R, modifiers: ctrlOpt),
			HotkeyBinding(action: .resizeIncrease,  keyCode: kVK_ANSI_Equal, modifiers: ctrlOpt),
			HotkeyBinding(action: .resizeDecrease,  keyCode: kVK_ANSI_Minus, modifiers: ctrlOpt),
			// Monitor
			HotkeyBinding(action: .monitorCursorCycle, keyCode: kVK_ANSI_M, modifiers: ctrlOpt),
			// Workspace
			HotkeyBinding(action: .workspaceNext, keyCode: kVK_ANSI_O, modifiers: ctrlOpt),
			HotkeyBinding(action: .workspacePrev, keyCode: kVK_ANSI_U, modifiers: ctrlOpt),
			HotkeyBinding(action: .moveWindowToNextWorkspace, keyCode: kVK_ANSI_O, modifiers: ctrlOptShift),
			HotkeyBinding(action: .moveWindowToPrevWorkspace, keyCode: kVK_ANSI_U, modifiers: ctrlOptShift),
		]
	}
}
