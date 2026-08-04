//
//  PerfLog.swift
//  Axis
//
//  For pinning down why focus movement is slow / why Focus Follows Mouse doesn't work
//  A measurement-only helper with zero effect on behavior. Only when a threshold is exceeded
//  Logs with an [PERF] tag via NSLog.
//

import Foundation

/// A helper for measurement logging
enum PerfLog {

	/// Whether measurement logging is enabled ("perfLogEnabled" in UserDefaults, default true)
	static var enabled: Bool {
		if UserDefaults.standard.object(forKey: "perfLogEnabled") == nil {
			return true
		}
		return UserDefaults.standard.bool(forKey: "perfLogEnabled")
	}

	// MARK: - File output

	/// Where the log is written (since NSLog doesn't always show up in the log stream depending on the environment,
	/// Also write the same content to a file that's guaranteed to be readable)
	private static let logFileURL: URL = {
		let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("Logs", isDirectory: true)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir.appendingPathComponent("Axis-perf.log")
	}()

	/// Serialize file writes (so calls from multiple threads don't corrupt it)
	private static let fileQueue = DispatchQueue(label: "com.noki.Axis.perflog")

	/// Write one line with a timestamp
	private static func write(_ message: String) {
		let stamp = timeFormatter.string(from: Date())
		let line = "\(stamp) [PERF] \(message)\n"
		NSLog("[PERF] %@", message)
		fileQueue.async {
			guard let data = line.data(using: .utf8) else { return }
			if let handle = try? FileHandle(forWritingTo: logFileURL) {
				defer { try? handle.close() }
				try? handle.seekToEnd()
				try? handle.write(contentsOf: data)
			} else {
				try? data.write(to: logFileURL)
			}
		}
	}

	private static let timeFormatter: DateFormatter = {
		let f = DateFormatter()
		f.dateFormat = "HH:mm:ss.SSS"
		return f
	}()

	/// Measure the processing time and log only if it exceeds the threshold (seconds)
	/// - Parameters:
	///   - label: the label to print in the log. Pass a "parent/child"-style string to show the hierarchy
	///   - threshold: only log if this is exceeded (seconds). Defaults to 5ms
	///   - body: the work being measured
	@discardableResult
	static func measure<T>(_ label: String, threshold: Double = 0.005, _ body: () -> T) -> T {
		guard enabled else { return body() }
		let start = CFAbsoluteTimeGetCurrent()
		let result = body()
		let elapsed = CFAbsoluteTimeGetCurrent() - start
		if elapsed >= threshold {
			write(String(format: "%@: %.1fms", label, elapsed * 1000))
		}
		return result
	}

	/// The caller does the measurement; this just prints a line once the threshold check is done
	static func log(_ message: String) {
		guard enabled else { return }
		write(message)
	}

	/// Print a line using the same format specifiers as NSLog
	static func logf(_ format: String, _ args: CVarArg...) {
		guard enabled else { return }
		write(String(format: format, arguments: args))
	}

	// MARK: - End-to-end measurement from key press to focus confirmation

	/// The time a key-press-driven focus move started (recorded by HotkeyManager)
	private static var keyPressStart: CFAbsoluteTime?
	private static var keyPressLabel: String?

	/// Called at the moment a key press starts a focus move
	static func markKeyPressStart(_ label: String) {
		guard enabled else { return }
		keyPressStart = CFAbsoluteTimeGetCurrent()
		keyPressLabel = label
	}

	/// Call this once focus is confirmed (or once we give up confirming it).
	/// Print the elapsed time since markKeyPressStart as one line, then clear the record
	static func reportKeyPressToFocusConfirmed() {
		guard enabled, let start = keyPressStart else { return }
		let elapsed = CFAbsoluteTimeGetCurrent() - start
		write(String(format: "キー押下→フォーカス確定(%@): %.1fms", keyPressLabel ?? "?", elapsed * 1000))
		keyPressStart = nil
		keyPressLabel = nil
	}
}
