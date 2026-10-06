//
//  LayoutTests.swift
//  Axis core tests
//
//  Column layout math and the geometry of parked windows.
//

import Foundation
import CoreGraphics

let layoutTests: [TestCase] = evenSplitTests + ratioTests + fitTests + geometryTests + reservationTests
	+ parkCornerTests + hiddenTests

// The default main display: 1440x900 at the origin, a 25 pt menu bar, no Dock.
private let mainVisible = CGRect(x: 0, y: 25, width: 1440, height: 875)
private let defaults = LayoutConfig()

private func layout(_ columns: [[WindowID]], widthRatios: [CGFloat]? = nil, rowRatios: [Int: [CGFloat]] = [:],
	visibleFrame: CGRect = mainVisible, config: LayoutConfig = LayoutConfig(),
	reservation: PlacementReservation? = nil) -> LayoutResult {
	ColumnLayout.frames(for: LayoutInput(columns: columns, widthRatios: widthRatios, rowRatios: rowRatios),
		visibleFrame: visibleFrame, config: config, reservation: reservation)
}

private func expectFrames(_ actual: [WindowID: CGRect], _ expected: [WindowID: CGRect], file: StaticString = #filePath, line: UInt = #line) {
	expectEqual(Set(actual.keys), Set(expected.keys), "laid out windows", file: file, line: line)
	for id in expected.keys.sorted() {
		guard let frame = actual[id], let target = expected[id] else { continue }
		expectEqual(frame, target, accuracy: 0.001, "#\(id)", file: file, line: line)
	}
}

private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
	CGRect(x: x, y: y, width: width, height: height)
}

// MARK: - Even split

private let evenSplitTests: [TestCase] = [
	TestCase("one to six columns split the padded width evenly with gaps between them") {
		let expected: [Int: (x: [CGFloat], width: CGFloat)] = [
			1: ([12], 1416),
			2: ([12, 726], 702),
			3: ([12, 488, 964], 464),
			4: ([12, 369, 726, 1083], 345),
			5: ([12, 297.6, 583.2, 868.8, 1154.4], 273.6),
			6: ([12, 250, 488, 726, 964, 1202], 226),
		]
		for count in 1...6 {
			let slots = ColumnLayout.slotFrames(columnSizes: Array(repeating: 1, count: count), visibleFrame: mainVisible, config: defaults)
			expectEqual(slots.count, count, "\(count) columns")
			guard let columns = expected[count], slots.count == count else { continue }
			for (index, slot) in slots.enumerated() {
				expectEqual(slot.count, 1)
				expectEqual(slot.first ?? .null, rect(columns.x[index], 37, columns.width, 851), accuracy: 0.001,
					"\(count) columns, column \(index)")
			}
			// The last column ends at the right padding.
			expectEqual(slots.last?.first?.maxX ?? 0, 1428, accuracy: 0.001)
		}
	},

	TestCase("rows split a column's height with gaps between them") {
		let slots = ColumnLayout.slotFrames(columnSizes: [1, 2, 3], visibleFrame: mainVisible, config: defaults)
		expectEqual(slots.map { $0.count }, [1, 2, 3])
		guard slots.count == 3, slots[1].count == 2, slots[2].count == 3 else { return }
		expectEqual(slots[0][0], rect(12, 37, 464, 851), accuracy: 0.001)
		expectEqual(slots[1][0], rect(488, 37, 464, 419.5), accuracy: 0.001)
		expectEqual(slots[1][1], rect(488, 468.5, 464, 419.5), accuracy: 0.001)
		expectEqual(slots[2][0], rect(964, 37, 464, 275.6667), accuracy: 0.001)
		expectEqual(slots[2][1], rect(964, 324.6667, 464, 275.6667), accuracy: 0.001)
		expectEqual(slots[2][2], rect(964, 612.3333, 464, 275.6667), accuracy: 0.001)
		expectEqual(slots[2][2].maxY, 888, accuracy: 0.001)
	},

	TestCase("a column of size zero keeps its share of the width without slots") {
		let slots = ColumnLayout.slotFrames(columnSizes: [1, 0, 1], visibleFrame: mainVisible, config: defaults)
		expectEqual(slots.map { $0.count }, [1, 0, 1])
		expectEqual(slots.last?.first ?? .null, rect(964, 37, 464, 851), accuracy: 0.001)
		expectEqual(ColumnLayout.slotFrames(columnSizes: [], visibleFrame: mainVisible, config: defaults), [])
	},

	TestCase("columns without ratios are laid out evenly by window id") {
		let result = layout([[1], [2, 3], [4, 5, 6]])
		expectFrames(result.frames, [
			1: rect(12, 37, 464, 851),
			2: rect(488, 37, 464, 419.5), 3: rect(488, 468.5, 464, 419.5),
			4: rect(964, 37, 464, 275.6667), 5: rect(964, 324.6667, 464, 275.6667), 6: rect(964, 612.3333, 464, 275.6667),
		])
		expectEqual(result.widthRatios, nil)
		expectEqual(result.rowRatios, [:])
		expectEqual(result.reservedSlot, nil)
	},
]

