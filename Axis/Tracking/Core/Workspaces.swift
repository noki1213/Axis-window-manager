//
//  Workspaces.swift
//  Axis
//
//  Workspace rows and numbers, compaction of empty workspaces, and the column operations
//  (move, step, reset, reservation insert, size ratios) on window ids.
//
//  Every column operation works on the drawable view of a workspace (`layoutColumns`): the
//  columns without windows that take no slot right now (on another Space, gone from the window
//  server). Those keep their entry in the columns, so a transient gap does not reshuffle the
//  layout, but a key press never moves a window "past" an invisible one. After an operation they
//  are put back next to the neighbours they had.
//

import Foundation
import CoreGraphics

// MARK: - Pure column helpers

nonisolated enum ColumnView {
	/// Where a window goes back into a column row.
	nonisolated enum Insertion: Equatable, Sendable {
		/// Into an existing column at a row.
		case intoColumn(column: Int, row: Int)
		/// As a new column at an index.
		case newColumn(index: Int)
	}

	/// The columns keeping only ids in `drawable`; columns left empty are dropped.
	static func drawable(_ columns: [[WindowID]], keeping drawable: Set<WindowID>) -> [[WindowID]] {
		columns.map { $0.filter { drawable.contains($0) } }.filter { !$0.isEmpty }
	}

	static func position(of id: WindowID, in columns: [[WindowID]]) -> (column: Int, row: Int)? {
		for (column, ids) in columns.enumerated() {
			if let row = ids.firstIndex(of: id) {
				return (column, row)
			}
		}
		return nil
	}

	/// The columns without `id`; a column it leaves empty is dropped.
	static func removing(_ id: WindowID, from columns: [[WindowID]]) -> [[WindowID]] {
		columns.map { $0.filter { $0 != id } }.filter { !$0.isEmpty }
	}

	/// The neighbours of `id`: above and below in its column, and the first window of the columns
	/// on either side. Nil when `id` is not in the columns.
	static func slotMemory(of id: WindowID, in columns: [[WindowID]], workspace: WorkspaceID) -> SlotMemory? {
		guard let (column, row) = position(of: id, in: columns) else { return nil }
		let ids = columns[column]
		return SlotMemory(
			above: row > 0 ? ids[row - 1] : nil,
			below: row < ids.count - 1 ? ids[row + 1] : nil,
			leftRep: column > 0 ? columns[column - 1].first : nil,
			rightRep: column < columns.count - 1 ? columns[column + 1].first : nil,
			workspace: workspace)
	}

	/// Where a window with `memory` goes back: next to its above or below neighbour when that is
	/// still there, else as a new column beside the first window of its left or right column.
	/// Nil when none of the neighbours is in the columns any more.
	static func slotInsertion(for memory: SlotMemory, in columns: [[WindowID]]) -> Insertion? {
		if let above = memory.above, let at = position(of: above, in: columns) {
			return .intoColumn(column: at.column, row: at.row + 1)
		}
		if let below = memory.below, let at = position(of: below, in: columns) {
			return .intoColumn(column: at.column, row: at.row)
		}
		if let left = memory.leftRep, let at = position(of: left, in: columns) {
			return .newColumn(index: at.column + 1)
		}
		if let right = memory.rightRep, let at = position(of: right, in: columns) {
			return .newColumn(index: at.column)
		}
		return nil
	}

	/// The columns with `id` inserted; out-of-range positions are clamped.
	static func inserting(_ id: WindowID, _ insertion: Insertion, into columns: [[WindowID]]) -> [[WindowID]] {
		var result = columns
		switch insertion {
		case .intoColumn(let column, let row):
			if result.indices.contains(column) {
				result[column].insert(id, at: min(max(row, 0), result[column].count))
			} else {
				result.append([id])
			}
		case .newColumn(let index):
			result.insert([id], at: min(max(index, 0), result.count))
		}
		return result
	}

	/// Puts the ids of `original` that are not in `drawable` back into `edited` (an edited copy of
	/// the drawable view): right after the entry above them in their column, else at the front of
	/// the column now holding the entries below them, else as their own column after the column
	/// holding their left neighbour column's entries (else first). With `edited` unchanged this
	/// restores `original` exactly.
	static func merge(original: [[WindowID]], edited: [[WindowID]], drawable: Set<WindowID>) -> [[WindowID]] {
		var result = edited
		var placed = Set(edited.joined())
		for (columnIndex, column) in original.enumerated() {
			for (rowIndex, id) in column.enumerated() where !drawable.contains(id) && !placed.contains(id) {
				if let anchor = column[..<rowIndex].last(where: { placed.contains($0) }),
					let at = position(of: anchor, in: result) {
					result[at.column].insert(id, at: at.row + 1)
				} else if let anchor = column[(rowIndex + 1)...].first(where: { placed.contains($0) }),
					let at = position(of: anchor, in: result) {
					result[at.column].insert(id, at: 0)
				} else {
					var index = 0
					for previous in original[..<columnIndex].reversed() {
						let held = previous.compactMap { placed.contains($0) ? position(of: $0, in: result)?.column : nil }
						if let last = held.max() {
							index = last + 1
							break
						}
					}
					result.insert([id], at: index)
				}
				placed.insert(id)
			}
		}
		return result
	}

	static func evenRatios(_ count: Int) -> [CGFloat] {
		guard count > 0 else { return [] }
		return Array(repeating: 1.0 / CGFloat(count), count: count)
	}

	/// Horizontal centres of the column slots on a visible area, from the width ratios when they
	/// match the column count, else even widths. Used to place a new column by a window's centre
	/// without depending on where parked windows currently are.
	static func columnCentres(count: Int, widthRatios: [CGFloat]?, visibleFrame: CGRect, config: LayoutConfig) -> [CGFloat] {
		guard count > 0 else { return [] }
		let available = visibleFrame.width - config.padding * 2 - config.gap * CGFloat(count - 1)
		let ratios = widthRatios?.count == count ? widthRatios! : evenRatios(count)
		var x = visibleFrame.minX + config.padding
		var centres: [CGFloat] = []
		for ratio in ratios {
			let width = available * ratio
			centres.append(x + width / 2)
			x += width + config.gap
		}
		return centres
	}
}

