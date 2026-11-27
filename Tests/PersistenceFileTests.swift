//
//  PersistenceFileTests.swift
//  Axis core tests
//
//  The saved layout file: lenient decoding, sanitizing, the copy kept aside when a read finds
//  a problem, and the refusal to save a state that would not restore.
//

import Foundation
import CoreGraphics

/// A layout with ratios, a hidden window, a floating window and a remembered monitor.
private func richSnapshot() -> PersistenceSnapshot {
	var state = testState()
	let row = state.testSetRow(nonNegatives: 2, active: 0)
	state.testSetColumns(row[0], [[10, 11], [12]])
	state.testSetColumns(row[1], [[13]])
	state.workspaces[row[0]]?.widthRatios = [0.3, 0.7]
	state.workspaces[row[0]]?.rowRatios = [0: [0.4, 0.6], 1: [1.0]]
	state.testAddWindow(14, placement: .floating, workspace: row[0])
	state.records[14]?.floatingFrame = RelativeFrame(
		monitor: testKey("Main"), offset: CGPoint(x: 10, y: 20), size: CGSize(width: 300, height: 200))
	state.hiddenStack = [HiddenEntry(window: 13, minimizeConfirmed: true)]
	let gone = testKey("Gone")
	state.memory[gone] = MonitorMemory(
		key: gone, name: "Gone", order: [WorkspaceID(raw: 90)], negativeCount: 0, active: WorkspaceID(raw: 90),
		adoptedBy: nil, at: 1)
	return state.snapshot()
}

/// Runs `body` with a fresh temporary directory and removes it afterwards.
private func withTempDirectory(_ body: (URL) throws -> Void) throws {
	let dir = FileManager.default.temporaryDirectory
		.appendingPathComponent("axis-persistence-tests-\(UUID().uuidString)", isDirectory: true)
	try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: dir) }
	try body(dir)
}

