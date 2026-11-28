//
//  HotkeyKeyTests.swift
//  Axis core tests
//
//  The key strings of hotkeys.json: parsing, writing back, display names, the file value and the
//  key lookup table built from the bindings.
//

import Foundation
import AppKit
import Carbon

private func parse(_ string: String) -> HotkeyKey? {
	HotkeyKey(string: string)
}

private func expectKey(_ string: String, _ keyCode: Int, _ modifiers: HotkeyModifiers, file: StaticString = #filePath, line: UInt = #line) {
	guard let key = parse(string) else {
		fail("\"\(string)\" did not parse", file: file, line: line)
		return
	}
	expectEqual(key, HotkeyKey(keyCode: keyCode, modifiers: modifiers), "\"\(string)\"", file: file, line: line)
}

private func expectRejected(_ string: String, file: StaticString = #filePath, line: UInt = #line) {
	expect(parse(string) == nil, "\"\(string)\" should not parse, got \(String(describing: parse(string)?.string))", file: file, line: line)
}

private func expectWritten(_ string: String, _ written: String, file: StaticString = #filePath, line: UInt = #line) {
	guard let key = parse(string) else {
		fail("\"\(string)\" did not parse", file: file, line: line)
		return
	}
	expectEqual(key.string, written, "\"\(string)\" written back", file: file, line: line)
}

let hotkeyKeyTests: [TestCase] = modifierParsingTests + keyNameTests + rejectedStringTests + roundTripTests
	+ fileValueTests + displayTests + modifierFlagTests + resolveTests

// MARK: - Modifiers

private let modifierParsingTests: [TestCase] = [
	TestCase("every modifier name and alias maps to its modifier") {
		let names: [(String, HotkeyModifiers)] = [
			("cmd", .command), ("command", .command), ("super", .command),
			("shift", .shift),
			("opt", .option), ("option", .option), ("alt", .option),
			("ctrl", .control), ("control", .control),
		]
		for (name, modifier) in names {
			expectKey("\(name)+j", kVK_ANSI_J, modifier)
		}
	},
	TestCase("modifier order does not change the key") {
		let expected = HotkeyModifiers([.control, .option, .shift, .command])
		for string in ["ctrl+opt+shift+cmd+j", "cmd+shift+opt+ctrl+j", "shift+ctrl+cmd+opt+j", "opt+cmd+ctrl+shift+j"] {
			expectKey(string, kVK_ANSI_J, expected)
		}
	},
	TestCase("case and surrounding spaces are ignored") {
		expectKey("CTRL+Opt+J", kVK_ANSI_J, [.control, .option])
		expectKey("  ctrl + opt + j  ", kVK_ANSI_J, [.control, .option])
		expectKey("Cmd+SHIFT+LEFT", kVK_LeftArrow, [.command, .shift])
		expectKey("\tctrl+j", kVK_ANSI_J, .control)
	},
	TestCase("a duplicated modifier counts once") {
		expectKey("ctrl+ctrl+j", kVK_ANSI_J, .control)
		expectKey("cmd+super+command+j", kVK_ANSI_J, .command)
		expectWritten("alt+opt+option+j", "opt+j")
	},
	TestCase("a key without modifiers parses") {
		expectKey("j", kVK_ANSI_J, [])
		expectKey("f5", kVK_F5, [])
	},
	TestCase("modifiers are written in the order ctrl, opt, shift, cmd") {
		expectWritten("cmd+shift+opt+ctrl+j", "ctrl+opt+shift+cmd+j")
		expectWritten("super+alt+j", "opt+cmd+j")
		expectWritten("control+command+j", "ctrl+cmd+j")
	},
]

// MARK: - Key names

