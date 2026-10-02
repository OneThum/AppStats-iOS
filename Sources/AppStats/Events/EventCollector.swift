// EventCollector.swift - Event collection and batching
// Copyright © 2026 One Thum Software

import Foundation

/// Collects, batches, and sends events to the server
actor EventCollector {
    
    // MARK: - Properties
    
    private let sessionID: UUID
    private let storage: StorageManager
    private let network: NetworkManager
    
    private var eventQueue: [Event] = []
    /// Persisted events older than this are not restored on launch.
    private let staleEventAge: TimeInterval = 48 * 3600

    private var initialLoadFinished = false
    private var initialLoadWaiters: [CheckedContinuation<Void, Never>] = []
    private let maxQueueSize: Int // Hard limit per SDK spec; 500 in production
    private let batchSize = 20 // Flush when queue reaches this size

    // MARK: - Initialization

    init(sessionID: UUID, storage: StorageManager, network: NetworkManager, maxQueueSize: Int = 500) {
        self.sessionID = sessionID
        self.storage = storage
        self.network = network
        self.maxQueueSize = maxQueueSize
        
        // Load any persisted events from previous session
        Task {
            await loadPersistedEvents()
        }
    }

    /// Test-only: wait for the queue restored at init to be in place.
    ///
    /// The restore runs in a detached task, so without this a test's own `collect()` calls
    /// race it and the resulting queue depends on which won.
    func awaitInitialLoadForTesting() async {
        if initialLoadFinished { return }
        await withCheckedContinuation { initialLoadWaiters.append($0) }
    }

    /// Release anything waiting on the init-time restore.
    private func finishInitialLoad() {
        initialLoadFinished = true
        let waiters = initialLoadWaiters
        initialLoadWaiters = []
        for waiter in waiters { waiter.resume() }
    }
    
    // MARK: - Event Collection
    
    /// Collect an event
    func collect(_ event: Event) async throws {
        // Check queue size limit
        if eventQueue.count >= maxQueueSize {
            // Evict oldest event
            eventQueue.removeFirst()
        }
        
        // Add to in-memory queue
        eventQueue.append(event)
        
        // Persist to disk
        try await storage.saveEvents(eventQueue)
        
        // Flush if batch size reached
        if eventQueue.count >= batchSize {
            Task {
                try await flush()
            }
        }
    }
    
    /// Flush all queued events to the server
    func flush() async throws {
        guard !eventQueue.isEmpty else { return }
        
        // Take up to 100 events from queue to avoid hitting server limits
        let eventsToSend = Array(eventQueue.prefix(100))
        eventQueue.removeFirst(eventsToSend.count)
        
        // Send to server
        do {
            try await network.sendEvents(eventsToSend)
            
            // Clear from persistent storage on success if queue is empty,
            // otherwise just re-persist remaining queue
            if eventQueue.isEmpty {
                try await storage.clearEvents()
            } else {
                try await storage.saveEvents(eventQueue)
            }
            
            // If we still have events, recursively flush again
            if !eventQueue.isEmpty {
                Task {
                    try? await flush()
                }
            }
            
        } catch {
            // On failure, restore events to queue
            eventQueue.insert(contentsOf: eventsToSend, at: 0)

            // Keep queue within limits. Trim from the tail (the newest arrivals, appended by
            // `collect()` while this batch was in flight) rather than the head: `eventsToSend`
            // just failed to send and is about to be retried, so it must survive eviction
            // ahead of events that haven't been attempted yet. This intentionally overrides
            // `collect()`'s own steady-state "evict oldest" policy for the batch under retry.
            if eventQueue.count > maxQueueSize {
                eventQueue = Array(eventQueue.prefix(maxQueueSize))
            }

            throw error
        }
    }
    
    /// Test-only snapshot of the in-memory queue, oldest first.
    var queueSnapshotForTesting: [Event] { eventQueue }

    // MARK: - Private

    private func loadPersistedEvents() async {
        defer { finishInitialLoad() }

        do {
            let persistedEvents = try await storage.loadEvents()

            eventQueue.append(contentsOf: Self.eventsToRestore(
                persisted: persistedEvents,
                alreadyQueued: eventQueue,
                staleBefore: Date().addingTimeInterval(-staleEventAge),
                maxQueueSize: maxQueueSize
            ))

        } catch {
            // Silent failure - not critical
            print("[AppStats] Failed to load persisted events: \(error)")
        }
    }

    /// Which persisted events should join the queue on launch.
    ///
    /// Pulled out of `loadPersistedEvents` so it can be tested directly. The restore runs in
    /// a detached task from `init`, and whether it or a `collect()` call gets there first is
    /// not something a test can pin down through the actor -- but this decision is the whole
    /// of the behaviour, and it is a pure function of its inputs.
    ///
    /// - An event already in the queue is never restored. `collect()` persists the queue as
    ///   it goes, so the file read here may already hold the events sitting in `eventQueue`;
    ///   appending them queued each one twice and sent it twice, which on a cold start is any
    ///   event tracked in the first moments of launch.
    /// - The ceiling applies to the queue as it stands. Appending up to `maxQueueSize` on top
    ///   of a non-empty queue overshot it.
    /// - Events older than `staleEventAge` are dropped: nobody wants a session from last week
    ///   appearing live, and the backend would place it in the past anyway.
    static func eventsToRestore(
        persisted: [Event],
        alreadyQueued: [Event],
        staleBefore: Date,
        maxQueueSize: Int
    ) -> [Event] {
        let queuedIDs = Set(alreadyQueued.map(\.id))
        let restorable = persisted.filter { $0.timestamp > staleBefore && !queuedIDs.contains($0.id) }
        let room = max(0, maxQueueSize - alreadyQueued.count)
        return Array(restorable.prefix(room))
    }
}
