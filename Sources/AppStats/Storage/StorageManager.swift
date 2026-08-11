// StorageManager.swift - Local event persistence
// Copyright © 2026 One Thum Software

import Foundation

/// Manages local storage of events with an in-memory fallback.
actor StorageManager {
    
    // MARK: - Properties
    
    private let fileManager = FileManager.default
    private let storageDirectory: URL?
    private let databaseURL: URL?
    private let userPropertiesURL: URL?

    private let maxStorageSize: UInt64 = 10 * 1024 * 1024 // 10 MB limit

    // MARK: - Initialization

    init() {
        let fileManager = FileManager.default
        let resolvedPaths: (storageDirectory: URL?, databaseURL: URL?, userPropertiesURL: URL?)

        do {
            let storageDirectory = try StoragePaths.ensureAppStatsDirectoryExists(fileManager: fileManager)
            resolvedPaths = (
                storageDirectory,
                try StoragePaths.eventsFileURL(fileManager: fileManager),
                try StoragePaths.userPropertiesFileURL(fileManager: fileManager)
            )
        } catch {
            resolvedPaths = (nil, nil, nil)
            Logger.warning("Persistent storage unavailable - using in-memory queue only: \(error)")
        }

        self.storageDirectory = resolvedPaths.storageDirectory
        self.databaseURL = resolvedPaths.databaseURL
        self.userPropertiesURL = resolvedPaths.userPropertiesURL
    }
    
    // MARK: - Event Persistence
    
    /// Save the entire queue to disk (overwrites existing)
    func saveEvents(_ events: [Event]) throws {
        guard let databaseURL else { return }

        try ensureStorageDirectoryExists()

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
        guard let databaseURL else {
            return []
        }

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
        guard let databaseURL else { return }

        if fileManager.fileExists(atPath: databaseURL.path) {
            try fileManager.removeItem(at: databaseURL)
        }
    }

    // MARK: - User Property Persistence

    /// Save the entire user property set to disk (overwrites existing)
    func saveUserProperties(_ properties: [String: AnyCodable]) throws {
        guard let userPropertiesURL else { return }

        try ensureStorageDirectoryExists()

        let encoder = JSONEncoder()
        let data = try encoder.encode(properties)

        try data.write(to: userPropertiesURL, options: .atomic)
    }

    /// Load persisted user properties
    func loadUserProperties() throws -> [String: AnyCodable] {
        guard let userPropertiesURL else { return [:] }

        guard fileManager.fileExists(atPath: userPropertiesURL.path) else {
            return [:]
        }

        let data = try Data(contentsOf: userPropertiesURL)
        return try JSONDecoder().decode([String: AnyCodable].self, from: data)
    }

    // MARK: - Private
    
    private func calculateStorageSize() throws -> UInt64 {
        guard let storageDirectory else {
            return 0
        }

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

    private func ensureStorageDirectoryExists() throws {
        guard storageDirectory != nil else { return }
        _ = try StoragePaths.ensureAppStatsDirectoryExists(fileManager: fileManager)
    }
    
    private func pruneOldEvents() throws {
        guard let databaseURL else { return }

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