// MARK: - Monitors and workspace rows

nonisolated extension TrackingState {
	mutating func makeWorkspaceID() -> WorkspaceID {
		defer { nextWorkspaceRaw += 1 }
		return WorkspaceID(raw: nextWorkspaceRaw)
	}

	/// Creates an empty workspace on `monitor`. `index` positions it within its side (nil = the
	/// outer end of that side: the far left for negative, the far right for non-negative).
	@discardableResult
	mutating func createWorkspace(on monitor: MonitorKey, side: Side, at index: Int? = nil) -> WorkspaceID? {
		guard var state = monitors[monitor] else { return nil }
		let id = makeWorkspaceID()
		workspaces[id] = Workspace(id: id, host: monitor, origin: monitor, side: side)
		switch side {
		case .negative:
			state.order.insert(id, at: min(max(index ?? 0, 0), state.negativeCount))
			state.negativeCount += 1
		case .nonNegative:
			state.order.insert(id, at: min(max(index ?? state.order.count, state.negativeCount), state.order.count))
		}
		monitors[monitor] = state
		return id
	}

	/// Connects a monitor with one empty home workspace, or refreshes its geometry when it is
	/// already connected. Topology reconciliation decides when a monitor is new.
	@discardableResult
	mutating func addMonitor(_ display: DisplayFacts) -> MonitorKey {
		if monitors[display.key] != nil {
			updateMonitor(display)
			return display.key
		}
		let id = makeWorkspaceID()
		workspaces[id] = Workspace(id: id, host: display.key)
		monitors[display.key] = MonitorState(
			key: display.key, displayID: display.displayID, name: display.name,
			frame: display.frame, visibleFrame: display.visibleFrame, isPrimary: display.isPrimary,
			order: [id], negativeCount: 0, active: id)
		if !monitorOrder.contains(display.key) {
			monitorOrder.append(display.key)
		}
		return display.key
	}

	/// Copies a connected monitor's identity and geometry from fresh display facts.
	mutating func updateMonitor(_ display: DisplayFacts) {
		guard var state = monitors[display.key] else { return }
		state.displayID = display.displayID
		state.name = display.name
		state.frame = display.frame
		state.visibleFrame = display.visibleFrame
		state.isPrimary = display.isPrimary
		monitors[display.key] = state
	}

	/// The first empty workspace past the last one in use (non-empty or active) on the
	/// non-negative side: a trailing empty workspace is reused, else one is appended.
	@discardableResult
	mutating func createWorkspaceAtEnd(on monitor: MonitorKey) -> WorkspaceID? {
		guard let state = monitors[monitor] else { return nil }
		let counts = memberCounts()
		let lastInUse = state.order.indices.last { index in
			index >= state.negativeCount
				&& (counts[state.order[index], default: 0] > 0 || state.order[index] == state.active)
		}
		let candidate = (lastInUse ?? state.negativeCount - 1) + 1
		if candidate < state.order.count {
			return state.order[candidate]
		}
		return createWorkspace(on: monitor, side: .nonNegative)
	}

	/// The workspace a target names on `monitor`. Next past the right end and previous past the
	/// left end create one there (non-negative and negative respectively).
	mutating func resolveWorkspace(_ target: WorkspaceTarget, on monitor: MonitorKey) -> WorkspaceID? {
		guard let state = monitors[monitor], let index = state.order.firstIndex(of: state.active) else { return nil }
		switch target {
		case .id(let workspace):
			return state.order.contains(workspace) ? workspace : nil
		case .number(let number):
			return self.workspace(number: number, on: monitor)
		case .next:
			return index + 1 < state.order.count ? state.order[index + 1] : createWorkspace(on: monitor, side: .nonNegative)
		case .prev:
			return index > 0 ? state.order[index - 1] : createWorkspace(on: monitor, side: .negative)
		}
	}

	/// Makes a workspace active on `monitor`, ending a Zen session there, and drops the empty
	/// workspaces left behind (keeping the new active one even when it is empty). Returns the new
	/// active workspace, nil when nothing changed.
	@discardableResult
	mutating func switchWorkspace(on monitor: MonitorKey, to target: WorkspaceTarget) -> WorkspaceID? {
		guard let current = monitors[monitor]?.active,
			let destination = resolveWorkspace(target, on: monitor),
			destination != current
		else { return nil }
		if zen?.monitor == monitor {
			zenExit(reason: .workspaceSwitched)
		}
		monitors[monitor]?.active = destination
		emit(.activeChanged(monitor: monitor, from: current, to: destination, cause: .command))
		compact(monitor, keepingActive: true)
		return destination
	}

	/// Drops `monitor`'s empty workspaces (no members of any placement). Kept anyway: the active
	/// workspace when `keepingActive`, the Zen workspace, and the home workspace (number 0) when no
	/// non-negative workspace has members, so a row is never empty. A deleted active workspace
	/// hands over to its outer neighbour (the one that slides into its number), else its inner
	/// neighbour.
	mutating func compact(_ monitor: MonitorKey, keepingActive: Bool) {
		guard var state = monitors[monitor] else { return }
		let counts = memberCounts()
		let keptActive = keepingActive ? state.active : nil
		let zenWorkspace = zen?.monitor == monitor ? zen?.workspace : nil
		func hasMembers(_ workspace: WorkspaceID) -> Bool {
			counts[workspace, default: 0] > 0
		}
		func isKept(_ workspace: WorkspaceID) -> Bool {
			hasMembers(workspace) || workspace == keptActive || workspace == zenWorkspace
		}

		let negatives = Array(state.order.prefix(state.negativeCount))
		let nonNegatives = Array(state.order.dropFirst(state.negativeCount))
		let keptNegatives = negatives.filter(isKept)
		let nonNegativeHasMembers = nonNegatives.contains(where: hasMembers)
		var keptNonNegatives = nonNegatives.enumerated()
			.filter { index, workspace in isKept(workspace) || (index == 0 && !nonNegativeHasMembers) }
			.map { $0.element }
		if keptNonNegatives.isEmpty {
			if let home = nonNegatives.first {
				keptNonNegatives = [home]
			} else {
				let home = makeWorkspaceID()
				workspaces[home] = Workspace(id: home, host: monitor)
				keptNonNegatives = [home]
			}
		}
		let newOrder = keptNegatives + keptNonNegatives
		guard newOrder != state.order else { return }

		let kept = Set(newOrder)
		let dropped = state.order.filter { !kept.contains($0) }
		let droppedText = dropped.map { describeWorkspace($0) }.joined(separator: ", ")
		let previousActive = state.active
		if !kept.contains(previousActive), let index = state.order.firstIndex(of: previousActive) {
			let outer: WorkspaceID?
			let inner: WorkspaceID?
			if index < state.negativeCount {
				outer = state.order[..<index].last(where: kept.contains)
				inner = state.order[(index + 1)...].first(where: kept.contains)
			} else {
				outer = state.order[(index + 1)...].first(where: kept.contains)
				inner = state.order[..<index].last(where: kept.contains)
			}
			state.active = outer ?? inner ?? newOrder[keptNegatives.count]
		}
		state.order = newOrder
		state.negativeCount = keptNegatives.count
		if let before = state.activeBeforeHosting, !kept.contains(before) {
			state.activeBeforeHosting = nil
		}
		monitors[monitor] = state
		for workspace in dropped {
			workspaces[workspace] = nil
		}

		var line = "workspace: dropped empty \(droppedText) on \(describeMonitor(monitor))"
		if state.active != previousActive {
			line += "; active -> \(describeWorkspace(state.active))"
			emit(.activeChanged(monitor: monitor, from: previousActive, to: state.active, cause: .compaction))
		}
		log(line)
	}
}

