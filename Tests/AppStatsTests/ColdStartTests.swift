// ColdStartTests.swift - Regression coverage for setUserProperty and crash-marker replay.
//
// Both scenarios are exercised in a single `configure()` call rather than as separate
// tests. `AppStats.configure()` is fire-and-forget (Task.detached) with no teardown hook,
// and `AppStats` is a process-wide singleton — a second `configure()` call in the same
// process can leave the first instance's background initialization still running,
// clobbering the second instance's writes to the same fixed on-disk event queue file.
// Real apps only ever call configure() once per process, so one combined cold-start
// scenario is both more realistic and avoids that cross-instance interference.
//
// Copyright © 2026 One Thum Software

import XCTest
@testable import AppStats

final class ColdStartTests: XCTestCase {

    override func setUpWithError() throws {
        try? FileManager.default.removeItem(at: StoragePaths.eventsFileURL())
        try? FileManager.default.removeItem(at: StoragePaths.userPropertiesFileURL())
        try? FileManager.default.removeItem(at: StoragePaths.crashMarkerURL())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: StoragePaths.eventsFileURL())
        try? FileManager.default.removeItem(at: StoragePaths.userPropertiesFileURL())
        try? FileManager.default.removeItem(at: StoragePaths.crashMarkerURL())
    }

    /// Regression test for two bugs found in the same audit:
    ///
    /// 1. `setUserProperty` was a no-op: the private `setProperty` it delegated to had an
    ///    empty body, so a property set before `track()` never appeared on any event.
    /// 2. The crash marker written on crash was never read back: `checkForPreviousCrash()`
    ///    was `internal` (unreachable by host apps) and nothing in the SDK called it either.
    ///
    /// This simulates a real cold start after a previous-session crash: a marker file is
    /// present on disk before `configure()` runs, mirroring what a host app would find.
    @MainActor
    func testColdStartReplaysCrashAndAttachesUserPropertyToEvents() async throws {
        let crashSessionID = UUID()
        let stackTrace = """
        0   MyApp   0x0000000100000000 someFunction + 16
        1   MyApp   0x0000000100000100 main + 32
        """
        let marker = """
        CRASH_TIMESTAMP: 1754800000.0
        SIGNAL: SIGSEGV
        REASON: N/A
        SESSION_ID: \(crashSessionID.uuidString)
        STACK_TRACE:
        \(stackTrace)
        """

        let crashMarkerURL = try StoragePaths.crashMarkerURL()
        try FileManager.default.createDirectory(
            at: crashMarkerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try marker.write(to: crashMarkerURL, atomically: true, encoding: .utf8)

        AppStats.configure(apiKey: "as_test_00000000000000000001")
        AppStats.setUserProperty("subscription_tier", value: "premium")
        AppStats.track("unit_test_event")

        let crashEvent = try await waitForPersistedEvent(ofType: .crash)
        XCTAssertEqual(crashEvent.sessionID, crashSessionID)
        XCTAssertEqual(crashEvent.properties?["exception"]?.unwrapped as? String, "SIGSEGV")
        XCTAssertEqual(crashEvent.properties?["message"]?.unwrapped as? String, "N/A")
        XCTAssertEqual(crashEvent.properties?["stack_trace"]?.unwrapped as? String, stackTrace)
        // The marker must be consumed so the same crash isn't reported twice.
        XCTAssertFalse(FileManager.default.fileExists(atPath: crashMarkerURL.path))

        let customEvent = try await waitForPersistedEvent(named: "unit_test_event")
        XCTAssertEqual(customEvent.properties?["subscription_tier"]?.unwrapped as? String, "premium")
    }

    private enum TestError: Error {
        case timedOutWaitingForEvent
    }

    /// Polls the on-disk event queue since `configure()`'s startup work is fire-and-forget.
    @MainActor
    private func waitForPersistedEvent(
        named name: String? = nil,
        ofType type: Event.EventType? = nil,
        timeout: TimeInterval = 5
    ) async throws -> Event {
        let deadline = Date().addingTimeInterval(timeout)
        let eventsURL = try StoragePaths.eventsFileURL()

        while Date() < deadline {
            if let data = try? Data(contentsOf: eventsURL) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let events = try? decoder.decode([Event].self, from: data),
                   let match = events.first(where: { ($0.name == name || name == nil) && ($0.type == type || type == nil) }) {
                    return match
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        throw TestError.timedOutWaitingForEvent
    }
}
