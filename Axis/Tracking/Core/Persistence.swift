//
//  Persistence.swift
//  Axis
//
//  Workspaces and columns carried across a relaunch of Axis: a snapshot of the layout is saved,
//  and on the next launch a window with the same id and process gets its place back.
//
//  Placeholder: not implemented yet.
//

import Foundation
import CoreGraphics

/// Persistence bookkeeping (the loaded snapshot waiting to be matched, ...).
/// Fields added here need default values.
nonisolated struct PersistenceState: Equatable, Sendable {
	init() {}
}
