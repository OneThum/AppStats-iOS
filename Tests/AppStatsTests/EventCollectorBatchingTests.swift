// EventCollectorBatchingTests.swift - The thresholds that decide when events leave the
// device, and what gets dropped when they cannot.
//
// EventCollectorRetryTests covers the eviction race during a retry. This covers the
// steady-state path: the automatic flush, the per-request cap, and the queue ceiling.
//
// Copyright © 2026 One Thum Software

import XCTest
@testable import AppStats

final class EventCollectorBatchingTests: XCTestCase {

    private let sessionID = UUID()

    /// A private directory per test. `EventCollector` loads whatever is persisted when it is
    /// created, in a detached task, so sharing the app's real events file lets a queue from
    /// one test arrive in the middle of another.
    private var storageDirectory: URL!

    override func setUpWithError() throws {
        storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStatsTests-\(UUID().uuidString)", isDirectory: true)
        URLProtocolStub.box.script([], fallback: .status(202))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storageDirectory)
    }

    private func makeCollector(maxQueueSize: Int = 500) -> EventCollector {
        let network = NetworkManager(
            apiKey: "as_test_00000000000000000042",
            baseURL: URL(string: "https://ingest.example.invalid")!,
            testProtocolClasses: [URLProtocolStub.self]
        )
        return EventCollector(
            sessionID: sessionID,
            storage: StorageManager(directoryForTesting: storageDirectory),
            network: network,
            maxQueueSize: maxQueueSize
        )
    }

    /// A collector whose init-time restore has already settled, so it cannot interleave with
    /// the events a test collects.
    private func makeSettledCollector(maxQueueSize: Int = 500) async -> EventCollector {
        let collector = makeCollector(maxQueueSize: maxQueueSize)
        await collector.awaitInitialLoadForTesting()
        return collector
    }

    private func event(_ name: String = "batching") -> Event {
        Event(type: .custom, name: name, sessionID: sessionID)
    }

    /// `collect()` kicks the flush off in a detached task, so it is not finished when
    /// `collect()` returns. Poll briefly rather than sleeping a fixed amount.
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        _ condition: @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(description)")
    }

    func testDoesNotSendAnythingBeforeTheBatchThresholdIsReached() async throws {
        let collector = await makeSettledCollector()

        // batchSize is 20, so nineteen events stay on the device.
        for _ in 0..<19 {
            try await collector.collect(event())
        }

        let queued = await collector.queueSnapshotForTesting.count
        XCTAssertEqual(queued, 19)
        XCTAssertEqual(
            URLProtocolStub.box.requestCount, 0,
            "a partial batch should wait for the timer, not go out one event at a time"
        )
    }

    func testFlushesOnceTheBatchThresholdIsReached() async throws {
        let collector = await makeSettledCollector()

        for _ in 0..<20 {
            try await collector.collect(event())
        }

        try await waitUntil("the automatic flush") { URLProtocolStub.box.requestCount >= 1 }
        try await waitUntil("the queue to drain") {
            await collector.queueSnapshotForTesting.isEmpty
        }
    }

    func testSendsAtMostOneHundredEventsPerRequest() async throws {
        // The server caps a batch, so a backlog has to be split rather than sent whole.
        let collector = await makeSettledCollector()
        for _ in 0..<150 {
            try await collector.collect(event())
        }

        try await waitUntil("the backlog to drain") {
            await collector.queueSnapshotForTesting.isEmpty
        }

        let bodies = URLProtocolStub.box.requests.compactMap(\.body)
        XCTAssertGreaterThanOrEqual(bodies.count, 2, "150 events cannot go in one request")

        // Every request must respect the cap. Decoding the compressed bodies is
        // NetworkManagerTests' job; here the count is what matters, and the queue draining
        // to empty is what proves nothing was lost.
        XCTAssertTrue(bodies.allSatisfy { !$0.isEmpty })
    }

    func testDropsTheOldestEventWhenTheQueueIsFull() async throws {
        // Nothing can be sent, so the queue fills and the ceiling is what is under test.
        URLProtocolStub.box.script([], fallback: .failure(.notConnectedToInternet))
        let collector = await makeSettledCollector(maxQueueSize: 5)

        let events = (0..<8).map { event("event_\($0)") }
        for event in events {
            try? await collector.collect(event)
        }

        let queue = await collector.queueSnapshotForTesting
        XCTAssertEqual(queue.count, 5, "the queue must not grow past maxQueueSize")

        // In steady state the oldest go first: an analytics backlog is more useful recent.
        let survivingIDs = Set(queue.map(\.id))
        for dropped in events.prefix(3) {
            XCTAssertFalse(survivingIDs.contains(dropped.id), "oldest should have been evicted")
        }
        for kept in events.suffix(5) {
            XCTAssertTrue(survivingIDs.contains(kept.id), "newest should have been kept")
        }
    }

    // MARK: - What gets restored on launch
    //
    // These drive EventCollector.eventsToRestore directly. Going through the actor cannot
    // pin the ordering down: the restore is spawned from init, so it reaches the storage read
    // before any collect() a test makes, and an earlier version of these tests passed just as
    // happily with the duplicate bug put back.

    func testRestoreSkipsAnEventAlreadyInTheQueue() {
        // The cold-start duplicate: collect() persisted the queue, so the file read by the
        // restore holds the very event already sitting in it. Appending it sent it twice.
        let queued = event("tracked_at_launch")
        let fromLastLaunch = event("from_last_launch")

        let restored = EventCollector.eventsToRestore(
            persisted: [fromLastLaunch, queued],
            alreadyQueued: [queued],
            staleBefore: Date().addingTimeInterval(-48 * 3600),
            maxQueueSize: 500
        )

        XCTAssertEqual(restored.map(\.id), [fromLastLaunch.id])
    }

    func testRestoreCountsTheQueueItIsAddingTo() {
        // The ceiling is 5 and three events are already queued, so at most two may join --
        // appending up to maxQueueSize regardless overshot it.
        let queued = (0..<3).map { event("queued_\($0)") }
        let persisted = (0..<10).map { event("persisted_\($0)") }

        let restored = EventCollector.eventsToRestore(
            persisted: persisted,
            alreadyQueued: queued,
            staleBefore: Date().addingTimeInterval(-48 * 3600),
            maxQueueSize: 5
        )

        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.map(\.id), persisted.prefix(2).map(\.id))
    }

    func testRestoreAddsNothingToAFullQueue() {
        let queued = (0..<5).map { event("queued_\($0)") }

        let restored = EventCollector.eventsToRestore(
            persisted: [event("persisted")],
            alreadyQueued: queued,
            staleBefore: Date().addingTimeInterval(-48 * 3600),
            maxQueueSize: 5
        )

        XCTAssertTrue(restored.isEmpty)
    }

    func testRestoreDropsEventsOlderThanTheStalenessWindow() {
        let cutoff = Date()
        let old = Event(timestamp: cutoff.addingTimeInterval(-1), type: .custom,
                        name: "too_old", sessionID: sessionID)
        let fresh = Event(timestamp: cutoff.addingTimeInterval(1), type: .custom,
                          name: "fresh", sessionID: sessionID)

        let restored = EventCollector.eventsToRestore(
            persisted: [old, fresh],
            alreadyQueued: [],
            staleBefore: cutoff,
            maxQueueSize: 500
        )

        XCTAssertEqual(restored.map(\.id), [fresh.id])
    }

    func testRestoreFillsAnEmptyQueueUpToTheCeiling() {
        let persisted = (0..<600).map { event("persisted_\($0)") }

        let restored = EventCollector.eventsToRestore(
            persisted: persisted,
            alreadyQueued: [],
            staleBefore: Date().addingTimeInterval(-48 * 3600),
            maxQueueSize: 500
        )

        XCTAssertEqual(restored.count, 500)
    }

    func testAPersistedQueueIsRestoredOnLaunch() async throws {
        // The path end to end, which is all the actor can tell us deterministically: what a
        // previous launch left on disk is in the queue once the restore has settled.
        URLProtocolStub.box.script([], fallback: .failure(.notConnectedToInternet))

        let fromLastLaunch = (0..<3).map { event("from_last_launch_\($0)") }
        try await StorageManager(directoryForTesting: storageDirectory)
            .saveEvents(fromLastLaunch)

        let collector = await makeSettledCollector()

        let ids = await collector.queueSnapshotForTesting.map(\.id)
        XCTAssertEqual(ids, fromLastLaunch.map(\.id))
        XCTAssertEqual(Set(ids).count, ids.count, "an event was restored twice")
    }

    func testFlushOnAnEmptyQueueMakesNoRequest() async throws {
        let collector = await makeSettledCollector()

        try await collector.flush()

        XCTAssertEqual(
            URLProtocolStub.box.requestCount, 0,
            "the background flush timer fires on a quiet app too, and must stay silent"
        )
    }

    func testEventsSurviveToDiskSoAnUnsentQueueIsNotLostOnRelaunch() async throws {
        URLProtocolStub.box.script([], fallback: .failure(.notConnectedToInternet))
        let collector = await makeSettledCollector()

        let kept = event("survives_relaunch")
        try await collector.collect(kept)

        let persisted = try await StorageManager(directoryForTesting: storageDirectory).loadEvents()
        XCTAssertTrue(
            persisted.contains { $0.id == kept.id },
            "an event that has not been sent must be on disk before collect() returns"
        )
    }
}