private let keyNameTests: [TestCase] = [
	TestCase("letters parse to their key codes") {
		let codes: [(String, Int)] = [
			("a", kVK_ANSI_A), ("j", kVK_ANSI_J), ("m", kVK_ANSI_M), ("z", kVK_ANSI_Z),
		]
		for (name, code) in codes { expectKey("ctrl+\(name)", code, .control) }
	},
	TestCase("digits parse to the number row, not the keypad") {
		let codes = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
		             kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
		for (digit, code) in codes.enumerated() { expectKey("opt+\(digit)", code, .option) }
	},
	TestCase("F1 to F20 parse") {
		let codes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
		             kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
		for (index, code) in codes.enumerated() { expectKey("ctrl+f\(index + 1)", code, .control) }
	},
	TestCase("F21 and F0 do not parse") {
		expectRejected("f21")
		expectRejected("f0")
	},
	TestCase("arrows and navigation keys parse") {
		expectKey("left", kVK_LeftArrow, [])
		expectKey("right", kVK_RightArrow, [])
		expectKey("up", kVK_UpArrow, [])
		expectKey("down", kVK_DownArrow, [])
		expectKey("home", kVK_Home, [])
		expectKey("end", kVK_End, [])
		expectKey("pageup", kVK_PageUp, [])
		expectKey("pagedown", kVK_PageDown, [])
	},
	TestCase("space, return, tab, escape and the delete keys parse") {
		expectKey("space", kVK_Space, [])
		expectKey("return", kVK_Return, [])
		expectKey("tab", kVK_Tab, [])
		expectKey("escape", kVK_Escape, [])
		expectKey("delete", kVK_Delete, [])
		expectKey("forwarddelete", kVK_ForwardDelete, [])
	},
	TestCase("alternate spellings enter, backspace and esc parse and are written with the main name") {
		expectKey("enter", kVK_Return, [])
		expectKey("backspace", kVK_Delete, [])
		expectKey("esc", kVK_Escape, [])
		expectWritten("enter", "return")
		expectWritten("backspace", "delete")
		expectWritten("esc", "escape")
	},
	TestCase("punctuation keys parse") {
		let codes: [(String, Int)] = [
			("-", kVK_ANSI_Minus), ("=", kVK_ANSI_Equal), ("[", kVK_ANSI_LeftBracket), ("]", kVK_ANSI_RightBracket),
			(";", kVK_ANSI_Semicolon), ("'", kVK_ANSI_Quote), (",", kVK_ANSI_Comma), (".", kVK_ANSI_Period),
			("/", kVK_ANSI_Slash), ("\\", kVK_ANSI_Backslash), ("`", kVK_ANSI_Grave),
		]
		for (name, code) in codes {
			expectKey(name, code, [])
			expectKey("ctrl+opt+\(name)", code, [.control, .option])
		}
	},
	TestCase("keyNN reads a raw key code, also for keys that have a name") {
		expectKey("keycode200", 200, [])
		expectKey("ctrl+keycode42", 42, .control)
		expectKey("KeyCode7", 7, [])
		// Code 0 is the A key, so the written form is the name
		expectKey("keycode0", kVK_ANSI_A, [])
		expectWritten("keycode0", "a")
		expectWritten("keycode200", "keycode200")
	},
	TestCase("a key code without a name is written as keycodeNN") {
		expectEqual(HotkeyKey(keyCode: 200, modifiers: [.command]).string, "cmd+keycode200")
	},
]

// MARK: - Rejected strings

private let rejectedStringTests: [TestCase] = [
	TestCase("an empty or blank string does not parse") {
		expectRejected("")
		expectRejected("   ")
	},
	TestCase("a modifier with no key does not parse") {
		expectRejected("ctrl+")
		expectRejected("ctrl+opt+")
		// A lone modifier is read as a key name
		expectRejected("ctrl")
		expectRejected("cmd+shift")
	},
	TestCase("an unknown modifier or key does not parse") {
		expectRejected("hyper+j")
		expectRejected("ctrl+hyper+j")
		expectRejected("ctrl+unknownkey")
		expectRejected("ctrl+jj")
		expectRejected("garbage")
		expectRejected("!!!")
	},
	TestCase("a key name in modifier position does not parse") {
		expectRejected("j+ctrl")
		expectRejected("j+k")
	},
	TestCase("empty parts between plus signs do not parse") {
		expectRejected("+j")
		expectRejected("ctrl++j")
		expectRejected("ctrl++")
		expectRejected("++")
	},
	TestCase("keycode without a number does not parse") {
		expectRejected("keycode")
		expectRejected("keycodex")
		expectRejected("keycode1.5")
	},
]

