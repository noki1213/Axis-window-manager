//
//  ConfigFileTests.swift
//  Axis core tests
//
//  Finding the file behind a symlink and noticing that a file changed.
//

import Foundation

/// A fresh directory with its symlinks resolved, removed after `body`
private func withTempDirectory(_ body: (URL) throws -> Void) throws {
	let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
	let directory = base.appendingPathComponent("axis-configfile-\(UUID().uuidString)")
	try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: directory) }
	try body(directory)
}

private func write(_ text: String, to url: URL) throws {
	try Data(text.utf8).write(to: url)
}

private func link(_ url: URL, to destination: String) throws {
	try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
}

let configFileTests: [TestCase] = resolvedTests + stampTests

// MARK: - resolved

private let resolvedTests: [TestCase] = [
	TestCase("a plain file resolves to itself") {
		try withTempDirectory { dir in
			let file = dir.appendingPathComponent("settings.json")
			try write("{}", to: file)
			expectEqual(ConfigFile.resolved(file).path, file.path)
		}
	},
	TestCase("a path that does not exist resolves to itself") {
		try withTempDirectory { dir in
			let file = dir.appendingPathComponent("missing.json")
			expectEqual(ConfigFile.resolved(file).path, file.path)
		}
	},
	TestCase("a symlink resolves to its destination") {
		try withTempDirectory { dir in
			let target = dir.appendingPathComponent("target.json")
			let alias = dir.appendingPathComponent("alias.json")
			try write("{}", to: target)
			try link(alias, to: target.path)
			expectEqual(ConfigFile.resolved(alias).path, target.path)
		}
	},
	TestCase("a chain of symlinks resolves to the last destination") {
		try withTempDirectory { dir in
			let target = dir.appendingPathComponent("target.json")
			let middle = dir.appendingPathComponent("middle.json")
			let first = dir.appendingPathComponent("first.json")
			try write("{}", to: target)
			try link(middle, to: target.path)
			try link(first, to: middle.path)
			expectEqual(ConfigFile.resolved(first).path, target.path)
		}
	},
	TestCase("a relative link target is read from the link's own directory") {
		try withTempDirectory { dir in
			let sub = dir.appendingPathComponent("sub")
			try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
			let target = dir.appendingPathComponent("target.json")
			try write("{}", to: target)
			let sibling = dir.appendingPathComponent("sibling.json")
			try link(sibling, to: "target.json")
			expectEqual(ConfigFile.resolved(sibling).path, target.path)
			let nested = sub.appendingPathComponent("nested.json")
			try link(nested, to: "../target.json")
			expectEqual(ConfigFile.resolved(nested).path, target.path)
		}
	},
	TestCase("a link into a symlinked directory resolves to the real path") {
		try withTempDirectory { dir in
			let real = dir.appendingPathComponent("real")
			try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
			let target = real.appendingPathComponent("target.json")
			try write("{}", to: target)
			let linkedDirectory = dir.appendingPathComponent("linked")
			try link(linkedDirectory, to: real.path)
			expectEqual(ConfigFile.resolved(linkedDirectory.appendingPathComponent("target.json")).path, target.path)
		}
	},
	TestCase("a link whose destination is missing still gives the destination") {
		try withTempDirectory { dir in
			let target = dir.appendingPathComponent("not-yet.json")
			let alias = dir.appendingPathComponent("alias.json")
			try link(alias, to: target.path)
			expectEqual(ConfigFile.resolved(alias).path, target.path)
			let relative = dir.appendingPathComponent("relative.json")
			try link(relative, to: "not-yet.json")
			expectEqual(ConfigFile.resolved(relative).path, target.path)
		}
	},
	TestCase("a chain that ends in a missing file gives the missing destination") {
		try withTempDirectory { dir in
			let target = dir.appendingPathComponent("not-yet.json")
			let middle = dir.appendingPathComponent("middle.json")
			let first = dir.appendingPathComponent("first.json")
			try link(middle, to: target.path)
			try link(first, to: middle.path)
			expectEqual(ConfigFile.resolved(first).path, target.path)
		}
	},
	TestCase("links that point at each other end in one of them") {
		try withTempDirectory { dir in
			let a = dir.appendingPathComponent("a.json")
			let b = dir.appendingPathComponent("b.json")
			try link(a, to: b.path)
			try link(b, to: a.path)
			let result = ConfigFile.resolved(a)
			expect([a.path, b.path].contains(result.path), "ended at \(result.path)")
		}
	},
	TestCase("a link to itself ends at itself") {
		try withTempDirectory { dir in
			let a = dir.appendingPathComponent("self.json")
			try link(a, to: a.path)
			expectEqual(ConfigFile.resolved(a).path, a.path)
		}
	},
]

