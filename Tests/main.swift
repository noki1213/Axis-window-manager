//
//  main.swift
//  Axis core tests
//
//  Entry point of the test runner for the window-tracking core (Axis/Tracking/Core).
//  It is a plain executable instead of an XCTest bundle so the pure core builds and runs in
//  seconds. The flags match the app target's language mode, isolation and upcoming features;
//  `-target` pins the deployment version because the host default would hide availability errors.
//
//  Run from the repository root (give each checkout its own OUT directory when several run at once):
//
//    OUT=${OUT:-/tmp/axis-tracking-tests}
//    mkdir -p "$OUT" && swiftc -swift-version 5 -default-isolation MainActor \
//      -enable-upcoming-feature DisableOutwardActorInference -enable-upcoming-feature InferSendableFromCaptures \
//      -enable-upcoming-feature GlobalActorIsolatedTypesUsability -enable-upcoming-feature MemberImportVisibility \
//      -enable-upcoming-feature InferIsolatedConformances -enable-upcoming-feature NonisolatedNonsendingByDefault \
//      -enable-bare-slash-regex -target arm64-apple-macos14.0 -DDEBUG -Onone -warnings-as-errors \
//      Axis/Tracking/Core/*.swift Tests/*.swift -o "$OUT/t" && "$OUT/t"
//
//  `t -v` prints each test before it runs; `t <text>` runs only the tests whose "Suite / name"
//  contains the text. The exit status is 1 when any test fails.
//
//  This directory stays outside Axis/: everything under Axis/ is compiled into the app, and a
//  second main.swift would clash with the app's entry point. This is also the only file that
//  may contain top-level code.
//

import Foundation

exit(runTests([
	TestSuite("Workspaces", workspacesTests),
	TestSuite("Liveness", livenessTests),
	TestSuite("Admission", admissionTests),
	TestSuite("Visibility", visibilityTests),
	TestSuite("Layout", layoutTests),
	TestSuite("Planner", plannerTests),
	TestSuite("Topology", topologyTests),
	TestSuite("Scenario", scenarioTests),
	TestSuite("Persistence", persistenceTests),
]))
