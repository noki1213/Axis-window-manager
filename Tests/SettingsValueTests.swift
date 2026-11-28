//
//  SettingsValueTests.swift
//  Axis core tests
//
//  How values read from settings.json are checked: booleans, numbers within a range, string lists.
//

import Foundation

private func json(_ text: String) -> Any {
	try! JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
}

let settingsValueTests: [TestCase] = [
	TestCase("a JSON boolean is accepted") {
		let on = SettingsValue.bool(json("true"), key: "k", default: false)
		expectEqual(on.value, true)
		expect(on.problem == nil, "problem")
		let off = SettingsValue.bool(json("false"), key: "k", default: true)
		expectEqual(off.value, false)
		expect(off.problem == nil, "problem")
	},
	TestCase("numbers, strings and lists are not booleans") {
		for text in ["1", "0", "1.5", "\"true\"", "[true]", "null", "{}"] {
			let result = SettingsValue.bool(json(text), key: "flag", default: true)
			expectEqual(result.value, true, text)
			expectEqual(result.problem, "\"flag\": expected true or false. Using the default.", text)
		}
		let pasted: Any = NSNull()
		expectEqual(SettingsValue.bool(pasted, key: "flag", default: false).value, false)
	},
	TestCase("a number inside the range is accepted, bounds included") {
		for (text, expected) in [("5", 5.0), ("0", 0.0), ("10", 10.0), ("2.5", 2.5), ("-0", 0.0)] {
			let result = SettingsValue.number(json(text), key: "n", default: 7, in: 0...10)
			expectEqual(result.value, expected, text)
			expect(result.problem == nil, text)
		}
	},
	TestCase("a number outside the range falls back and names the bounds") {
		let high = SettingsValue.number(json("11"), key: "gap", default: 7, in: 0...10)
		expectEqual(high.value, 7)
		expectEqual(high.problem, "\"gap\": must be between 0 and 10. Using the default.")
		let low = SettingsValue.number(json("-0.5"), key: "gap", default: 7, in: 0...10)
		expectEqual(low.value, 7)
		expectEqual(low.problem, "\"gap\": must be between 0 and 10. Using the default.")
	},
	TestCase("fractional bounds are written with their decimals") {
		let result = SettingsValue.number(json("2"), key: "ratio", default: 0.5, in: 0.1...1.5)
		expectEqual(result.value, 0.5)
		expectEqual(result.problem, "\"ratio\": must be between 0.1 and 1.5. Using the default.")
	},
	TestCase("a boolean, string or list is not a number") {
		for text in ["true", "false", "\"5\"", "[5]", "null", "{}"] {
			let result = SettingsValue.number(json(text), key: "n", default: 3, in: 0...10)
			expectEqual(result.value, 3, text)
			expectEqual(result.problem, "\"n\": expected a number. Using the default.", text)
		}
	},
	TestCase("a list of strings is accepted, an empty list too") {
		let some = SettingsValue.strings(json("[\"a\", \"b\"]"), key: "l", default: ["x"])
		expectEqual(some.value, ["a", "b"])
		expect(some.problem == nil, "problem")
		let none = SettingsValue.strings(json("[]"), key: "l", default: ["x"])
		expectEqual(none.value, [])
		expect(none.problem == nil, "problem")
	},
	TestCase("anything but a list of strings falls back") {
		for text in ["\"a\"", "[1, 2]", "[\"a\", 1]", "true", "5", "null", "{}"] {
			let result = SettingsValue.strings(json(text), key: "apps", default: ["x"])
			expectEqual(result.value, ["x"], text)
			expectEqual(result.problem, "\"apps\": expected a list of strings. Using the default.", text)
		}
	},
]
