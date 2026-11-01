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
	case focusBack
	// Window movement
	case moveWindowLeft
	case moveWindowRight
	case moveWindowUp
	case moveWindowDown
	// Merge/split (step move)
	case stepMoveLeft
	case stepMoveRight
	// Float (floating)
	case floatToggle
	case floatFocusCycle
	case raiseFloatingWindows
	// Hide/restore
	case hideWindow
	case unhideLastWindow
	// Zen mode
	case zenToggle
	// Mode switching
	case gapSelectMode
	case windowPaletteMode
	// Layout
	case resetLayout
	case resizeIncrease
	case resizeDecrease
	// Workspace
	case workspaceNext
	case workspacePrev
	case moveWindowToNextWorkspace
	case moveWindowToPrevWorkspace
	// Placement reservation
	case placementReserve
}

// MARK: - HotkeySection (UI section grouping)

/// The section grouping in the settings screen
enum HotkeySection: String, CaseIterable {
	case focusAndMove = "Focus / Move Window"
	case float = "Float"
	case hidden = "Hidden"
	case modeSwitching = "Modes"
	case layout = "Layout"
	case workspace = "Workspace"
	case placementReserve = "Placement Reserve"
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

// MARK: - HotkeyKey (one key combination)

/// One key combination: a Carbon key code plus modifiers. Also the key for looking up an action.
/// In hotkeys.json it is written as a string such as "ctrl+opt+shift+j".
struct HotkeyKey: Hashable {
	let keyCode: Int
	let modifiers: HotkeyModifiers

	init(keyCode: Int, modifiers: HotkeyModifiers) {
		self.keyCode = keyCode
		self.modifiers = modifiers
	}

	/// Reads "ctrl+opt+j", "cmd+shift+left", "opt+f5". Returns nil when a modifier or the key name is unknown.
	init?(string: String) {
		let parts = string.lowercased()
			.split(separator: "+", omittingEmptySubsequences: false)
			.map { $0.trimmingCharacters(in: .whitespaces) }
		guard let name = parts.last, !name.isEmpty else { return nil }
		var mods: HotkeyModifiers = []
		for part in parts.dropLast() {
			switch part {
			case "cmd", "command", "super": mods.insert(.command)
			case "shift": mods.insert(.shift)
			case "opt", "option", "alt": mods.insert(.option)
			case "ctrl", "control": mods.insert(.control)
			default: return nil
			}
		}
		if let code = Self.keyCodes[name] {
			self.init(keyCode: code, modifiers: mods)
		} else if name.hasPrefix("keycode"), let code = Int(name.dropFirst("keycode".count)) {
			// Keys without a name (other layouts) round-trip by their raw code
			self.init(keyCode: code, modifiers: mods)
		} else {
			return nil
		}
	}

	/// The string form used in hotkeys.json (e.g. ctrl+opt+shift+j)
	var string: String {
		var parts: [String] = []
		if modifiers.contains(.control) { parts.append("ctrl") }
		if modifiers.contains(.option)  { parts.append("opt") }
		if modifiers.contains(.shift)   { parts.append("shift") }
		if modifiers.contains(.command) { parts.append("cmd") }
		parts.append(Self.keyNames[keyCode] ?? "keycode\(keyCode)")
		return parts.joined(separator: "+")
	}

	/// The display string (e.g. Ctrl+Option+J)
	var displayString: String {
		let modStr = modifiers.displayString
		let keyStr = HotkeyBinding.keyCodeToDisplayName(keyCode)
		if modStr.isEmpty {
			return keyStr
		}
		return "\(modStr)+\(keyStr)"
	}

	/// The value hotkeys.json holds for a list of keys: "" for none, a string for one, a list for several
	static func fileValue(_ keys: [HotkeyKey]) -> Any {
		switch keys.count {
		case 0: return ""
		case 1: return keys[0].string
		default: return keys.map(\.string)
		}
	}

