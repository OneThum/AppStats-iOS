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
    private let maxQueueSize = 500 // Hard limit per SDK spec
    private let batchSize = 20 // Flush when queue reaches this size
    
    // MARK: - Initialization
    
    init(sessionID: UUID, storage: StorageManager, network: NetworkManager) {
        self.sessionID = sessionID
        self.storage = storage
        self.network = network
        
        // Load any persisted events from previous session
        Task {
            await loadPersistedEvents()
        }
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
        try await storage.saveEvent(event)
        
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
                try await storage.clearEvents()
                for event in eventQueue {
                    try? await storage.saveEvent(event)
                }
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
            
            // Keep queue within limits
            if eventQueue.count > maxQueueSize {
                eventQueue = Array(eventQueue.suffix(maxQueueSize))
            }
            
            throw error
        }
    }
    
    // MARK: - Private
    
    private func loadPersistedEvents() async {
        do {
            let persistedEvents = try await storage.loadEvents()
            
            // Filter out stale events (>48 hours old)
            let cutoffDate = Date().addingTimeInterval(-48 * 3600)
            let validEvents = persistedEvents.filter { $0.timestamp > cutoffDate }
            
            // Add to queue (respecting max size)
            let eventsToRestore = Array(validEvents.prefix(maxQueueSize))
            eventQueue.append(contentsOf: eventsToRestore)
            
        } catch {
            // Silent failure - not critical
            print("[AppStats] Failed to load persisted events: \(error)")
        }
    }
}
