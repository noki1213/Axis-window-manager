//
//  SettingsValue.swift
//  Axis
//
//  How a value read from settings.json is checked against the type a setting expects.
//

import Foundation

/// A checked value, or the default with a line saying what was wrong
nonisolated enum SettingsValue {
	/// The value as `Bool`, or `fallback` (with a problem) when it is not a boolean
	static func bool(_ value: Any, key: String, default fallback: Bool) -> (value: Bool, problem: String?) {
		guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
			return (fallback, "\"\(key)\": expected true or false. Using the default.")
		}
		return (number.boolValue, nil)
	}

	/// The value as a number within `range`, or `fallback` (with a problem) when not a number or out of range
	static func number(_ value: Any, key: String, default fallback: Double, in range: ClosedRange<Double>) -> (value: Double, problem: String?) {
		guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
			return (fallback, "\"\(key)\": expected a number. Using the default.")
		}
		guard range.contains(number.doubleValue) else {
			return (fallback, "\"\(key)\": must be between \(format(range.lowerBound)) and \(format(range.upperBound)). Using the default.")
		}
		return (number.doubleValue, nil)
	}

	/// The value as a list of strings, or `fallback` (with a problem) when it is not one
	static func strings(_ value: Any, key: String, default fallback: [String]) -> (value: [String], problem: String?) {
		guard let list = value as? [String] else {
			return (fallback, "\"\(key)\": expected a list of strings. Using the default.")
		}
		return (list, nil)
	}

	private static func format(_ value: Double) -> String {
		value == value.rounded() ? String(Int(value)) : String(value)
	}
}