// MARK: - Ratios

private let ratioTests: [TestCase] = [
	TestCase("width ratios matching the column count set the widths, row ratios the heights") {
		let result = layout([[1], [2, 3]], widthRatios: [0.6, 0.4], rowRatios: [1: [0.25, 0.75]])
		expectFrames(result.frames, [
			1: rect(12, 37, 842.4, 851),
			2: rect(866.4, 37, 561.6, 209.75),
			3: rect(866.4, 258.75, 561.6, 629.25),
		])
		expectEqual(result.widthRatios, [0.6, 0.4])
		expectEqual(result.rowRatios, [1: [0.25, 0.75]])
	},

	TestCase("row ratios of a column whose window count changed are dropped") {
		let result = layout([[1], [2, 3]], widthRatios: [0.5, 0.5], rowRatios: [0: [0.5, 0.5], 1: [0.25, 0.75], 4: [1]])
		expectFrames(result.frames, [
			1: rect(12, 37, 702, 851),
			2: rect(726, 37, 702, 209.75),
			3: rect(726, 258.75, 702, 629.25),
		])
		// Entries past the last column are not looked at.
		expectEqual(result.rowRatios, [1: [0.25, 0.75], 4: [1]])
		expectEqual(result.widthRatios, [0.5, 0.5])
	},

	TestCase("valid row ratios keep even widths and leave stale width ratios stored") {
		let result = layout([[1], [2, 3]], widthRatios: [0.5, 0.3, 0.2], rowRatios: [1: [0.25, 0.75]])
		expectFrames(result.frames, [
			1: rect(12, 37, 702, 851),
			2: rect(726, 37, 702, 209.75),
			3: rect(726, 258.75, 702, 629.25),
		])
		expectEqual(result.widthRatios, [0.5, 0.3, 0.2])
		expectEqual(result.rowRatios, [1: [0.25, 0.75]])

		// The same without stored widths: they stay missing.
		let missing = layout([[1], [2, 3]], rowRatios: [1: [0.25, 0.75]])
		expectEqual(missing.frames, result.frames)
		expectEqual(missing.widthRatios, nil)
	},

	TestCase("stale ratios without a matching row ratio reset to an even split") {
		let result = layout([[1], [2]], widthRatios: [0.5, 0.3, 0.2], rowRatios: [0: [0.5, 0.5]])
		expectFrames(result.frames, [1: rect(12, 37, 702, 851), 2: rect(726, 37, 702, 851)])
		expectEqual(result.widthRatios, nil)
		expectEqual(result.rowRatios, [:])
	},

	TestCase("nothing drawable leaves the ratios as they are") {
		let result = layout([], widthRatios: [0.7, 0.3], rowRatios: [0: [0.4, 0.6]])
		expectEqual(result.frames, [:])
		expectEqual(result.widthRatios, [0.7, 0.3])
		expectEqual(result.rowRatios, [0: [0.4, 0.6]])
	},
]