// MARK: - Drawable view

nonisolated extension TrackingState {
	func drawableIDs(in columns: [[WindowID]]) -> Set<WindowID> {
		Set(columns.joined().filter { isDrawable($0) })
	}

	/// The columns of `workspace` that the layout and every column operation see: only windows
	/// that take a slot (see `isDrawable`).
	func layoutColumns(_ workspace: WorkspaceID) -> [[WindowID]] {
		guard let columns = workspaces[workspace]?.columns else { return [] }
		return ColumnView.drawable(columns, keeping: drawableIDs(in: columns))
	}

	/// The drawable columns with the stored ratios, as the layout math takes them.
	func layoutInput(_ workspace: WorkspaceID) -> LayoutInput? {
		guard let stored = workspaces[workspace] else { return nil }
		return LayoutInput(columns: layoutColumns(workspace), widthRatios: stored.widthRatios, rowRatios: stored.rowRatios)
	}

	/// Runs `body` on the drawable view of `workspace` and writes the edited view back with the
	/// non-drawable entries re-inserted next to their neighbours. `body` may also change the
	/// workspace's ratios (indexed like the drawable view); its `columns` are overwritten.
	@discardableResult
	mutating func editLayoutColumns<R>(of workspace: WorkspaceID, _ body: (inout [[WindowID]], inout Workspace) -> R) -> R? {
		guard var stored = workspaces[workspace] else { return nil }
		let original = stored.columns
		let drawable = drawableIDs(in: original)
		var view = ColumnView.drawable(original, keeping: drawable)
		let result = body(&view, &stored)
		stored.columns = ColumnView.merge(original: original, edited: view, drawable: drawable)
		workspaces[workspace] = stored
		return result
	}
}