// MARK: - Round trips

private let roundTripTests: [TestCase] = [
	TestCase("every default binding survives string and back") {
		for binding in HotkeyBinding.defaults() {
			for key in binding.keys {
				expectEqual(parse(key.string), key, "\(binding.action.rawValue): \"\(key.string)\"")
			}
		}
	},
	TestCase("every default binding has one key and the actions are all covered once") {
		let defaults = HotkeyBinding.defaults()
		expectEqual(Set(defaults.map(\.action)), Set(HotkeyAction.allCases), "actions with a default")
		expectEqual(defaults.count, HotkeyAction.allCases.count, "bindings")
		for binding in defaults { expectEqual(binding.keys.count, 1, binding.action.rawValue) }
	},
	TestCase("the default keys are distinct") {
		let keys = HotkeyBinding.defaults().flatMap(\.keys)
		expectEqual(Set(keys).count, keys.count, "distinct default keys")
	},
	TestCase("hand-written strings read and write back unchanged in canonical form") {
		let strings = [
			"ctrl+opt+shift+j", "ctrl+opt+left", "shift+cmd+right", "opt+f5", "ctrl+opt+shift+cmd+space",
			"cmd+return", "escape", "ctrl+delete", "shift+forwarddelete", "ctrl+opt+-", "ctrl+opt+=", "cmd+[", "cmd+]",
			"ctrl+;", "ctrl+'", "ctrl+,", "ctrl+.", "ctrl+/", "ctrl+\\", "ctrl+`", "f20", "opt+0", "cmd+9",
			"ctrl+pageup", "ctrl+pagedown", "home", "end", "tab", "ctrl+keycode200",
		]
		for string in strings {
			guard let key = parse(string) else {
				fail("\"\(string)\" did not parse")
				continue
			}
			expectEqual(key.string, string, "\"\(string)\" written back")
			expectEqual(parse(key.string), key, "\"\(string)\" round trip")
		}
	},
	TestCase("every named key code round trips through its name") {
		for code in 0..<256 {
			let key = HotkeyKey(keyCode: code, modifiers: [.control, .shift])
			expectEqual(parse(key.string), key, "key code \(code) as \"\(key.string)\"")
		}
	},
]

// MARK: - File value

private let fileValueTests: [TestCase] = [
	TestCase("no keys are written as an empty string") {
		expectEqual(HotkeyKey.fileValue([]) as? String, "")
	},
	TestCase("one key is written as its string") {
		let key = HotkeyKey(keyCode: kVK_ANSI_J, modifiers: [.control, .option])
		expectEqual(HotkeyKey.fileValue([key]) as? String, "ctrl+opt+j")
	},
	TestCase("several keys are written as a list in order") {
		let first = HotkeyKey(keyCode: kVK_ANSI_J, modifiers: [.control, .option])
		let second = HotkeyKey(keyCode: kVK_LeftArrow, modifiers: [.control, .option])
		let third = HotkeyKey(keyCode: kVK_F5, modifiers: [])
		expectEqual(HotkeyKey.fileValue([first, second]) as? [String], ["ctrl+opt+j", "ctrl+opt+left"])
		expectEqual(HotkeyKey.fileValue([second, third, first]) as? [String], ["ctrl+opt+left", "f5", "ctrl+opt+j"])
	},
]

// MARK: - Display