// MARK: - Fitting inside the visible area

private let fitTests: [TestCase] = [
	TestCase("a slot pushed past the right edge moves back inside") {
		let result = layout([[1], [2]], widthRatios: [0.7, 0.5])
		expectFrames(result.frames, [1: rect(12, 37, 982.8, 851), 2: rect(726, 37, 702, 851)])
	},

	TestCase("a slot wider than the visible area stays at the left padding") {
		let result = layout([[1], [2]], widthRatios: [1.2, 0.1])
		expectFrames(result.frames, [1: rect(12, 37, 1684.8, 851), 2: rect(1287.6, 37, 140.4, 851)])
	},

	TestCase("a row pushed past the bottom edge moves back inside") {
		let result = layout([[1, 2]], widthRatios: [1], rowRatios: [0: [0.8, 0.4]])
		expectFrames(result.frames, [1: rect(12, 37, 1416, 671.2), 2: rect(12, 552.4, 1416, 335.6)])
	},
]

// MARK: - Gaps, padding and screen geometry

private let geometryTests: [TestCase] = [
	TestCase("no gap and no padding fill the visible area exactly") {
		let result = layout([[1], [2]], config: LayoutConfig(gap: 0, padding: 0))
		expectFrames(result.frames, [1: rect(0, 25, 720, 875), 2: rect(720, 25, 720, 875)])
	},

	TestCase("a wider gap and narrower padding change every slot") {
		let result = layout([[1], [2], [3, 4]], config: LayoutConfig(gap: 20, padding: 8))
		expectFrames(result.frames, [
			1: rect(8, 33, 461.3333, 859),
			2: rect(489.3333, 33, 461.3333, 859),
			3: rect(970.6667, 33, 461.3333, 419.5),
			4: rect(970.6667, 472.5, 461.3333, 419.5),
		])
	},

	TestCase("a secondary display at negative coordinates lays out inside its own visible area") {
		let left = testDisplay("Left", x: -1920, y: -180, width: 1920, height: 1080)
		expectEqual(left.visibleFrame, rect(-1920, -155, 1920, 1055))
		let result = layout([[1], [2, 3]], visibleFrame: left.visibleFrame)
		expectFrames(result.frames, [
			1: rect(-1908, -143, 942, 1031),
			2: rect(-954, -143, 942, 509.5),
			3: rect(-954, 378.5, 942, 509.5),
		])
		// The right column ends at the padding left of the main display.
		expectEqual(result.frames[3]?.maxX ?? 0, -12, accuracy: 0.001)
	},

	TestCase("a Dock at the bottom shortens the slots") {
		let docked = testDisplay("Main", dock: 70)
		let result = layout([[1]], visibleFrame: docked.visibleFrame)
		expectFrames(result.frames, [1: rect(12, 37, 1416, 781)])
	},
]

// MARK: - Placement reservation

