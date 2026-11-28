//
//  PersistenceStore.swift
//  Axis
//
//  The saved layout file in Application Support: read once at launch, written in one step on a
//  background queue while Axis runs and synchronously when it quits. A file that cannot be used
//  comes back with its reason instead of an error, so a damaged file costs the restore and
//  nothing else. Whenever a read finds anything wrong with the file (it cannot be decoded, it is
//  inconsistent, or parts of it were left out), the file is first copied to
//  `<name>.bad-YYYYMMDD-HHMMSS` (local time), so the next save never destroys the only copy of
//  what was there. The newest `keptBadCopies` copies stay; older ones are deleted, and no other
//  file in the directory is touched.
//

import Foundation

nonisolated enum PersistenceStore {
	/// What the file at launch gave.
	nonisolated enum Loaded {
		case missing
		/// The usable part of the file, one note per part left out, and the file name of the copy
		/// kept of the original (nil when no copy was made or it failed).
		case snapshot(PersistenceSnapshot, dropped: [String], copiedAs: String?)
		/// The file exists but cannot be used; the reason is one line for the log. `copiedAs` is
		/// the file name of the kept copy of the original, nil when it could not be copied.
		case ignored(reason: String, copiedAs: String?)
	}

	/// Next to the file of the keyboard shortcuts.
	static let fileURL: URL = {
		let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
				.appendingPathComponent("Library/Application Support", isDirectory: true)
		return support.appendingPathComponent("Axis", isDirectory: true).appendingPathComponent("workspaces.json")
	}()

	/// Every write goes through this queue in order, so the write at quit lands after the ones
	/// queued before it.
	private static let queue = DispatchQueue(label: "com.noki.Axis.persistence", qos: .utility)

	// MARK: - Reading

	/// How many dated copies of a file with a problem stay.
	static let keptBadCopies = 5

	static func load(from url: URL = fileURL, now: Date = Date()) -> Loaded {
		guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
		let data: Data
		do {
			data = try Data(contentsOf: url)
		} catch {
			let copy = copyAside(url, at: now)
			return .ignored(reason: "unreadable: \(oneLine(error))" + copy.reasonSuffix, copiedAs: copy.name)
		}
		var snapshot: PersistenceSnapshot
		var dropped: [String]
		do {
			(snapshot, dropped) = try PersistenceSnapshot.decodeReporting(from: data)
		} catch {
			let copy = copyAside(url, at: now)
			return .ignored(reason: "damaged: \(oneLine(error))" + copy.reasonSuffix, copiedAs: copy.name)
		}
		dropped += snapshot.sanitize()
		if let problem = snapshot.validationProblem() {
			let copy = copyAside(url, at: now)
			return .ignored(reason: "inconsistent: \(problem)" + copy.reasonSuffix, copiedAs: copy.name)
		}
		guard !dropped.isEmpty else { return .snapshot(snapshot, dropped: [], copiedAs: nil) }
		let copy = copyAside(url, at: now)
		if copy.failure != nil {
			dropped.append("(copy to .bad failed: \(copy.failure ?? ""))")
		}
		return .snapshot(snapshot, dropped: dropped, copiedAs: copy.name)
	}

	/// The place the original goes when a read at `date` finds a problem. The stamp uses fixed
	/// digits so the name never depends on the region settings and sorts by time.
	static func badURL(for url: URL, at date: Date) -> URL {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.calendar = Calendar(identifier: .gregorian)
		formatter.timeZone = TimeZone.current
		formatter.dateFormat = "yyyyMMdd-HHmmss"
		return url.deletingLastPathComponent()
			.appendingPathComponent(url.lastPathComponent + ".bad-" + formatter.string(from: date))
	}

	/// The dated copies of the file next to it, oldest first. Only names that are exactly
	/// `<file name>.bad-` and a stamp of 8 digits, a dash and 6 digits count.
	static func badCopies(of url: URL) -> [URL] {
		let directory = url.deletingLastPathComponent()
		let prefix = url.lastPathComponent + ".bad-"
		let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
		return names
			.filter { name in
				guard name.hasPrefix(prefix) else { return false }
				let stamp = Array(name.dropFirst(prefix.count).utf8)
				guard stamp.count == 15, stamp[8] == UInt8(ascii: "-") else { return false }
				return stamp.enumerated().allSatisfy { $0.offset == 8 || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0.element) }
			}
			.sorted()
			.map { directory.appendingPathComponent($0) }
	}

	/// Copies the file to a dated copy (replacing one of the same second), then deletes the oldest
	/// copies beyond the cap. A failed copy never changes what the read returns; it only adds its
	/// one-line failure. A failed delete is ignored.
	private static func copyAside(_ url: URL, at date: Date) -> (name: String?, failure: String?, reasonSuffix: String) {
		let bad = badURL(for: url, at: date)
		let manager = FileManager.default
		do {
			if manager.fileExists(atPath: bad.path) {
				try manager.removeItem(at: bad)
			}
			try manager.copyItem(at: url, to: bad)
		} catch {
			let line = oneLine(error)
			return (nil, line, " (copy to .bad failed: \(line))")
		}
		let copies = badCopies(of: url)
		for old in copies.dropLast(keptBadCopies) {
			try? manager.removeItem(at: old)
		}
		return (bad.lastPathComponent, nil, "")
	}

	// MARK: - Writing

	/// Writes the snapshot on the background queue. `completion` runs on the main thread, with the
	/// error when the write failed.
	static func save(_ snapshot: PersistenceSnapshot, to url: URL = fileURL, completion: @escaping @MainActor (Error?) -> Void) {
		queue.async {
			var failure: Error?
			do {
				try write(snapshot, to: url)
			} catch {
				failure = error
			}
			let result = failure
			DispatchQueue.main.async {
				MainActor.assumeIsolated { completion(result) }
			}
		}
	}

	/// Writes the snapshot before returning, after the writes queued earlier.
	static func saveNow(_ snapshot: PersistenceSnapshot, to url: URL = fileURL) throws {
		try queue.sync {
			try write(snapshot, to: url)
		}
	}

	/// The file is written beside the old one and renamed over it, so a crash or a power cut leaves
	/// the old layout or the new one, never half of one.
	private static func write(_ snapshot: PersistenceSnapshot, to url: URL) throws {
		let data = try snapshot.encode()
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		try data.write(to: url, options: .atomic)
	}

	private static func oneLine(_ error: Error) -> String {
		var text: String
		if let decoding = error as? DecodingError {
			switch decoding {
			case .dataCorrupted(let context), .typeMismatch(_, let context), .valueNotFound(_, let context):
				text = context.debugDescription
			case .keyNotFound(let key, _):
				text = "missing key \(key.stringValue)"
			@unknown default:
				text = "\(decoding)"
			}
		} else {
			text = error.localizedDescription
		}
		text = text.replacingOccurrences(of: "\n", with: " ")
		return text.count > 160 ? String(text.prefix(160)) + "..." : text
	}
}