	/// Key code -> the name written in hotkeys.json
	private static let keyNames: [Int: String] = {
		var names: [Int: String] = [
			kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d",
			kVK_ANSI_E: "e", kVK_ANSI_F: "f", kVK_ANSI_G: "g", kVK_ANSI_H: "h",
			kVK_ANSI_I: "i", kVK_ANSI_J: "j", kVK_ANSI_K: "k", kVK_ANSI_L: "l",
			kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o", kVK_ANSI_P: "p",
			kVK_ANSI_Q: "q", kVK_ANSI_R: "r", kVK_ANSI_S: "s", kVK_ANSI_T: "t",
			kVK_ANSI_U: "u", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x",
			kVK_ANSI_Y: "y", kVK_ANSI_Z: "z",
			kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
			kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
			kVK_ANSI_8: "8", kVK_ANSI_9: "9",
			kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
			kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
			kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
			kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
			kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\",
			kVK_ANSI_Grave: "`",
			kVK_Return: "return", kVK_Tab: "tab", kVK_Space: "space",
			kVK_Delete: "delete", kVK_ForwardDelete: "forwarddelete",
			kVK_Escape: "escape",
			kVK_LeftArrow: "left", kVK_RightArrow: "right",
			kVK_UpArrow: "up", kVK_DownArrow: "down",
			kVK_Home: "home", kVK_End: "end",
			kVK_PageUp: "pageup", kVK_PageDown: "pagedown",
		]
		let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
		                    kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
		for (index, code) in functionKeys.enumerated() {
			names[code] = "f\(index + 1)"
		}
		return names
	}()

	/// Name -> key code, including the other spellings accepted when reading
	private static let keyCodes: [String: Int] = {
		var codes = Dictionary(uniqueKeysWithValues: keyNames.map { ($1, $0) })
		codes["enter"] = kVK_Return
		codes["backspace"] = kVK_Delete
		codes["esc"] = kVK_Escape
		return codes
	}()
}

// MARK: - HotkeyBinding (a single key assignment)

/// Represents the keys assigned to one action
struct HotkeyBinding: Identifiable {
	var id: String { action.rawValue }
	let action: HotkeyAction
	/// Every key that runs the action; empty leaves the action without a key
	var keys: [HotkeyKey]

	init(action: HotkeyAction, keys: [HotkeyKey]) {
		self.action = action
		self.keys = keys
	}

	init(action: HotkeyAction, keyCode: Int, modifiers: HotkeyModifiers) {
		self.init(action: action, keys: [HotkeyKey(keyCode: keyCode, modifiers: modifiers)])
	}

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
		return HotkeyBinding.displayString(of: keys)
	}

	/// The display string for a list of keys
	static func displayString(of keys: [HotkeyKey]) -> String {
		if keys.isEmpty {
			return "None"
		}
		return keys.map(\.displayString).joined(separator: ", ")
	}

	// MARK: - Action name dictionary

	static let actionDisplayNames: [HotkeyAction: String] = [
		.focusLeft: "Focus Left",
		.focusRight: "Focus Right",
		.focusUp: "Focus Up",
		.focusDown: "Focus Down",
		.focusBack: "Focus Previous Window",
		.moveWindowLeft: "Move Window Left",
		.moveWindowRight: "Move Window Right",
		.moveWindowUp: "Move Window Up",
		.moveWindowDown: "Move Window Down",
		.stepMoveLeft: "Step Move Left (Merge / Split)",
		.stepMoveRight: "Step Move Right (Merge / Split)",
		.floatToggle: "Float ON/OFF",
		.floatFocusCycle: "Focus Float Window",
		.raiseFloatingWindows: "Raise Floating Windows",
		.hideWindow: "Hide Window",
		.unhideLastWindow: "Restore Last Hidden Window",
		.zenToggle: "Zen Mode ON/OFF",
		.gapSelectMode: "Gap Adjust Mode",
		.windowPaletteMode: "Window Palette Mode",
		.resetLayout: "Reset Layout",
		.resizeIncrease: "Enlarge Window",
		.resizeDecrease: "Shrink Window",
		.workspaceNext: "Next Workspace",
		.workspacePrev: "Previous Workspace",
		.moveWindowToNextWorkspace: "Move Window to Next Workspace",
		.moveWindowToPrevWorkspace: "Move Window to Previous Workspace",
		.placementReserve: "Placement Reserve (Await Next Key)",
	]

	// MARK: - Section classification dictionary