// MARK: - Stamp

private let stampTests: [TestCase] = [
	TestCase("a file that does not exist has no stamp") {
		try withTempDirectory { dir in
			expect(ConfigFile.Stamp(of: dir.appendingPathComponent("missing.json")) == nil, "stamp")
		}
	},
	TestCase("a stamp holds the path, size and modification date") {
		try withTempDirectory { dir in
			let file = dir.appendingPathComponent("a.json")
			try write("12345", to: file)
			guard let stamp = ConfigFile.Stamp(of: file) else { return fail("no stamp") }
			expectEqual(stamp.path, file.path)
			expectEqual(stamp.size, 5)
			expect(abs(stamp.modified.timeIntervalSinceNow) < 60, "modified date is recent")
		}
	},
	TestCase("an unchanged file has an equal stamp") {
		try withTempDirectory { dir in
			let file = dir.appendingPathComponent("a.json")
			try write("{}", to: file)
			expectEqual(ConfigFile.Stamp(of: file), ConfigFile.Stamp(of: file))
		}
	},
	TestCase("a content change of the same size changes the stamp through the modification date") {
		try withTempDirectory { dir in
			let file = dir.appendingPathComponent("a.json")
			try write("{\"a\":1}", to: file)
			let before = ConfigFile.Stamp(of: file)
			try write("{\"a\":2}", to: file)
			try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 100)], ofItemAtPath: file.path)
			let after = ConfigFile.Stamp(of: file)
			expect(before != nil && after != nil, "stamps exist")
			expect(before != after, "stamp should change")
			expectEqual(before?.size, after?.size)
		}
	},
	TestCase("a content change of another size changes the stamp") {
		try withTempDirectory { dir in
			let file = dir.appendingPathComponent("a.json")
			try write("{}", to: file)
			try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: file.path)
			let before = ConfigFile.Stamp(of: file)
			try write("{\"a\": 1}", to: file)
			try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: file.path)
			let after = ConfigFile.Stamp(of: file)
			expect(before != after, "stamp should change")
			expect(before?.modified == after?.modified, "same date")
		}
	},
	TestCase("pointing the link at another file changes the stamp of the resolved file") {
		try withTempDirectory { dir in
			let first = dir.appendingPathComponent("first.json")
			let second = dir.appendingPathComponent("second.json")
			let alias = dir.appendingPathComponent("alias.json")
			try write("{}", to: first)
			try write("{}", to: second)
			let date = Date(timeIntervalSince1970: 1_000_000)
			try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: first.path)
			try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: second.path)
			try link(alias, to: first.path)
			let before = ConfigFile.Stamp(of: ConfigFile.resolved(alias))
			try FileManager.default.removeItem(at: alias)
			try link(alias, to: second.path)
			let after = ConfigFile.Stamp(of: ConfigFile.resolved(alias))
			expect(before != nil && after != nil, "stamps exist")
			expect(before != after, "stamp should change")
			expectEqual(before?.size, after?.size)
			expectEqual(before?.modified, after?.modified)
		}
	},
	TestCase("a file that appears or disappears changes the stamp") {
		try withTempDirectory { dir in
			let file = dir.appendingPathComponent("a.json")
			let missing = ConfigFile.Stamp(of: file)
			try write("{}", to: file)
			let present = ConfigFile.Stamp(of: file)
			expect(missing != present, "appearing")
			try FileManager.default.removeItem(at: file)
			expect(ConfigFile.Stamp(of: file) != present, "disappearing")
		}
	},
]
