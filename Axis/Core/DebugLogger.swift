//
//  DebugLogger.swift
//  Axis
//
//  Created on 2026/02/02.
//

import Foundation

class DebugLogger {
    static let shared = DebugLogger()
    private let logFileURL: URL
    
    private init() {
        let fileManager = FileManager.default
        let homeURL = fileManager.homeDirectoryForCurrentUser
        logFileURL = homeURL.appendingPathComponent("axis_debug.log")
        
        // Create file if not exists
        if !fileManager.fileExists(atPath: logFileURL.path) {
            fileManager.createFile(atPath: logFileURL.path, contents: nil)
        }
    }
    
    func log(_ message: String) {
        let timestamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        let logMessage = "[\(timestamp)] \(message)\n"
        
        if let data = logMessage.data(using: .utf8) {
            if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            }
        }
    }
}