private let displayTests: [TestCase] = [
	TestCase("a key shows its modifiers in the order Ctrl, Option, Shift, Cmd") {
		let key = HotkeyKey(keyCode: kVK_ANSI_J, modifiers: [.command, .shift, .option, .control])
		expectEqual(key.displayString, "Ctrl+Option+Shift+Cmd+J")
		expectEqual(key.keyName, "J")
	},
	TestCase("a key without modifiers shows only the key") {
		expectEqual(HotkeyKey(keyCode: kVK_Space, modifiers: []).displayString, "Space")
		expectEqual(HotkeyKey(keyCode: kVK_F12, modifiers: []).displayString, "F12")
	},
	TestCase("arrows show as arrow symbols") {
		expectEqual(HotkeyKey(keyCode: kVK_LeftArrow, modifiers: .control).displayString, "Ctrl+\u{2190}")
		expectEqual(HotkeyKey(keyCode: kVK_RightArrow, modifiers: .control).displayString, "Ctrl+\u{2192}")
		expectEqual(HotkeyKey(keyCode: kVK_UpArrow, modifiers: .control).displayString, "Ctrl+\u{2191}")
		expectEqual(HotkeyKey(keyCode: kVK_DownArrow, modifiers: .control).displayString, "Ctrl+\u{2193}")
	},
	TestCase("a key code without a display name shows its number") {
		expectEqual(HotkeyKey(keyCode: 200, modifiers: .option).displayString, "Option+Key(200)")
	},
	TestCase("F13 to F20 have a string name but no display name") {
		// Current behavior: the display falls back to the key code
		expectEqual(HotkeyKey(keyCode: kVK_F13, modifiers: []).keyName, "Key(105)")
		expectEqual(HotkeyKey(keyCode: kVK_F20, modifiers: []).keyName, "Key(90)")
	},
	TestCase("a list of keys is joined with commas and an empty list shows None") {
		let keys = [HotkeyKey(keyCode: kVK_ANSI_J, modifiers: .control), HotkeyKey(keyCode: kVK_Return, modifiers: .command)]
		expectEqual(HotkeyBinding.displayString(of: keys), "Ctrl+J, Cmd+Return")
		expectEqual(HotkeyBinding.displayString(of: []), "None")
	},
	TestCase("every default binding shows a name for every key") {
		for binding in HotkeyBinding.defaults() {
			expect(!binding.shortcutDisplayString.contains("Key("), "\(binding.action.rawValue): \(binding.shortcutDisplayString)")
			expect(!binding.displayName.isEmpty, binding.action.rawValue)
			expect(HotkeyBinding.actionDisplayNames[binding.action] != nil, "display name of \(binding.action.rawValue)")
			expect(HotkeyBinding.actionSections[binding.action] != nil, "section of \(binding.action.rawValue)")
		}
	},
	TestCase("modifier display strings") {
		expectEqual(HotkeyModifiers([]).displayString, "")
		expectEqual(HotkeyModifiers([.control, .option]).displayString, "Ctrl+Option")
		expectEqual(HotkeyModifiers([.shift, .command]).displayString, "Shift+Cmd")
	},
]

// MARK: - Modifier flags

private let modifierFlagTests: [TestCase] = [
	TestCase("NSEvent modifier flags map to hotkey modifiers and ignore the others") {
		expectEqual(HotkeyModifiers.from(NSEvent.ModifierFlags([.control, .option, .shift, .command])),
			HotkeyModifiers([.control, .option, .shift, .command]))
		expectEqual(HotkeyModifiers.from(NSEvent.ModifierFlags([.option])), HotkeyModifiers.option)
		expectEqual(HotkeyModifiers.from(NSEvent.ModifierFlags([.capsLock, .numericPad, .function])), HotkeyModifiers([]))
		expectEqual(HotkeyModifiers.from(NSEvent.ModifierFlags([])), HotkeyModifiers([]))
	},
	TestCase("CGEvent flags map to hotkey modifiers and ignore the others") {
		expectEqual(HotkeyModifiers.from(CGEventFlags([.maskControl, .maskAlternate, .maskShift, .maskCommand])),
			HotkeyModifiers([.control, .option, .shift, .command]))
		expectEqual(HotkeyModifiers.from(CGEventFlags([.maskCommand])), HotkeyModifiers.command)
		expectEqual(HotkeyModifiers.from(CGEventFlags([.maskAlphaShift, .maskSecondaryFn, .maskNumericPad])), HotkeyModifiers([]))
		expectEqual(HotkeyModifiers.from(CGEventFlags([])), HotkeyModifiers([]))
	},
]

