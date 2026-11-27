//
//  PersistenceStore.swift
//  Axis
//
//  The saved layout file in Application Support: read once at launch, written in one step on a
//  background queue while Axis runs and synchronously when it quits. A file that cannot be used
//  comes back with its reason instead of an error, so a damaged file costs the restore and
//  nothing else. Whenever a read finds anything wrong with the file (it cannot be decoded, it is
//  inconsistent, or parts of it were left out), the file is first copied to `<name>.bad`, so the
//  next save never destroys the only copy of what was there.
//

import Foundation

nonisolated enum PersistenceStore {
	/// What the file at launch gave.
	nonisolated enum Loaded {
		case missing
		/// The usable part of the file, one note per part left out, and whether the original was
		/// copied aside.
		case snapshot(PersistenceSnapshot, dropped: [String], copiedAside: Bool)
		/// The file exists but cannot be used; the reason is one line for the log. `copiedAside`
		/// tells whether the original was kept as `.bad`.
		case ignored(reason: String, copiedAside: Bool)
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

	static func load(from url: URL = fileURL) -> Loaded {
		guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
		let data: Data
		do {
			data = try Data(contentsOf: url)
		} catch {
			let copy = copyAside(url)
			return .ignored(reason: "unreadable: \(oneLine(error))" + copy.reasonSuffix, copiedAside: copy.failure == nil)
		}
		var snapshot: PersistenceSnapshot
		var dropped: [String]
		do {
			(snapshot, dropped) = try PersistenceSnapshot.decodeReporting(from: data)
		} catch {
			let copy = copyAside(url)
			return .ignored(reason: "damaged: \(oneLine(error))" + copy.reasonSuffix, copiedAside: copy.failure == nil)
		}
		dropped += snapshot.sanitize()
		if let problem = snapshot.validationProblem() {
			let copy = copyAside(url)
			return .ignored(reason: "inconsistent: \(problem)" + copy.reasonSuffix, copiedAside: copy.failure == nil)
		}
		guard !dropped.isEmpty else { return .snapshot(snapshot, dropped: [], copiedAside: false) }
		let copy = copyAside(url)
		if copy.failure != nil {
			dropped.append("(copy to .bad failed: \(copy.failure ?? ""))")
		}
		return .snapshot(snapshot, dropped: dropped, copiedAside: copy.failure == nil)
	}

	/// The place the original goes when a read finds a problem.
	static func badURL(for url: URL) -> URL {
		url.appendingPathExtension("bad")
	}

	/// Copies the file to `.bad`, replacing an older copy. A failed copy never changes what the
	/// read returns; it only adds its one-line failure.
	private static func copyAside(_ url: URL) -> (failure: String?, reasonSuffix: String) {
		let bad = badURL(for: url)
		let manager = FileManager.default
		do {
			if manager.fileExists(atPath: bad.path) {
				try manager.removeItem(at: bad)
			}
			try manager.copyItem(at: url, to: bad)
			return (nil, "")
		} catch {
			let line = oneLine(error)
			return (line, " (copy to .bad failed: \(line))")
		}
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