// MARK: - Column membership

nonisolated extension TrackingState {
	/// Takes `id` out of the columns it is in and returns its neighbours there. Nil when it was in
	/// no columns. Ratios are left to the layout, which resets them when the counts change.
	@discardableResult
	mutating func removeFromColumns(_ id: WindowID) -> SlotMemory? {
		var candidates: [WorkspaceID] = []
		if let own = records[id]?.workspace {
			candidates.append(own)
		}
		candidates += workspaces.keys.sorted().filter { !candidates.contains($0) }
		for workspaceID in candidates {
			guard var stored = workspaces[workspaceID],
				let memory = ColumnView.slotMemory(of: id, in: stored.columns, workspace: workspaceID)
			else { continue }
			stored.columns = ColumnView.removing(id, from: stored.columns)
			workspaces[workspaceID] = stored
			return memory
		}
		return nil
	}

	/// Puts `id` back into `workspace` next to the neighbours it remembers. Returns false, changing
	/// nothing, when none of them is in the columns any more; the caller then places it another
	/// way (by its centre, or at the end).
	@discardableResult
	mutating func insertBySlotMemory(_ id: WindowID, memory: SlotMemory, into workspace: WorkspaceID) -> Bool {
		guard let columns = workspaces[workspace]?.columns,
			let insertion = ColumnView.slotInsertion(for: memory, in: ColumnView.removing(id, from: columns))
		else { return false }
		removeFromColumns(id)
		guard let current = workspaces[workspace]?.columns else { return false }
		workspaces[workspace]?.columns = ColumnView.inserting(id, insertion, into: current)
		return true
	}

	/// Adds `id` as its own column, before the first drawable column whose slot centre lies right
	/// of `midX` (the window's horizontal centre), else at the right end.
	mutating func insertByMidX(_ id: WindowID, midX: CGFloat, into workspace: WorkspaceID) {
		guard let host = workspaces[workspace]?.host else { return }
		removeFromColumns(id)
		let visibleFrame = monitors[host]?.visibleFrame ?? .zero
		let config = self.config
		editLayoutColumns(of: workspace) { columns, stored in
			let centres = ColumnView.columnCentres(count: columns.count, widthRatios: stored.widthRatios,
				visibleFrame: visibleFrame, config: config)
			let index = centres.firstIndex { midX < $0 } ?? columns.count
			columns.insert([id], at: index)
		}
	}

	/// Adds `id` where a placement reservation points (column index in the drawable view, clamped).
	/// A float reservation adds nothing.
	mutating func insertReserved(_ id: WindowID, kind: ReservationKind, columnIndex: Int, into workspace: WorkspaceID) {
		guard kind != .float else { return }
		removeFromColumns(id)
		editLayoutColumns(of: workspace) { columns, _ in
			switch kind {
			case .aboveInColumn, .belowInColumn:
				guard !columns.isEmpty else {
					columns = [[id]]
					return
				}
				let index = min(max(columnIndex, 0), columns.count - 1)
				if kind == .aboveInColumn {
					columns[index].insert(id, at: 0)
				} else {
					columns[index].append(id)
				}
			case .newColumnLeft:
				columns.insert([id], at: min(max(columnIndex, 0), columns.count))
			case .newColumnRight:
				columns.insert([id], at: min(max(columnIndex + 1, 0), columns.count))
			case .float:
				break
			}
		}
	}
}