// MARK: - Lookup table

private let jKey = HotkeyKey(keyCode: kVK_ANSI_J, modifiers: [.control, .option])
private let lKey = HotkeyKey(keyCode: kVK_ANSI_L, modifiers: [.control, .option])

private func defaultBindings(changing changes: [HotkeyAction: [HotkeyKey]]) -> [HotkeyBinding] {
	HotkeyBinding.defaults().map { binding in
		var copy = binding
		if let keys = changes[binding.action] { copy.keys = keys }
		return copy
	}
}

private let resolveTests: [TestCase] = [
	TestCase("the defaults resolve without conflicts to one entry per key") {
		let result = HotkeyStore.resolve(HotkeyBinding.defaults())
		expect(result.conflicts.isEmpty, "conflicts: \(result.conflicts)")
		expectEqual(result.table.count, HotkeyBinding.defaults().count)
		expectEqual(result.table[jKey], .focusLeft)
		expectEqual(result.table[lKey], .focusRight)
	},
	TestCase("a key moved onto another action's default key goes to the changed action and is reported") {
		let result = HotkeyStore.resolve(defaultBindings(changing: [.focusRight: [jKey]]))
		expectEqual(result.table[jKey], .focusRight)
		expect(result.table[lKey] == nil, "the old key of the changed action is free")
		expectEqual(result.conflicts, ["ctrl+opt+j is set for both \"focusLeft\" and \"focusRight\". Only \"focusRight\" gets it."])
	},
	TestCase("a cleared action gives up its key and a changed one can take it without a conflict") {
		let result = HotkeyStore.resolve(defaultBindings(changing: [.focusLeft: [], .focusRight: [jKey]]))
		expectEqual(result.table[jKey], .focusRight)
		expect(result.conflicts.isEmpty, "conflicts: \(result.conflicts)")
	},
	TestCase("an action with several keys fills the table with all of them") {
		let extra = HotkeyKey(keyCode: kVK_LeftArrow, modifiers: [.control, .option])
		let result = HotkeyStore.resolve(defaultBindings(changing: [.focusLeft: [jKey, extra]]))
		expectEqual(result.table[jKey], .focusLeft)
		expectEqual(result.table[extra], .focusLeft)
		expect(result.conflicts.isEmpty, "conflicts: \(result.conflicts)")
	},
	TestCase("the same key listed twice for one action is not a conflict") {
		let result = HotkeyStore.resolve(defaultBindings(changing: [.focusLeft: [jKey, jKey]]))
		expectEqual(result.table[jKey], .focusLeft)
		expect(result.conflicts.isEmpty, "conflicts: \(result.conflicts)")
	},
	TestCase("two changed actions on one key: the later binding wins") {
		let shared = HotkeyKey(keyCode: kVK_F5, modifiers: [])
		let result = HotkeyStore.resolve(defaultBindings(changing: [.focusLeft: [shared], .zenToggle: [shared]]))
		expectEqual(result.table[shared], .zenToggle)
		expectEqual(result.conflicts.count, 1)
		expect(result.conflicts.first?.hasPrefix("f5 is set for both \"focusLeft\" and \"zenToggle\"") == true, "conflict: \(result.conflicts)")
	},
	TestCase("no bindings resolve to an empty table") {
		let result = HotkeyStore.resolve([])
		expect(result.table.isEmpty, "table")
		expect(result.conflicts.isEmpty, "conflicts")
	},
]