	static let actionSections: [HotkeyAction: HotkeySection] = [
		.focusLeft: .focusAndMove,
		.focusRight: .focusAndMove,
		.focusUp: .focusAndMove,
		.focusDown: .focusAndMove,
		.focusBack: .focusAndMove,
		.moveWindowLeft: .focusAndMove,
		.moveWindowRight: .focusAndMove,
		.moveWindowUp: .focusAndMove,
		.moveWindowDown: .focusAndMove,
		.stepMoveLeft: .focusAndMove,
		.stepMoveRight: .focusAndMove,
		.floatToggle: .float,
		.floatFocusCycle: .float,
		.raiseFloatingWindows: .float,
		.hideWindow: .hidden,
		.unhideLastWindow: .hidden,
		.zenToggle: .modeSwitching,
		.gapSelectMode: .modeSwitching,
		.windowPaletteMode: .modeSwitching,
		.resetLayout: .layout,
		.resizeIncrease: .layout,
		.resizeDecrease: .layout,
		.workspaceNext: .workspace,
		.workspacePrev: .workspace,
		.moveWindowToNextWorkspace: .workspace,
		.moveWindowToPrevWorkspace: .workspace,
		.placementReserve: .placementReserve,
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
			HotkeyBinding(action: .focusBack,  keyCode: kVK_ANSI_A, modifiers: ctrlOpt),
			// Window movement
			HotkeyBinding(action: .moveWindowLeft,  keyCode: kVK_ANSI_J, modifiers: ctrlOptShift),
			HotkeyBinding(action: .moveWindowRight, keyCode: kVK_ANSI_L, modifiers: ctrlOptShift),
			HotkeyBinding(action: .moveWindowUp,    keyCode: kVK_ANSI_I, modifiers: ctrlOptShift),
			HotkeyBinding(action: .moveWindowDown,  keyCode: kVK_ANSI_K, modifiers: ctrlOptShift),
			// Merge/split (step move)
			HotkeyBinding(action: .stepMoveLeft,  keyCode: kVK_ANSI_H, modifiers: ctrlOpt),
			HotkeyBinding(action: .stepMoveRight, keyCode: kVK_ANSI_Semicolon, modifiers: ctrlOpt),
			// Float
			HotkeyBinding(action: .floatToggle,     keyCode: kVK_ANSI_F, modifiers: ctrlOpt),
			HotkeyBinding(action: .floatFocusCycle, keyCode: kVK_ANSI_F, modifiers: ctrlOptShift),
			HotkeyBinding(action: .raiseFloatingWindows, keyCode: kVK_ANSI_B, modifiers: ctrlOpt),
			// Hide/restore
			HotkeyBinding(action: .hideWindow,       keyCode: kVK_ANSI_X, modifiers: ctrlOpt),
			HotkeyBinding(action: .unhideLastWindow, keyCode: kVK_ANSI_X, modifiers: ctrlOptShift),
			// Zen mode
			HotkeyBinding(action: .zenToggle, keyCode: kVK_ANSI_Z, modifiers: ctrlOpt),
			// Mode switching
			HotkeyBinding(action: .gapSelectMode,     keyCode: kVK_ANSI_G, modifiers: ctrlOpt),
			HotkeyBinding(action: .windowPaletteMode, keyCode: kVK_ANSI_P, modifiers: ctrlOpt),
			// Layout
			HotkeyBinding(action: .resetLayout,     keyCode: kVK_ANSI_R, modifiers: ctrlOpt),
			HotkeyBinding(action: .resizeIncrease,  keyCode: kVK_ANSI_Equal, modifiers: ctrlOpt),
			HotkeyBinding(action: .resizeDecrease,  keyCode: kVK_ANSI_Minus, modifiers: ctrlOpt),
			// Workspace
			HotkeyBinding(action: .workspaceNext, keyCode: kVK_ANSI_O, modifiers: ctrlOpt),
			HotkeyBinding(action: .workspacePrev, keyCode: kVK_ANSI_U, modifiers: ctrlOpt),
			HotkeyBinding(action: .moveWindowToNextWorkspace, keyCode: kVK_ANSI_O, modifiers: ctrlOptShift),
			HotkeyBinding(action: .moveWindowToPrevWorkspace, keyCode: kVK_ANSI_U, modifiers: ctrlOptShift),
			// Placement reservation
			HotkeyBinding(action: .placementReserve, keyCode: kVK_ANSI_N, modifiers: ctrlOpt),
		]
	}
}