// MARK: - Column operations

nonisolated extension TrackingState {
	/// Moves a tiled window one step: left/right swap whole columns (and their ratios), up/down swap
	/// it with its neighbour in the column (and their row ratios). At the edge of the row or column
	/// it moves to the adjacent monitor's active workspace: to the right end when moving left, to
	/// the left end otherwise.
	@discardableResult
	mutating func moveWindow(_ id: WindowID, _ direction: MoveDirection) -> ColumnMoveResult {
		guard let workspace = records[id]?.workspace, let host = workspaces[workspace]?.host else { return .none }
		enum Outcome { case moved, atEdge, absent }
		let outcome = editLayoutColumns(of: workspace) { columns, stored -> Outcome in
			guard let (column, row) = ColumnView.position(of: id, in: columns) else { return .absent }
			switch direction {
			case .left, .right:
				let other = direction == .left ? column - 1 : column + 1
				guard columns.indices.contains(other) else { return .atEdge }
				columns.swapAt(column, other)
				if var ratios = stored.widthRatios, ratios.count == columns.count {
					ratios.swapAt(column, other)
					stored.widthRatios = ratios
				}
				let rows = stored.rowRatios[column]
				stored.rowRatios[column] = stored.rowRatios[other]
				stored.rowRatios[other] = rows
			case .up, .down:
				let other = direction == .up ? row - 1 : row + 1
				guard columns[column].indices.contains(other) else { return .atEdge }
				columns[column].swapAt(row, other)
				if var ratios = stored.rowRatios[column], ratios.count == columns[column].count {
					ratios.swapAt(row, other)
					stored.rowRatios[column] = ratios
				}
			}
			return .moved
		} ?? .absent

		switch outcome {
		case .moved:
			return .moved
		case .absent:
			return .none
		case .atEdge:
			guard let neighbour = adjacentMonitor(of: host, toward: direction) else { return .none }
			let edge: ColumnEdge = direction == .left ? .right : .left
			return moveWindowToMonitor(id, to: neighbour, edge: edge) ? .movedToMonitor(neighbour) : .none
		}
	}

	/// Merges or splits (consume/expel): a window sharing its column leaves it for a new column on
	/// that side; a window alone in its column joins the bottom of the neighbouring column. Only
	/// left and right; returns whether anything changed.
	@discardableResult
	mutating func stepMove(_ id: WindowID, _ direction: MoveDirection) -> Bool {
		guard direction == .left || direction == .right, let workspace = records[id]?.workspace else { return false }
		return editLayoutColumns(of: workspace) { columns, _ -> Bool in
			guard let (column, row) = ColumnView.position(of: id, in: columns) else { return false }
			if columns[column].count > 1 {
				columns[column].remove(at: row)
				columns.insert([id], at: direction == .left ? column : column + 1)
			} else {
				let target = direction == .left ? column - 1 : column + 1
				guard columns.indices.contains(target) else { return false }
				columns.remove(at: column)
				columns[direction == .left ? target : target - 1].append(id)
			}
			return true
		} ?? false
	}

	/// Gives every drawable window of `workspace` its own column, in reading order. Ends Zen, whose
	/// parked windows would otherwise be laid out underneath it.
	mutating func resetToSingleColumns(_ workspace: WorkspaceID) {
		if zen != nil {
			zenExit(reason: .layoutReset)
		}
		editLayoutColumns(of: workspace) { columns, _ in
			columns = columns.joined().map { [$0] }
		}
	}

	/// The first connected monitor that lies fully on that side of `monitor` and overlaps it
	/// across the other axis (top-left coordinates: "up" is smaller y).
	func adjacentMonitor(of monitor: MonitorKey, toward direction: MoveDirection) -> MonitorKey? {
		guard let current = monitors[monitor]?.frame else { return nil }
		return monitorOrder.first { key in
			guard key != monitor, let other = monitors[key]?.frame else { return false }
			let overlapsVertically = other.minY < current.maxY && other.maxY > current.minY
			let overlapsHorizontally = other.minX < current.maxX && other.maxX > current.minX
			switch direction {
			case .left: return other.maxX <= current.minX + 1 && overlapsVertically
			case .right: return other.minX >= current.maxX - 1 && overlapsVertically
			case .up: return other.maxY <= current.minY + 1 && overlapsHorizontally
			case .down: return other.minY >= current.maxY - 1 && overlapsHorizontally
			}
		}
	}

	/// Moves a tiled or floating window into the active workspace of another monitor: a tiled one
	/// as a new column at that end of the drawable view, a floating one at the same offset in the
	/// new monitor's visible area. The empty workspace left behind stays until the next switch
	/// there, so the monitor it left does not jump to another workspace.
	@discardableResult
	mutating func moveWindowToMonitor(_ id: WindowID, to monitor: MonitorKey, edge: ColumnEdge) -> Bool {
		guard var record = records[id], record.placement != .unmanaged,
			let destination = monitors[monitor]?.active,
			record.workspace != destination
		else { return false }
		let sourceHost = record.workspace.flatMap { workspaces[$0]?.host }
		removeFromColumns(id)
		record.workspace = destination
		if record.placement == .floating, let frame = record.floatingFrame {
			record.floatingFrame = RelativeFrame(monitor: monitor, offset: frame.offset, size: frame.size)
			record.pendingFloatRestore = true
		}
		records[id] = record
		if record.placement == .tiled && record.visibility.keepsSlot {
			editLayoutColumns(of: destination) { columns, _ in
				switch edge {
				case .left: columns.insert([id], at: 0)
				case .right: columns.append([id])
				}
			}
		}
		if let sourceHost, sourceHost != monitor {
			compact(sourceHost, keepingActive: true)
		}
		return true
	}

	/// Moves a window to another workspace of `monitor` (created past an end for next/previous)
	/// and switches there, so the window stays on screen. A tiled window becomes a new column placed
	/// by its centre; an unmanaged one becomes a floating member. Returns the destination.
	@discardableResult
	mutating func moveWindowToWorkspace(_ id: WindowID, on monitor: MonitorKey, to target: WorkspaceTarget) -> WorkspaceID? {
		guard records[id] != nil, let destination = resolveWorkspace(target, on: monitor),
			records[id]?.workspace != destination
		else { return nil }
		let sourceHost = records[id]?.workspace.flatMap { workspaces[$0]?.host }
		removeFromColumns(id)
		guard var record = records[id] else { return nil }
		record.workspace = destination
		if record.placement == .unmanaged {
			record.placement = .floating
			if record.floatingFrame == nil, let frame = record.observed.frame, let visibleFrame = monitors[monitor]?.visibleFrame {
				record.floatingFrame = RelativeFrame(frame: frame, monitor: monitor, visibleFrame: visibleFrame)
			}
		}
		records[id] = record
		if record.placement == .tiled && record.visibility.keepsSlot {
			insertByMidX(id, midX: record.observed.frame?.midX ?? .greatestFiniteMagnitude, into: destination)
		}
		switchWorkspace(on: monitor, to: .id(destination))
		if let sourceHost, sourceHost != monitor {
			compact(sourceHost, keepingActive: true)
		}
		return destination
	}

	/// Tiled -> floating: leaves the columns and is centred on its monitor at its current size.
	/// Floating -> tiled: joins the columns as a new column placed by its centre. Unmanaged: only
	/// centred (it has no workspace to tile in). Returns the new placement.
	@discardableResult
	mutating func toggleFloat(_ id: WindowID) -> Placement? {
		guard var record = records[id] else { return nil }
		switch record.placement {
		case .tiled:
			removeFromColumns(id)
			record.placement = .floating
			centre(&record)
			records[id] = record
		case .floating:
			record.placement = .tiled
			records[id] = record
			if record.visibility.keepsSlot, let workspace = record.workspace {
				insertByMidX(id, midX: record.observed.frame?.midX ?? .greatestFiniteMagnitude, into: workspace)
			}
		case .unmanaged:
			centre(&record)
			records[id] = record
		}
		return record.placement
	}

	/// Sets a centred floatingFrame on the window's monitor (its workspace host, else the monitor
	/// holding its frame) and asks for it to be applied once.
	private func centre(_ record: inout WindowRecord) {
		guard let frame = record.observed.frame else { return }
		let monitor = record.workspace.flatMap { workspaces[$0]?.host } ?? monitorKey(for: frame)
		guard let monitor, let visibleFrame = monitors[monitor]?.visibleFrame else { return }
		record.floatingFrame = RelativeFrame.centred(size: frame.size, monitor: monitor, visibleFrame: visibleFrame)
		record.pendingFloatRestore = true
	}
}

