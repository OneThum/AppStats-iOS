// EventCollectorRetryTests.swift - Regression coverage for the failed-batch eviction race in
// EventCollector.flush().
//
// Copyright © 2026 One Thum Software

import XCTest
@testable import AppStats

final class EventCollectorRetryTests: XCTestCase {

    override func setUpWithError() throws {
        try? FileManager.default.removeItem(at: StoragePaths.eventsFileURL())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: StoragePaths.eventsFileURL())
    }

    /// `EventCollector` is an actor; `flush()` suspends at `await network.sendEvents(...)`,
    /// and that suspension is exactly the window in which other actor calls — like a
    /// concurrent `collect()` from the rest of the app — can interleave and grow `eventQueue`
    /// before the `catch` block re-inserts the failed batch and trims back down to
    /// `maxQueueSize`. A batch that has already failed once and is about to be retried must
    /// survive that trim ahead of brand-new events that haven't been attempted yet.
    ///
    /// `GatedFailingURLProtocol` below makes this deterministic: it holds the "network" call
    /// open until the test has appended the new events, so the interleaving isn't left to
    /// chance timing between the two concurrent tasks.
    func testFailedBatchSurvivesConcurrentCollectDuringRetry() async throws {
        let sessionID = UUID()
        let storage = StorageManager()
        let gate = FlushGate()
        GatedFailingURLProtocol.gate = gate

        let network = NetworkManager(
            apiKey: "as_test_00000000000000000003",
            baseURL: URL(string: "https://example.invalid")!,
            testProtocolClasses: [GatedFailingURLProtocol.self]
        )

        // Small enough that a handful of concurrent `collect()` calls can overflow it, without
        // needing hundreds of events to exercise the eviction path.
        let collector = EventCollector(sessionID: sessionID, storage: storage, network: network, maxQueueSize: 5)

        // The batch that is about to fail and be retried.
        let failingBatch = (0..<3).map { _ in Event(type: .custom, name: "failing_batch", sessionID: sessionID) }
        for event in failingBatch {
            try await collector.collect(event)
        }

        let flushTask = Task { try? await collector.flush() }

        // Wait until flush() has removed the batch from the queue and is suspended awaiting
        // the (gated) network call, then append new events — simulating `collect()` calls
        // racing a slow/failing network request.
        await gate.waitForRequestStarted()

        let newEvents = (0..<4).map { _ in Event(type: .custom, name: "new_event", sessionID: sessionID) }
        for event in newEvents {
            try await collector.collect(event)
        }

        // Let the gated network call fail now that the new events are in.
        await gate.openGate()
        _ = await flushTask.value

        let finalQueue = await collector.queueSnapshotForTesting
        XCTAssertEqual(finalQueue.count, 5, "queue should be trimmed back to maxQueueSize")

        let finalIDs = Set(finalQueue.map(\.id))
        for event in failingBatch {
            XCTAssertTrue(finalIDs.contains(event.id), "retried batch must survive eviction")
        }

        // 3 retried events + maxQueueSize of 5 leaves room for exactly 2 of the 4 new
        // arrivals; the newest ones (not yet attempted) are the ones that must give way.
        XCTAssertTrue(finalIDs.contains(newEvents[0].id))
        XCTAssertTrue(finalIDs.contains(newEvents[1].id))
        XCTAssertFalse(finalIDs.contains(newEvents[2].id))
        XCTAssertFalse(finalIDs.contains(newEvents[3].id))
    }
}

// MARK: - Test doubles

/// Synchronizes the test with `GatedFailingURLProtocol` so a `collect()` call made from the
/// test is guaranteed to land while `flush()` is suspended on the network call, not before or
/// after it.
actor FlushGate {
    private var started = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var opened = false
    private var openContinuation: CheckedContinuation<Void, Never>?

    func waitForRequestStarted() async {
        if started { return }
        await withCheckedContinuation { startContinuation = $0 }
    }

    func markRequestStarted() {
        started = true
        startContinuation?.resume()
        startContinuation = nil
    }

    func waitForOpen() async {
        if opened { return }
        await withCheckedContinuation { openContinuation = $0 }
    }

    func openGate() {
        opened = true
        openContinuation?.resume()
        openContinuation = nil
    }
}

/// A `URLProtocol` that reports a request as started, waits for the test to open `gate`, then
/// always fails with a non-retryable error. Lets the test control exactly when an in-flight
/// "network" call resolves without touching the real network or relying on incidental timing.
final class GatedFailingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var gate: FlushGate!

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let gate = Self.gate!
        Task {
            await gate.markRequestStarted()
            await gate.waitForOpen()
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        }
    }

    override func stopLoading() {}
}