private let reservationTests: [TestCase] = [
	TestCase("a reservation on an empty workspace reserves the whole padded area") {
		let reservation = PlacementReservation(kind: .newColumnRight, monitor: testKey("Main"), columnIndex: 0)
		let result = layout([], widthRatios: [0.6, 0.4], reservation: reservation)
		expectEqual(result.reservedSlot ?? .null, rect(12, 37, 1416, 851), accuracy: 0.001)
		expectEqual(result.frames, [:])
		expectEqual(result.widthRatios, [0.6, 0.4])
	},

	TestCase("a new column right of a column shifts the columns after it") {
		let reservation = PlacementReservation(kind: .newColumnRight, monitor: testKey("Main"), columnIndex: 0)
		let result = layout([[1], [2]], reservation: reservation)
		expectEqual(result.reservedSlot ?? .null, rect(488, 37, 464, 851), accuracy: 0.001)
		expectFrames(result.frames, [1: rect(12, 37, 464, 851), 2: rect(964, 37, 464, 851)])

		let atEnd = layout([[1], [2]], reservation: PlacementReservation(kind: .newColumnRight, monitor: testKey("Main"), columnIndex: 1))
		expectEqual(atEnd.reservedSlot ?? .null, rect(964, 37, 464, 851), accuracy: 0.001)
		expectFrames(atEnd.frames, [1: rect(12, 37, 464, 851), 2: rect(488, 37, 464, 851)])
	},

	TestCase("a new column left of a column shifts it and the columns after it") {
		let reservation = PlacementReservation(kind: .newColumnLeft, monitor: testKey("Main"), columnIndex: 0)
		let result = layout([[1], [2]], reservation: reservation)
		expectEqual(result.reservedSlot ?? .null, rect(12, 37, 464, 851), accuracy: 0.001)
		expectFrames(result.frames, [1: rect(488, 37, 464, 851), 2: rect(964, 37, 464, 851)])
	},

	TestCase("a slot above a column pushes its windows down") {
		let reservation = PlacementReservation(kind: .aboveInColumn, monitor: testKey("Main"), columnIndex: 1)
		let result = layout([[1], [2]], reservation: reservation)
		expectEqual(result.reservedSlot ?? .null, rect(726, 37, 702, 419.5), accuracy: 0.001)
		expectFrames(result.frames, [1: rect(12, 37, 702, 851), 2: rect(726, 468.5, 702, 419.5)])
	},

	TestCase("a slot below a column clamps the column index") {
		let reservation = PlacementReservation(kind: .belowInColumn, monitor: testKey("Main"), columnIndex: 7)
		let result = layout([[1], [2]], reservation: reservation)
		expectEqual(result.reservedSlot ?? .null, rect(726, 468.5, 702, 419.5), accuracy: 0.001)
		expectFrames(result.frames, [1: rect(12, 37, 702, 851), 2: rect(726, 37, 702, 419.5)])
	},

	TestCase("the reserved layout splits evenly and leaves the stored ratios alone") {
		let reservation = PlacementReservation(kind: .newColumnRight, monitor: testKey("Main"), columnIndex: 1)
		let result = layout([[1], [2]], widthRatios: [0.6, 0.4], rowRatios: [0: [1]], reservation: reservation)
		expectFrames(result.frames, [1: rect(12, 37, 464, 851), 2: rect(488, 37, 464, 851)])
		expectEqual(result.widthRatios, [0.6, 0.4])
		expectEqual(result.rowRatios, [0: [1]])
	},

	TestCase("a float reservation lays out as usual without a reserved slot") {
		let reservation = PlacementReservation(kind: .float, monitor: testKey("Main"), columnIndex: 0)
		let result = layout([[1], [2]], reservation: reservation)
		expectEqual(result.reservedSlot, nil)
		expectFrames(result.frames, [1: rect(12, 37, 702, 851), 2: rect(726, 37, 702, 851)])
	},
]

// MARK: - Park corner

/// Monitors connected in order, as the planner sees them.
private func monitors(_ displays: [DisplayFacts]) -> [MonitorState] {
	let state = testState(displays)
	return state.monitorOrder.compactMap { state.monitors[$0] }
}

