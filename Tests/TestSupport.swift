//
//  TestSupport.swift
//  Axis core tests
//
//  A minimal test framework: named cases, assertions that record a failure with its file and
//  line, and a runner that prints a summary. XCTest is not used so the core can be compiled and
//  checked with a single swiftc invocation.
//

import Foundation
import CoreGraphics

/// One named test. The body reports failures through `expect`, `expectEqual` and `fail`;
/// an error thrown out of the body also fails the test. The name states the behavior checked.
struct TestCase {
	let name: String
	let body: () throws -> Void

	init(_ name: String, _ body: @escaping () throws -> Void) {
		self.name = name
		self.body = body
	}
}

/// A named group of test cases, run in order.
struct TestSuite {
	let name: String
	let cases: [TestCase]

	init(_ name: String, _ cases: [TestCase]) {
		self.name = name
		self.cases = cases
	}
}

// MARK: - Assertions

/// Failures recorded by the test that is running. Tests run one at a time on the main actor,
/// so a plain global is enough.
private var currentFailures: [String] = []

/// Records a failure at the caller's file and line.
func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
	currentFailures.append("\(file):\(line): \(message)")
}

/// Fails unless `condition` holds.
func expect(
	_ condition: @autoclosure () -> Bool,
	_ message: @autoclosure () -> String = "",
	file: StaticString = #filePath, line: UInt = #line
) {
	guard !condition() else { return }
	let text = message()
	fail(text.isEmpty ? "expectation failed" : text, file: file, line: line)
}

/// Fails unless the two values are equal. The failure text shows both values.
func expectEqual<T: Equatable>(
	_ actual: T, _ expected: T,
	_ message: @autoclosure () -> String = "",
	file: StaticString = #filePath, line: UInt = #line
) {
	guard actual != expected else { return }
	fail(mismatch(actual, expected, message()), file: file, line: line)
}

// Geometry is computed with floating point, so these compare within a tolerance.

/// Fails unless the two numbers differ by at most `accuracy` (NaN never matches).
func expectEqual<T: BinaryFloatingPoint>(
	_ actual: T, _ expected: T, accuracy: T,
	_ message: @autoclosure () -> String = "",
	file: StaticString = #filePath, line: UInt = #line
) {
	guard !(abs(actual - expected) <= accuracy) else { return }
	fail(mismatch(actual, expected, message()), file: file, line: line)
}

/// Fails unless both coordinates are within `accuracy`.
func expectEqual(
	_ actual: CGPoint, _ expected: CGPoint, accuracy: CGFloat,
	_ message: @autoclosure () -> String = "",
	file: StaticString = #filePath, line: UInt = #line
) {
	guard !(isClose(actual.x, expected.x, accuracy) && isClose(actual.y, expected.y, accuracy)) else { return }
	fail(mismatch(actual, expected, message()), file: file, line: line)
}

/// Fails unless width and height are within `accuracy`.
func expectEqual(
	_ actual: CGSize, _ expected: CGSize, accuracy: CGFloat,
	_ message: @autoclosure () -> String = "",
	file: StaticString = #filePath, line: UInt = #line
) {
	guard !(isClose(actual.width, expected.width, accuracy) && isClose(actual.height, expected.height, accuracy)) else { return }
	fail(mismatch(actual, expected, message()), file: file, line: line)
}

/// Fails unless origin and size are within `accuracy`.
func expectEqual(
	_ actual: CGRect, _ expected: CGRect, accuracy: CGFloat,
	_ message: @autoclosure () -> String = "",
	file: StaticString = #filePath, line: UInt = #line
) {
	guard !(isClose(actual.origin.x, expected.origin.x, accuracy)
		&& isClose(actual.origin.y, expected.origin.y, accuracy)
		&& isClose(actual.size.width, expected.size.width, accuracy)
		&& isClose(actual.size.height, expected.size.height, accuracy)) else { return }
	fail(mismatch(actual, expected, message()), file: file, line: line)
}

private func isClose(_ a: CGFloat, _ b: CGFloat, _ accuracy: CGFloat) -> Bool {
	abs(a - b) <= accuracy
}

private func mismatch<T>(_ actual: T, _ expected: T, _ message: String) -> String {
	let detail = "got \(String(reflecting: actual)), expected \(String(reflecting: expected))"
	return message.isEmpty ? detail : "\(message) (\(detail))"
}

// MARK: - Runner

/// Runs the suites, prints each failing test with its failures, then a one-line summary
/// ("<n> tests, <n> failures", counting recorded assertion failures and thrown errors).
/// Returns the process exit status: 0 when nothing failed, 1 otherwise.
///
/// Command-line arguments: `-v` prints each test before it runs, which shows which test was
/// running if the process crashes; any other argument keeps only the tests whose
/// "Suite / name" contains it, ignoring case.
func runTests(_ suites: [TestSuite]) -> Int32 {
	// Line-buffer stdout so output printed before a crash is not lost when it is piped.
	setvbuf(stdout, nil, _IOLBF, 0)

	let arguments = Array(CommandLine.arguments.dropFirst())
	let verbose = arguments.contains("-v")
	let filters = arguments.filter { $0 != "-v" }.map { $0.lowercased() }

	var testCount = 0
	var failureCount = 0
	for suite in suites {
		for test in suite.cases {
			let label = "\(suite.name) / \(test.name)"
			if !filters.isEmpty && !filters.contains(where: { label.lowercased().contains($0) }) {
				continue
			}
			if verbose { print("run  \(label)") }
			testCount += 1
			currentFailures = []
			do {
				try test.body()
			} catch {
				currentFailures.append("threw \(String(reflecting: error))")
			}
			guard !currentFailures.isEmpty else { continue }
			failureCount += currentFailures.count
			print("FAIL \(label)")
			for failure in currentFailures {
				print("  \(failure)")
			}
		}
	}
	print("\(testCount) tests, \(failureCount) failures")
	return failureCount == 0 ? 0 : 1
}
