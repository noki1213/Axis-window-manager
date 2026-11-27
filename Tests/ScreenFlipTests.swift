//
//  ScreenFlipTests.swift
//  Axis core tests
//
//  The vertical flip between top-left and bottom-left screen coordinates.
//

import Foundation
import CoreGraphics

let screenFlipTests: [TestCase] = [
	TestCase("a point flips its y around the primary height and keeps x") {
		let flipped = ScreenFlip.point(CGPoint(x: 100, y: 200), primaryHeight: 900)
		expectEqual(flipped, CGPoint(x: 100, y: 700), accuracy: 0.001, "flipped point")
	},
	TestCase("a rect keeps its size and its top edge becomes the bottom edge") {
		let top = CGRect(x: 10, y: 25, width: 300, height: 400)
		let flipped = ScreenFlip.rect(top, primaryHeight: 900)
		expectEqual(flipped.size, top.size, accuracy: 0.001, "size")
		expectEqual(flipped.minX, 10, accuracy: 0.001, "x")
		expectEqual(flipped.minY, 900 - top.maxY, accuracy: 0.001, "bottom edge")
		expectEqual(flipped.maxY, 900 - top.minY, accuracy: 0.001, "top edge")
	},
	TestCase("flipping twice gives back the original") {
		let point = CGPoint(x: -30, y: 1234.5)
		expectEqual(ScreenFlip.point(ScreenFlip.point(point, primaryHeight: 900), primaryHeight: 900), point, accuracy: 0.001, "point")
		let rect = CGRect(x: 5, y: -300, width: 640, height: 480)
		expectEqual(ScreenFlip.rect(ScreenFlip.rect(rect, primaryHeight: 900), primaryHeight: 900), rect, accuracy: 0.001, "rect")
	},
	TestCase("a display above the primary one lands at negative y in top-left coordinates") {
		// Cocoa frame of a 1080 pt display stacked over a 900 pt primary one.
		let above = CGRect(x: 0, y: 900, width: 1920, height: 1080)
		expectEqual(ScreenFlip.rect(above, primaryHeight: 900), CGRect(x: 0, y: -1080, width: 1920, height: 1080), accuracy: 0.001, "above")
	},
	TestCase("a display below the primary one lands past the primary height in top-left coordinates") {
		let below = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
		expectEqual(ScreenFlip.rect(below, primaryHeight: 900), CGRect(x: 0, y: 900, width: 1920, height: 1080), accuracy: 0.001, "below")
	},
]