private let parkCornerTests: [TestCase] = [
	TestCase("the park origin leaves one point inside the visible area's bottom corner") {
		expectEqual(ParkGeometry.parkOrigin(size: CGSize(width: 600, height: 400), visibleFrame: mainVisible, corner: .bottomRight),
			CGPoint(x: 1439, y: 899))
		expectEqual(ParkGeometry.parkOrigin(size: CGSize(width: 600, height: 400), visibleFrame: mainVisible, corner: .bottomLeft),
			CGPoint(x: -599, y: 899))
		let docked = testDisplay("Main", dock: 70).visibleFrame
		expectEqual(ParkGeometry.parkOrigin(size: CGSize(width: 600, height: 400), visibleFrame: docked, corner: .bottomRight),
			CGPoint(x: 1439, y: 829))
	},

	TestCase("a single monitor parks at its bottom-right corner") {
		let all = monitors([testDisplay("Main", primary: true)])
		expectEqual(ParkGeometry.corner(for: all[0], monitors: all), .bottomRight)
	},

	TestCase("a monitor with a neighbour on its right parks at its bottom-left corner") {
		let all = monitors([testDisplay("Main", primary: true), testDisplay("Right", x: 1440, y: -90, width: 1920, height: 1080)])
		expectEqual(ParkGeometry.corner(for: all[0], monitors: all), .bottomLeft)
		expectEqual(ParkGeometry.corner(for: all[1], monitors: all), .bottomRight)
	},

	TestCase("a monitor below reaching past the right edge moves parking to the left corner") {
		let all = monitors([testDisplay("Main", primary: true), testDisplay("Below", x: 400, y: 900, width: 1920, height: 1080)])
		expectEqual(ParkGeometry.corner(for: all[0], monitors: all), .bottomLeft)
		expectEqual(ParkGeometry.corner(for: all[1], monitors: all), .bottomRight)
	},

	TestCase("a monitor right below with the same width only meets a sliver and changes nothing") {
		let all = monitors([testDisplay("Main", primary: true), testDisplay("Below", y: 900)])
		expectEqual(ParkGeometry.corner(for: all[0], monitors: all), .bottomRight)
	},

	TestCase("when both corners reach another monitor the one showing less wins") {
		let wideRight = monitors([testDisplay("Main", primary: true), testDisplay("Below", x: -500, y: 900, width: 2560, height: 1440)])
		expectEqual(ParkGeometry.corner(for: wideRight[0], monitors: wideRight), .bottomLeft)
		let wideLeft = monitors([testDisplay("Main", primary: true), testDisplay("Below", x: -900, y: 900, width: 2560, height: 1440)])
		expectEqual(ParkGeometry.corner(for: wideLeft[0], monitors: wideLeft), .bottomRight)
	},
]

// MARK: - Out of sight

private let hiddenTests: [TestCase] = [
	TestCase("a window counts as hidden with at most a 2 point sliver on any visible area") {
		let all = monitors([testDisplay("Main", primary: true)])
		expect(ParkGeometry.isEffectivelyHidden(rect(1439, 899, 600, 400), monitors: all), "parked sliver")
		expect(ParkGeometry.isEffectivelyHidden(rect(-599, 899, 600, 400), monitors: all), "left sliver")
		expect(ParkGeometry.isEffectivelyHidden(rect(1438, 500, 600, 400), monitors: all), "2 pt wide")
		expect(!ParkGeometry.isEffectivelyHidden(rect(1437, 500, 600, 400), monitors: all), "3 pt wide")
		expect(ParkGeometry.isEffectivelyHidden(rect(100, 898, 600, 400), monitors: all), "2 pt high")
		expect(!ParkGeometry.isEffectivelyHidden(rect(100, 897, 600, 400), monitors: all), "3 pt high")
		expect(ParkGeometry.isEffectivelyHidden(rect(5000, 5000, 600, 400), monitors: all), "off every monitor")
		expect(!ParkGeometry.isEffectivelyHidden(rect(100, 100, 600, 400), monitors: all), "on screen")
	},

	TestCase("the Dock strip below the visible area does not count as showing a window") {
		let all = monitors([testDisplay("Main", dock: 70, primary: true)])
		expect(ParkGeometry.isEffectivelyHidden(rect(100, 831, 600, 400), monitors: all))
		expect(!ParkGeometry.isEffectivelyHidden(rect(100, 820, 600, 400), monitors: all))
	},

	TestCase("a window parked toward a neighbour shows on the neighbour") {
		let all = monitors([testDisplay("Main", primary: true), testDisplay("Right", x: 1440, width: 1920, height: 1080)])
		expect(!ParkGeometry.isEffectivelyHidden(rect(1439, 899, 600, 400), monitors: all))
		expect(ParkGeometry.isEffectivelyHidden(rect(-599, 899, 600, 400), monitors: all))
	},
]
