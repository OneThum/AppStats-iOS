// StorageManager.swift - Local event persistence
// Copyright © 2026 One Thum Software

import Foundation

/// Manages local storage of events using SQLite
actor StorageManager {
    
    // MARK: - Properties
    
    private let fileManager = FileManager.default
    private let storageDirectory: URL
    private let databaseURL: URL
    
    private let maxStorageSize: UInt64 = 10 * 1024 * 1024 // 10 MB limit
    
    // MARK: - Initialization
    
    init() throws {
        // Create AppStats directory in Application Support
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        
        self.storageDirectory = appSupport.appendingPathComponent("AppStats", isDirectory: true)
        self.databaseURL = storageDirectory.appendingPathComponent("events.json")
        
        // Create directory if needed
        if !fileManager.fileExists(atPath: storageDirectory.path) {
            try fileManager.createDirectory(
                at: storageDirectory,
                withIntermediateDirectories: true
            )
        }
    }
    
    // MARK: - Event Persistence
    
    /// Save the entire queue to disk (overwrites existing)
    func saveEvents(_ events: [Event]) throws {
        // Check disk budget
        let currentSize = try calculateStorageSize()
        if currentSize >= maxStorageSize && !events.isEmpty {
            // If we're over budget, don't write
            return
        }
        
        // Save to disk
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(events)
        
        try data.write(to: databaseURL, options: .atomic)
    }
    
    /// Load all persisted events
    func loadEvents() throws -> [Event] {
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            return []
        }
        
        let data = try Data(contentsOf: databaseURL)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        return try decoder.decode([Event].self, from: data)
    }
    
    /// Clear all persisted events
    func clearEvents() throws {
        if fileManager.fileExists(atPath: databaseURL.path) {
            try fileManager.removeItem(at: databaseURL)
        }
    }
    
    // MARK: - Private
    
    private func calculateStorageSize() throws -> UInt64 {
        guard fileManager.fileExists(atPath: storageDirectory.path) else {
            return 0
        }
        
        let contents = try fileManager.contentsOfDirectory(
            at: storageDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        
        return try contents.reduce(0) { total, url in
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let fileSize = attributes[.size] as? UInt64 ?? 0
            return total + fileSize
        }
    }
    
    private func pruneOldEvents() throws {
        var events = try loadEvents()
        
        // Remove oldest 25% of events
        let pruneCount = max(1, events.count / 4)
        events.removeFirst(pruneCount)
        
        // Save back
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(events)
        
        try data.write(to: databaseURL, options: .atomic)
    }
}