/// The encoded snapshot with `edit` applied to its JSON object.
private func editedJSON(_ snapshot: PersistenceSnapshot, _ edit: (inout [String: Any]) -> Void) throws -> Data {
	var object = try JSONSerialization.jsonObject(with: snapshot.encode()) as! [String: Any]
	edit(&object)
	return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func editWorkspace(_ object: inout [String: Any], _ edit: (inout [String: Any]) -> Void) {
	var monitors = object["monitors"] as! [[String: Any]]
	var workspaces = monitors[0]["workspaces"] as! [[String: Any]]
	edit(&workspaces[0])
	monitors[0]["workspaces"] = workspaces
	object["monitors"] = monitors
}

private func exists(_ url: URL) -> Bool {
	FileManager.default.fileExists(atPath: url.path)
}

let persistenceFileTests: [TestCase] = [
	TestCase("encode decode encode gives identical bytes") {
		let snapshot = richSnapshot()
		let first = try snapshot.encode()
		let decoded = try PersistenceSnapshot.decodeReporting(from: first)
		expectEqual(decoded.snapshot, snapshot)
		expectEqual(decoded.dropped, [])
		expectEqual(try decoded.snapshot.encode(), first)
	},

	TestCase("missing optional keys decode with defaults") {
		let snapshot = richSnapshot()
		let data = try editedJSON(snapshot) { object in
			object["hiddenStack"] = nil
			object["memory"] = nil
			object["windows"] = [["id": 10, "pid": 100]]
			editWorkspace(&object) {
				$0["widthRatios"] = nil
				$0["rowRatios"] = nil
			}
		}
		let decoded = try PersistenceSnapshot.decodeReporting(from: data)
		expectEqual(decoded.dropped, ["hidden entry list missing", "remembered monitor list missing"])
		expectEqual(decoded.snapshot.hiddenStack, [])
		expectEqual(decoded.snapshot.memory, [])
		expectEqual(decoded.snapshot.windows, [PersistedWindow(id: 10, pid: 100)])
		expectEqual(decoded.snapshot.monitors[0].workspaces[0].widthRatios, nil)
		expectEqual(decoded.snapshot.monitors[0].workspaces[0].rowRatios, [:])
	},

	TestCase("wrong typed optional fields take defaults and are noted") {
		let snapshot = richSnapshot()
		let data = try editedJSON(snapshot) { object in
			object["hiddenStack"] = "oops"
			object["windows"] = [["id": 10, "pid": 100, "title": 5, "isFloating": "yes", "bundleID": ["x"]]]
		}
		let decoded = try PersistenceSnapshot.decodeReporting(from: data)
		expectEqual(decoded.snapshot.windows, [PersistedWindow(id: 10, pid: 100)])
		expectEqual(decoded.snapshot.hiddenStack, [])
		expectEqual(decoded.dropped.count, 4)
	},

	TestCase("one unreadable window record is skipped and noted") {
		let snapshot = richSnapshot()
		let data = try editedJSON(snapshot) { object in
			var windows = object["windows"] as! [Any]
			windows[2] = ["id": "not a number"]
			object["windows"] = windows
		}
		let decoded = try PersistenceSnapshot.decodeReporting(from: data)
		expectEqual(decoded.snapshot.windows.count, snapshot.windows.count - 1)
		expectEqual(decoded.snapshot.windows, snapshot.windows.enumerated().filter { $0.offset != 2 }.map(\.element))
		expectEqual(decoded.dropped, ["window record 3 unreadable"])
		expectEqual(decoded.snapshot.monitors, snapshot.monitors)
	},

	TestCase("unreadable ratios are dropped and the layout is kept") {
		let snapshot = richSnapshot()
		let data = try editedJSON(snapshot) { object in
			editWorkspace(&object) {
				$0["widthRatios"] = "bad"
				$0["rowRatios"] = ["a": 1]
			}
		}
		let decoded = try PersistenceSnapshot.decodeReporting(from: data)
		let workspace = decoded.snapshot.monitors[0].workspaces[0]
		expectEqual(workspace.widthRatios, nil)
		expectEqual(workspace.rowRatios, [:])
		expectEqual(workspace.columns, snapshot.monitors[0].workspaces[0].columns)
		expectEqual(decoded.dropped.count, 2)
	},

	TestCase("a monitor that cannot be read rejects the file") {
		let snapshot = richSnapshot()
		let data = try editedJSON(snapshot) { $0["monitors"] = [["key": 1]] }
		var threw = false
		do { _ = try PersistenceSnapshot.decode(from: data) } catch { threw = true }
		expect(threw, "a bad monitor element must throw")
		let noWindows = try editedJSON(snapshot) { $0["windows"] = nil }
		threw = false
		do { _ = try PersistenceSnapshot.decode(from: noWindows) } catch { threw = true }
		expect(threw, "missing windows must throw")
	},

	TestCase("sanitize leaves a clean snapshot unchanged") {
		var snapshot = richSnapshot()
		let before = snapshot
		expectEqual(snapshot.sanitize(), [])
		expectEqual(snapshot, before)
	},

	TestCase("sanitize drops width ratios that are not positive numbers") {
		var stale = richSnapshot()
		stale.monitors[0].workspaces[0].widthRatios = [1.0]
		expectEqual(stale.sanitize(), [], "a count that does not fit the columns is left to the restore")
		expectEqual(stale.monitors[0].workspaces[0].widthRatios, [1.0])
		for bad in [[0.5, 0.0], [0.5, -1], [0.5, .nan], [0.5, .infinity]] as [[CGFloat]] {
			var snapshot = richSnapshot()
			snapshot.monitors[0].workspaces[0].widthRatios = bad
			expectEqual(snapshot.sanitize().count, 1, "\(bad)")
			expectEqual(snapshot.monitors[0].workspaces[0].widthRatios, nil)
			expectEqual(snapshot.monitors[0].workspaces[0].rowRatios.count, 2)
		}
	},

	TestCase("sanitize drops row ratios that are not positive numbers") {
		var snapshot = richSnapshot()
		let stale: [Int: [CGFloat]] = [0: [0.4, 0.6], 1: [0.5, 0.5], 2: [1.0], -1: [1.0]]
		snapshot.monitors[0].workspaces[0].rowRatios = stale
		expectEqual(snapshot.sanitize(), [], "keys and counts that do not fit the columns are left to the restore")
		expectEqual(snapshot.monitors[0].workspaces[0].rowRatios, stale)
		snapshot.monitors[0].workspaces[0].rowRatios = [0: [0.4, 0], 1: [.nan]]
		expectEqual(snapshot.sanitize().count, 2)
		expectEqual(snapshot.monitors[0].workspaces[0].rowRatios, [:])
	},

	TestCase("sanitize keeps the first of a window saved twice") {
		var snapshot = richSnapshot()
		var copy = snapshot.windows[0]
		copy.title = "later"
		snapshot.windows.append(copy)
		let count = snapshot.windows.count - 1
		expectEqual(snapshot.sanitize().count, 1)
		expectEqual(snapshot.windows.count, count)
		expect(snapshot.windows[0].title != "later", "the first record stays")
	},

	TestCase("sanitize drops hidden entries that repeat or have no record") {
		var snapshot = richSnapshot()
		snapshot.hiddenStack = [HiddenEntry(window: 13), HiddenEntry(window: 13), HiddenEntry(window: 999), HiddenEntry(window: 12)]
		expectEqual(snapshot.sanitize().count, 2)
		expectEqual(snapshot.hiddenStack.map(\.window), [13, 12])
	},

	TestCase("sanitize drops unusable memory entries") {
		let ws = WorkspaceID(raw: 5)
		func entry(_ key: String, order: [WorkspaceID], negative: Int = 0, active: WorkspaceID = WorkspaceID(raw: 5)) -> PersistedMemory {
			PersistedMemory(key: testKey(key), name: key, order: order, negativeCount: negative, active: active)
		}
		var snapshot = richSnapshot()
		let liveKey = snapshot.monitors[0].key
		snapshot.memory = [
			entry("ok", order: [ws]),
			entry("empty", order: []),
			entry("strayActive", order: [ws], active: WorkspaceID(raw: 6)),
			entry("negative", order: [ws], negative: 1),
			entry("negativeBelow", order: [ws], negative: -1),
			entry("huge", order: [WorkspaceID(raw: Int.max)], active: WorkspaceID(raw: Int.max)),
			entry("ok", order: [ws]),
			PersistedMemory(key: liveKey, name: "live", order: [ws], negativeCount: 0, active: ws)
		]
		expectEqual(snapshot.sanitize().count, 6)
		expectEqual(snapshot.memory.map(\.key), [testKey("ok"), liveKey], "an entry for a saved monitor is left to the restore")
		expectEqual(snapshot.validationProblem(), nil)
	},

	TestCase("structural problems still reject the file") {
		var snapshot = richSnapshot()
		snapshot.monitors[0].workspaces[0].columns = [[]]
		_ = snapshot.sanitize()
		expect(snapshot.validationProblem() != nil, "an empty column stays a problem")
		var twice = richSnapshot()
		twice.monitors[0].workspaces[1].columns = [[10]]
		_ = twice.sanitize()
		expect(twice.validationProblem() != nil, "a window in two columns stays a problem")
	},

	TestCase("load of a damaged file is ignored and kept as an identical bad copy") {
		try withTempDirectory { dir in
			let url = dir.appendingPathComponent("workspaces.json")
			let bytes = Data("{\"monitors\": 3}".utf8)
			try bytes.write(to: url)
			guard case .ignored(let reason, let copied) = PersistenceStore.load(from: url) else {
				fail("expected .ignored")
				return
			}
			expect(reason.hasPrefix("damaged"), reason)
			expect(copied, "the copy is reported")
			expectEqual(try Data(contentsOf: PersistenceStore.badURL(for: url)), bytes)
			expectEqual(PersistenceStore.badURL(for: url).lastPathComponent, "workspaces.json.bad")
		}
	},

	TestCase("load of an inconsistent file is ignored and kept") {
		try withTempDirectory { dir in
			let url = dir.appendingPathComponent("workspaces.json")
			var snapshot = richSnapshot()
			snapshot.monitors[0].workspaces[0].columns = [[]]
			let bytes = try snapshot.encode()
			try bytes.write(to: url)
			guard case .ignored(let reason, _) = PersistenceStore.load(from: url) else {
				fail("expected .ignored")
				return
			}
			expect(reason.hasPrefix("inconsistent"), reason)
			expectEqual(try Data(contentsOf: PersistenceStore.badURL(for: url)), bytes)
		}
	},

	TestCase("load of a file with one bad record keeps the rest and a bad copy") {
		try withTempDirectory { dir in
			let url = dir.appendingPathComponent("workspaces.json")
			let snapshot = richSnapshot()
			let bytes = try editedJSON(snapshot) { object in
				var windows = object["windows"] as! [Any]
				windows[0] = 7
				object["windows"] = windows
			}
			try bytes.write(to: url)
			guard case .snapshot(let loaded, let dropped, let copied) = PersistenceStore.load(from: url) else {
				fail("expected .snapshot")
				return
			}
			expectEqual(loaded.windows.count, snapshot.windows.count - 1)
			expectEqual(dropped, ["window record 1 unreadable"])
			expect(copied, "the copy is reported")
			expectEqual(try Data(contentsOf: PersistenceStore.badURL(for: url)), bytes)
		}
	},

	TestCase("load of a file that needs sanitizing keeps a bad copy") {
		try withTempDirectory { dir in
			let url = dir.appendingPathComponent("workspaces.json")
			var snapshot = richSnapshot()
			snapshot.monitors[0].workspaces[0].widthRatios = snapshot.monitors[0].workspaces[0].columns.map { _ in 0 }
			try snapshot.encode().write(to: url)
			guard case .snapshot(let loaded, let dropped, _) = PersistenceStore.load(from: url) else {
				fail("expected .snapshot")
				return
			}
			expectEqual(dropped.count, 1)
			expectEqual(loaded.monitors[0].workspaces[0].widthRatios, nil)
			expect(exists(PersistenceStore.badURL(for: url)), "a bad copy exists")
		}
	},

	TestCase("load of a clean file makes no bad copy") {
		try withTempDirectory { dir in
			let url = dir.appendingPathComponent("workspaces.json")
			let snapshot = richSnapshot()
			try snapshot.encode().write(to: url)
			guard case .snapshot(let loaded, let dropped, let copied) = PersistenceStore.load(from: url) else {
				fail("expected .snapshot")
				return
			}
			expectEqual(loaded, snapshot)
			expectEqual(dropped, [])
			expect(!copied, "no copy")
			expect(!exists(PersistenceStore.badURL(for: url)), "no bad file")
		}
	},

	TestCase("load of a missing file is missing and makes no bad copy") {
		try withTempDirectory { dir in
			let url = dir.appendingPathComponent("workspaces.json")
			guard case .missing = PersistenceStore.load(from: url) else {
				fail("expected .missing")
				return
			}
			expect(!exists(PersistenceStore.badURL(for: url)), "no bad file")
		}
	},

	TestCase("an older bad copy is replaced") {
		try withTempDirectory { dir in
			let url = dir.appendingPathComponent("workspaces.json")
			try Data("old".utf8).write(to: PersistenceStore.badURL(for: url))
			let bytes = Data("garbage".utf8)
			try bytes.write(to: url)
			_ = PersistenceStore.load(from: url)
			expectEqual(try Data(contentsOf: PersistenceStore.badURL(for: url)), bytes)
		}
	},

	TestCase("a failed copy does not change the result") {
		try withTempDirectory { dir in
			let url = dir.appendingPathComponent("workspaces.json")
			try Data("garbage".utf8).write(to: url)
			// A directory in the way of the copy makes the replacement fail.
			let bad = PersistenceStore.badURL(for: url)
			try FileManager.default.createDirectory(at: bad.appendingPathComponent("inner"), withIntermediateDirectories: true)
			try Data("x".utf8).write(to: bad.appendingPathComponent("inner/file"))
			try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
			defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
			guard case .ignored(let reason, let copied) = PersistenceStore.load(from: url) else {
				fail("expected .ignored")
				return
			}
			expect(reason.hasPrefix("damaged"), reason)
			expect(!copied, "the copy failed")
			expect(reason.contains("copy to .bad failed"), reason)
		}
	},

	TestCase("a state that fails validation is not handed out and is logged once") {
		var state = testState()
		let row = state.testSetRow(nonNegatives: 2, active: 0)
		state.testSetColumns(row[0], [[10]])
		expect(state.persistenceTakeSnapshot() != nil, "a consistent layout is offered")
		let saved = state.persistenceState.lastSnapshot
		_ = state.drainLog()

		state.workspaces[row[1]]?.columns = [[10]]
		expectEqual(state.persistenceTakeSnapshot(), nil)
		expectEqual(state.persistenceTakeSnapshot(), nil)
		expectEqual(state.persistenceSnapshotForQuit(), nil)
		let lines = state.drainLog().map(\.message)
		expectEqual(lines.count, 1)
		expect(lines.first?.hasPrefix("persist: not saved (") == true, "\(lines)")
		expectEqual(state.persistenceState.lastSnapshot, saved)

		state.workspaces[row[1]]?.columns = []
		expect(state.persistenceSnapshotForQuit() != nil, "a repaired state is offered for the quit save")
	},
]
