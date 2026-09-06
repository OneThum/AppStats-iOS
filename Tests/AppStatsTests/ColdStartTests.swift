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

    /// The minimal marker `writeCrashMarkerSignalSafe` produces from inside the actual signal
    /// handler — see CrashReporter.swift. Proves `parseMarker` learned the new format, not just
    /// that the pre-existing rich format (tested above) still works.
    ///
    /// Deliberately does not carry a session id: capturing one safely from inside a signal
    /// handler would need meaningfully more unsafe-context formatting work for a field with a
    /// documented, working fallback already (`UUID(uuidString:) ?? sessionID`), so it is left
    /// out. This test pins that fallback explicitly rather than leaving it incidental.
    @MainActor
    func testColdStartReplaysASignalSafeCrashMarker() async throws {
        let marker = "CRASH_SIGNAL:6\nCRASH_EPOCH:1754800000\n"

        let crashMarkerURL = try StoragePaths.crashMarkerURL()
        try FileManager.default.createDirectory(
            at: crashMarkerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try marker.write(to: crashMarkerURL, atomically: true, encoding: .utf8)

        AppStats.configure(apiKey: "as_test_00000000000000000002")
        AppStats.track("unit_test_event_after_signal_safe_crash")

        let crashEvent = try await waitForPersistedEvent(ofType: .crash)
        // Signal 6 is SIGABRT on Darwin — resolved back to a name by `parseMarker`, which the
        // signal handler itself could not safely do (see writeCrashMarkerSignalSafe's comment).
        XCTAssertEqual(crashEvent.properties?["exception"]?.unwrapped as? String, "SIGABRT")
        // A whole-number Double round-trips through JSON as an Int (Event's Codable value
        // tries .int before .double), so compare against whichever numeric type actually came
        // back rather than assuming Double.
        let timestampMs = (crashEvent.properties?["timestamp_ms"]?.unwrapped as? Double)
            ?? (crashEvent.properties?["timestamp_ms"]?.unwrapped as? Int).map(Double.init)
        XCTAssertEqual(timestampMs, 1754800000.0 * 1000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: crashMarkerURL.path))

        // This format has no SESSION_ID line, so `crash.sessionID` fails to parse as a UUID and
        // the event constructor falls back to `?? sessionID` — the live session, not nil and not
        // some garbage value. `AppStats.shared`/`sessionID` are `private`, so a second real event
        // from the same run is the only way to observe that fallback from outside the module:
        // if the crash event's session id matches an ordinary event's, the fallback landed on
        // the live session as intended.
        let followUpEvent = try await waitForPersistedEvent(named: "unit_test_event_after_signal_safe_crash")
        XCTAssertEqual(crashEvent.sessionID, followUpEvent.sessionID)
    }

    /// The signal-safe writer records the *crashing* session's id, and it must survive the
    /// marker round-trip so the replayed crash is attributed to the session that actually
    /// crashed rather than to whichever session is live when the marker is read.
    ///
    /// Deliberately exercised through `consumePreviousCrash()` rather than a third
    /// `configure()` call: `AppStats` is a process-wide singleton with fire-and-forget
    /// startup and no teardown hook (see this file's header), so each extra `configure()`
    /// in one process is another chance for cross-instance interference on the shared event
    /// queue. The read path is a pure function of the marker file and needs no singleton.
    func testSignalSafeMarkerRoundTripsTheCrashingSessionID() throws {
        let crashingSession = "C8D9AEB7-E42C-4192-8C7C-23B25F6D6C04"
        let marker = "CRASH_SIGNAL:6\nCRASH_EPOCH:1754800000\nSESSION_ID:\(crashingSession)\n"

        let crashMarkerURL = try StoragePaths.crashMarkerURL()
        try FileManager.default.createDirectory(
            at: crashMarkerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try marker.write(to: crashMarkerURL, atomically: true, encoding: .utf8)

        let crash = try XCTUnwrap(CrashReporter.consumePreviousCrash())
        XCTAssertEqual(crash.sessionID, crashingSession)
        XCTAssertEqual(crash.signal, "SIGABRT")
        XCTAssertEqual(crash.timestamp.timeIntervalSince1970, 1754800000, accuracy: 0.001)
        // Consumed, so a crash is never reported twice.
        XCTAssertFalse(FileManager.default.fileExists(atPath: crashMarkerURL.path))
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