// MARK: - Size ratios

nonisolated extension TrackingState {
	/// The smallest share of the width or height a column or row can be resized to.
	static let minimumRatio: CGFloat = 0.1
	/// How much one resize step changes a column's width share.
	static let resizeStep: CGFloat = 0.05

	/// Moves the boundary between drawable column `columnIndex` and the next one by `delta` points
	/// (positive = right). Refused when either column would drop below the minimum share.
	@discardableResult
	mutating func resizeColumnGap(in workspace: WorkspaceID, at columnIndex: Int, delta: CGFloat) -> Bool {
		guard let host = workspaces[workspace]?.host, let visibleFrame = monitors[host]?.visibleFrame else { return false }
		let config = self.config
		return editLayoutColumns(of: workspace) { columns, stored -> Bool in
			guard columns.count > 1, columnIndex >= 0, columnIndex < columns.count - 1 else { return false }
			var ratios = stored.widthRatios ?? ColumnView.evenRatios(columns.count)
			if ratios.count != columns.count {
				ratios = ColumnView.evenRatios(columns.count)
			}
			let available = visibleFrame.width - config.padding * 2 - config.gap * CGFloat(columns.count - 1)
			let deltaRatio = delta / available
			let left = ratios[columnIndex] + deltaRatio
			let right = ratios[columnIndex + 1] - deltaRatio
			guard left >= Self.minimumRatio && right >= Self.minimumRatio else { return false }
			ratios[columnIndex] = left
			ratios[columnIndex + 1] = right
			stored.widthRatios = ratios
			return true
		} ?? false
	}

	/// Moves the boundary between row `rowIndex` and the next one in drawable column `columnIndex`
	/// by `delta` points (positive = down). Refused below the minimum share.
	@discardableResult
	mutating func resizeRowGap(in workspace: WorkspaceID, column columnIndex: Int, row rowIndex: Int, delta: CGFloat) -> Bool {
		guard let host = workspaces[workspace]?.host, let visibleFrame = monitors[host]?.visibleFrame else { return false }
		let config = self.config
		return editLayoutColumns(of: workspace) { columns, stored -> Bool in
			guard columns.indices.contains(columnIndex) else { return false }
			let count = columns[columnIndex].count
			guard count > 1, rowIndex >= 0, rowIndex < count - 1 else { return false }
			var ratios = stored.rowRatios[columnIndex] ?? ColumnView.evenRatios(count)
			if ratios.count != count {
				ratios = ColumnView.evenRatios(count)
			}
			let available = visibleFrame.height - config.padding * 2 - config.gap * CGFloat(count - 1)
			let deltaRatio = delta / available
			let upper = ratios[rowIndex] + deltaRatio
			let lower = ratios[rowIndex + 1] - deltaRatio
			guard upper >= Self.minimumRatio && lower >= Self.minimumRatio else { return false }
			ratios[rowIndex] = upper
			ratios[rowIndex + 1] = lower
			stored.rowRatios[columnIndex] = ratios
			return true
		} ?? false
	}

	/// Grows or shrinks the window's column by one step, taking the change evenly from both
	/// neighbouring columns (or all from the one neighbour at an edge). Refused below the minimum
	/// share or when the workspace has one column.
	@discardableResult
	mutating func resizeWindow(_ id: WindowID, increase: Bool) -> Bool {
		guard let workspace = records[id]?.workspace else { return false }
		return editLayoutColumns(of: workspace) { columns, stored -> Bool in
			guard let (column, _) = ColumnView.position(of: id, in: columns), columns.count > 1 else { return false }
			let delta = increase ? Self.resizeStep : -Self.resizeStep
			var ratios = stored.widthRatios ?? ColumnView.evenRatios(columns.count)
			if ratios.count != columns.count {
				ratios = ColumnView.evenRatios(columns.count)
			}
			let hasLeft = column > 0
			let hasRight = column < columns.count - 1
			let current = ratios[column] + delta
			if hasLeft && hasRight {
				let left = ratios[column - 1] - delta / 2
				let right = ratios[column + 1] - delta / 2
				guard left >= Self.minimumRatio && right >= Self.minimumRatio && current >= Self.minimumRatio else { return false }
				ratios[column - 1] = left
				ratios[column + 1] = right
			} else if hasLeft {
				let left = ratios[column - 1] - delta
				guard left >= Self.minimumRatio && current >= Self.minimumRatio else { return false }
				ratios[column - 1] = left
			} else {
				let right = ratios[column + 1] - delta
				guard right >= Self.minimumRatio && current >= Self.minimumRatio else { return false }
				ratios[column + 1] = right
			}
			ratios[column] = current
			stored.widthRatios = ratios
			return true
		} ?? false
	}
}
